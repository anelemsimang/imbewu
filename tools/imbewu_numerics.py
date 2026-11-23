#!/usr/bin/env python3
"""imbewu_numerics.py - a whole language model on Imbewu's exact arithmetic.

Plain language: simulating the chip gate by gate is far too slow for a
whole model. But every calculation the chip does is now pinned down by
bit-exact references that the hardware matches:
  * matrix multiplies (engine version 5): MX rounding of both sides, exact
    sums inside each block of 32, one FP32 rounding per block;
  * the vector unit (vu_v1): softmax, RMSNorm and SiLU as exactly the same
    FP32 instruction sequences (tools/vu_asm.py).
This file does the same arithmetic quickly with PyTorch, so a real model
(Qwen2.5-0.5B) can run end to end "as the chip would", and its accuracy
(perplexity on WikiText-2) can be compared with ordinary FP32.

What runs on Imbewu arithmetic: every linear layer (attention q/k/v/o,
MLP gate/up/down, and the output layer), both attention products (Q x K
and attention x V), softmax, every RMSNorm, and SiLU. Element-wise steps
(rotary position code, residual adds, gate x up) are plain FP32, which is
what the vector unit's add and multiply do. The token embedding is a table
lookup (no arithmetic).

One approximation, measured by self_check(): the "one FP32 rounding per
block" is done via float64, which can round twice in very rare cases.

Usage: python3 tools/imbewu_numerics.py [MODEL] [--windows 8] [--check]
"""
import argparse
import json
import math
import os
import random
import sys
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

sys.path.insert(0, os.path.dirname(__file__))
from accuracy_eval import EMAX, perplexity, round_fp4     # noqa: E402

BLOCK, LANES = 32, 16
LOG2E = 1.4426950408889634
EXP_C = [math.log(2) ** k / math.factorial(k) for k in range(8)]
f32 = lambda v: torch.tensor(v, dtype=torch.float32)


# ---- matrix units --------------------------------------------------------------
def mx_split(x, fmt):
    """x [..., K] (K multiple of 32) -> (element values without the block
    scale [..., KB, 32] as float64, block scale exponents [..., KB])."""
    xb = x.double().reshape(*x.shape[:-1], -1, BLOCK)
    amax = xb.abs().amax(-1)
    e = torch.floor(torch.log2(amax.clamp(min=2.0 ** -127))) - EMAX[fmt]
    e = e.clamp(-127, 127)
    y = xb / torch.exp2(e).unsqueeze(-1)
    if fmt == "mxfp8":
        y = y.clamp(-448, 448).float().to(torch.float8_e4m3fn).double()
    elif fmt == "mxfp4":
        y = round_fp4(y.float()).double()
    else:
        y = torch.round(y * 64).clamp(-128, 127) / 64
    return y, e


def imbewu_matmul(x, w, fa="mxfp8", fb="mxfp8", wsplit=None):
    """x [..., K] times w [N, K]^T on the engine's arithmetic -> float32."""
    K = x.shape[-1]
    pad = (-K) % BLOCK
    if pad:
        x = F.pad(x, (0, pad))
        w = F.pad(w, (0, pad))
    lead = x.shape[:-1]
    x2 = x.reshape(-1, x.shape[-1])
    ux, ex = mx_split(x2, fa)
    uw, ew = wsplit if wsplit is not None else mx_split(w, fb)
    out = torch.empty(x2.shape[0], w.shape[0], dtype=torch.float32)
    step = max(1, (1 << 26) // (w.shape[0] * ux.shape[1]))
    for t0 in range(0, x2.shape[0], step):
        u, e = ux[t0:t0 + step], ex[t0:t0 + step]
        # exact sum inside each block (float64 holds it exactly), then the
        # block's power-of-two scale (exact)
        blk = torch.einsum("tkb,nkb->ktn", u, uw)
        blk = torch.ldexp(blk, (e.t().unsqueeze(-1) + ew.t().unsqueeze(1)).long())
        acc = torch.zeros(u.shape[0], w.shape[0], dtype=torch.float32)
        for kb in range(blk.shape[0]):            # FP32 total, one rounding per block
            acc = (acc.double() + blk[kb]).float()
        out[t0:t0 + step] = acc
    return out.reshape(*lead, w.shape[0])


def imbewu_bmm(x, w, fa="mxfp8", fb="mxfp8"):
    """Batched: x [B, T, K] times w [B, N, K]^T, same arithmetic as
    imbewu_matmul (used for the attention products, all heads at once)."""
    K = x.shape[-1]
    pad = (-K) % BLOCK
    if pad:
        x = F.pad(x, (0, pad))
        w = F.pad(w, (0, pad))
    ux, ex = mx_split(x, fa)                      # [B, T, KB, 32], [B, T, KB]
    uw, ew = mx_split(w, fb)                      # [B, N, KB, 32], [B, N, KB]
    blk = torch.einsum("btkc,bnkc->kbtn", ux, uw)
    sc = ex.permute(2, 0, 1).unsqueeze(-1) + ew.permute(2, 0, 1).unsqueeze(-2)
    blk = torch.ldexp(blk, sc.long())
    acc = torch.zeros(x.shape[0], x.shape[1], w.shape[1], dtype=torch.float32)
    for kb in range(blk.shape[0]):
        acc = (acc.double() + blk[kb]).float()
    return acc


class ImbewuLinear(nn.Module):
    def __init__(self, lin, fa, fb):
        super().__init__()
        self.fa = fa
        self.w = lin.weight.data
        self.wsplit = mx_split(F.pad(self.w, (0, (-self.w.shape[1]) % BLOCK)), fb)
        self.bias = lin.bias

    def forward(self, x):
        y = imbewu_matmul(x.float(), self.w, self.fa, None, self.wsplit)
        return y if self.bias is None else y + self.bias


# ---- vector unit (same instruction sequences as tools/vu_asm.py) ------------------
def _lane_sum(acc):
    while acc.shape[-1] > 1:                      # pairwise: (0+1), (2+3), ...
        acc = acc[..., 0::2] + acc[..., 1::2]
    return acc[..., 0]


def _row_sum(x):
    """Sum of each row as the vector unit does it: word by word, then lanes."""
    xw = x.reshape(*x.shape[:-1], -1, LANES)
    acc = torch.zeros_like(xw[..., 0, :])
    for i in range(xw.shape[-2]):
        acc = acc + xw[..., i, :]
    return _lane_sum(acc)


def _vmax(a, b):
    return torch.where(a < b, b, a)


def _vmin(a, b):
    return torch.where(a < b, a, b)


def vu_exp(x):
    t = x * f32(LOG2E)
    t = _vmin(_vmax(t, f32(-126.0)), f32(127.0))
    n = torch.floor(t)
    fr = t - n
    p = torch.full_like(x, EXP_C[7])
    for k in range(6, -1, -1):
        p = p * fr
        p = p + f32(EXP_C[k])
    return p * torch.ldexp(torch.ones_like(n), n.to(torch.int32))


def vu_recip(a):
    out = (0x7EF311C3 - (a.view(torch.int32) & 0x7FFFFFFF)).view(torch.float32)
    for _ in range(3):
        t = a * out
        t = f32(2.0) - t
        out = out * t
    return out


def vu_rsqrt(a):
    out = (0x5F3759DF - ((a.view(torch.int32) & 0x7FFFFFFF) >> 1)).view(torch.float32)
    for _ in range(3):
        t = out * out
        t = t * a
        t = t * f32(0.5)
        t = f32(1.5) - t
        out = out * t
    return out


def vu_softmax(x):
    """Softmax over the last dimension (padded to whole vectors)."""
    n = x.shape[-1]
    pad = (-n) % LANES
    xp = F.pad(x, (0, pad), value=-3.0e38) if pad else x
    xw = xp.reshape(*xp.shape[:-1], -1, LANES)
    m = xw[..., 0, :]
    for i in range(1, xw.shape[-2]):
        m = _vmax(m, xw[..., i, :])
    while m.shape[-1] > 1:
        m = _vmax(m[..., 0::2], m[..., 1::2])
    e = vu_exp(xp - m)
    r = vu_recip(_row_sum(e)).unsqueeze(-1)
    return (e * r)[..., :n]


def vu_rmsnorm(x, g, eps, n):
    s = _row_sum(x * x)
    s = s * f32(1.0 / n)
    s = s + f32(eps)
    r = vu_rsqrt(s).unsqueeze(-1)
    return (x * r) * g


def vu_silu(x):
    e = vu_exp(x * f32(-1.0))
    e = e + f32(1.0)
    return x * vu_recip(e)


class ImbewuSiLU(nn.Module):
    def forward(self, x):
        return vu_silu(x.float())


class ImbewuRMSNorm(nn.Module):
    def __init__(self, norm):
        super().__init__()
        self.weight = norm.weight
        self.eps = norm.variance_epsilon

    def forward(self, x):
        return vu_rmsnorm(x.float(), self.weight.float(), self.eps, x.shape[-1])


def make_attention(qk_fmt="mxfp8", pv_fmt="mxfp8"):
    """Attention with Q x K^T in qk_fmt and probabilities x V in pv_fmt
    (an MX format on the engine, or None = plain FP32). Softmax is always
    the vector unit's."""
    from transformers.models.qwen2.modeling_qwen2 import repeat_kv

    def attention(module, query, key, value, attention_mask, scaling, dropout=0.0, **kw):
        k = repeat_kv(key, module.num_key_value_groups)
        v = repeat_kv(value, module.num_key_value_groups)
        B, H, T, D = query.shape
        if qk_fmt is None:
            s = torch.matmul(query.float(), k.float().transpose(2, 3))
        else:                                      # Q x K^T on the engine
            s = imbewu_bmm(query.float().reshape(B * H, T, D), k.float().reshape(B * H, -1, D),
                           qk_fmt, qk_fmt).reshape(B, H, T, -1)
        s = s * f32(scaling)
        if attention_mask is not None:
            s = s + attention_mask.float()
        p = vu_softmax(s)
        if pv_fmt is None:
            o = torch.matmul(p, v.float())
        else:                                      # probabilities x V on the engine
            vt = v.float().transpose(-1, -2).reshape(B * H, D, -1)
            o = imbewu_bmm(p.reshape(B * H, T, -1), vt, pv_fmt, pv_fmt).reshape(B, H, T, D)
        return o.transpose(1, 2).contiguous(), None
    return attention


def to_imbewu(model, w_fmt="mxfp4", a_fmt="mxfp8", head_fmt="mxfp8", attn="mxfp8"):
    """Put a Qwen2 model on Imbewu arithmetic (in place). head_fmt=None keeps
    the output layer in FP32; attn="fp32" keeps the attention products (but
    not softmax) in FP32 - used to find which part costs accuracy."""
    from transformers.models.qwen2 import modeling_qwen2 as m
    for layer in model.model.layers:
        for name in ("q_proj", "k_proj", "v_proj", "o_proj"):
            setattr(layer.self_attn, name, ImbewuLinear(getattr(layer.self_attn, name), a_fmt, w_fmt))
        for name in ("gate_proj", "up_proj", "down_proj"):
            setattr(layer.mlp, name, ImbewuLinear(getattr(layer.mlp, name), a_fmt, w_fmt))
        layer.mlp.act_fn = ImbewuSiLU()
        layer.input_layernorm = ImbewuRMSNorm(layer.input_layernorm)
        layer.post_attention_layernorm = ImbewuRMSNorm(layer.post_attention_layernorm)
    model.model.norm = ImbewuRMSNorm(model.model.norm)
    if head_fmt:
        model.lm_head = ImbewuLinear(model.lm_head, a_fmt, head_fmt)
    # attn: a format for both halves, "fp32", or "qk-fp32" / "pv-fp32" to keep
    # just one half in FP32 (diagnostics)
    qk = None if attn in ("fp32", "qk-fp32") else (a_fmt if attn == "pv-fp32" else attn)
    pv = None if attn in ("fp32", "pv-fp32") else (a_fmt if attn == "qk-fp32" else attn)
    m.eager_attention_forward = make_attention(qk, pv)
    return model


# ---- checks against the bit-exact references ---------------------------------------
def self_check():
    """Fast versions vs the exact references: vector programs vs the vu_asm
    emulator (must be identical), matmul vs fp32_ref (counts differences)."""
    from fp32_ref import fadd_ref
    from gen_mx_vectors import value_x512
    from vu_asm import bits, emulate, from_bits, rmsnorm, silu, softmax
    rng = np.random.default_rng(3)
    res = {}
    W = 4
    for name in ("softmax", "rmsnorm", "silu"):
        same = 0
        for _ in range(20):
            x = (rng.standard_normal(W * LANES) * 3).astype(np.float32)
            g = rng.standard_normal(W * LANES).astype(np.float32)
            vm = {a: [0] * LANES for a in range(256)}
            for a in range(W):
                vm[a] = [bits(v) for v in x[a * LANES:(a + 1) * LANES]]
                vm[32 + a] = [bits(v) for v in g[a * LANES:(a + 1) * LANES]]
            prog = {"softmax": softmax(W), "rmsnorm": rmsnorm(W, W * LANES), "silu": silu(W)}[name]
            emu, _ = emulate(prog, vm, LANES)
            ref = np.array([b for a in range(W) for b in emu[64 + a]], dtype=np.uint32)
            xt = torch.tensor(x)
            y = {"softmax": lambda: vu_softmax(xt), "rmsnorm": lambda: vu_rmsnorm(xt, torch.tensor(g), 1e-6, W * LANES),
                 "silu": lambda: vu_silu(xt)}[name]()
            same += int(np.array_equal(y.numpy().view(np.uint32), ref))
        res[f"{name}_rows_identical_to_emulator"] = f"{same}/20"
    # matmul: compare with exact-fraction rounding on random cases
    from fractions import Fraction
    diff = total = 0
    torch.manual_seed(0)
    for fa, fb in (("mxfp8", "mxfp4"), ("mxfp8", "mxfp8"), ("mxint8", "mxint8")):
        x = torch.randn(8, 96) * 2
        w = torch.randn(8, 96)
        y = imbewu_matmul(x, w, fa, fb).numpy().view(np.uint32)
        ux, ex = mx_split(x, fa)
        uw, ew = mx_split(w, fb)
        for i in range(8):
            for j in range(8):
                acc = 0
                for kb in range(3):
                    s = sum(Fraction(float(a)) * Fraction(float(b)) for a, b in zip(ux[i, kb], uw[j, kb]))
                    v = s * Fraction(2) ** int(ex[i, kb] + ew[j, kb])
                    # express as integer * 2^e for fadd_ref (units 2^-18 exact here)
                    q = v * Fraction(2) ** 40
                    assert q.denominator == 1
                    acc = fadd_ref(acc, int(q.numerator), -40)
                total += 1
                diff += int(acc != int(y[i, j]))
    res["matmul_results_differing_from_exact_rounding"] = f"{diff}/{total}"
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model", nargs="?", default="Qwen/Qwen2.5-0.5B")
    ap.add_argument("--windows", type=int, default=8)
    ap.add_argument("--seq", type=int, default=512)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--skip-ref", type=float, default=None,
                    help="reuse a known FP32 perplexity instead of recomputing it")
    ap.add_argument("--configs", default="ref,fp8,fp4")
    ap.add_argument("--attn", default="mxfp8",
                    help="attention products: mxfp8, mxint8, fp32, qk-fp32 or pv-fp32")
    ap.add_argument("--head", default="mxfp8", help="mxfp8 or none (output layer)")
    args = ap.parse_args()
    torch.set_num_threads(max(1, os.cpu_count() or 1))
    chk = self_check()
    print("self-check:", json.dumps(chk), flush=True)
    if args.check:
        return
    from datasets import load_dataset
    from transformers import AutoModelForCausalLM, AutoTokenizer
    tok = AutoTokenizer.from_pretrained(args.model)
    text = "\n\n".join(load_dataset("Salesforce/wikitext", "wikitext-2-raw-v1", split="test")["text"])
    ids = tok(text, return_tensors="pt").input_ids
    results = []
    todo = [c for c in (("ref", "FP32 (reference)", None), ("fp8", "Imbewu, FP8 activations x FP8 weights", "mxfp8"),
                         ("fp4", "Imbewu, FP8 activations x FP4 weights", "mxfp4")) if c[0] in args.configs.split(",")]
    if args.skip_ref is not None:
        results.append(dict(config="FP32 (reference)", perplexity=args.skip_ref, reused=True))
    for _, label, wf in todo:
        t0 = time.time()
        model = AutoModelForCausalLM.from_pretrained(args.model, torch_dtype=torch.float32,
                                                     attn_implementation="eager").eval()
        if wf:
            to_imbewu(model, w_fmt=wf, attn=args.attn, head_fmt=None if args.head == "none" else args.head)
        ppl, ntok = perplexity(model, ids, args.seq, args.windows)
        r = dict(config=label, attention=args.attn, output_layer=args.head,
                 perplexity=round(ppl, 3), tokens=ntok, seconds=round(time.time() - t0))
        if results:
            r["change_pct"] = round(100 * (ppl / results[0]["perplexity"] - 1), 2)
        print(json.dumps(r), flush=True)
        results.append(r)
        if wf:
            from transformers.models.qwen2 import modeling_qwen2 as m
            import importlib
            importlib.reload(m)
        del model
    out = dict(model=args.model, dataset="wikitext-2-raw-v1 test", seq=args.seq, windows=args.windows,
               self_check=chk, results=results)
    tag = "" if (args.attn, args.head) == ("mxfp8", "mxfp8") else f"_attn-{args.attn}_head-{args.head}"
    with open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "results",
                           f"imbewu_numerics_qwen0.5b{tag}.json"), "w") as fh:
        json.dump(out, fh, indent=2)


if __name__ == "__main__":
    main()
