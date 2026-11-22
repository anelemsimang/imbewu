#!/usr/bin/env python3
"""Accuracy check: how much does a real language model lose when its maths
runs in the number formats the Imbewu engine supports?

Method (standard "fake quantisation"):
  * Load a public pretrained language model.
  * Before every matrix multiply in the model's transformer layers (every
    nn.Linear), round both the weights and the incoming activations to an
    OCP MX format: blocks of 32 numbers share one power-of-two scale (E8M0),
    each number is stored as INT8, FP8 E4M3 or FP4 E2M1. Products are then
    summed in high precision, as the Imbewu engine does (it sums exactly).
  * Measure perplexity on the WikiText-2 test set. Perplexity is the standard
    accuracy measure for language models: lower is better; it is roughly how
    many words the model is "choosing between" at each step.

Kept in original precision (stated in the results): the token embedding,
the final output layer (lm_head), normalisation layers, and the two
attention products (Q x K and attention x V).

Usage: python3 tools/accuracy_eval.py MODEL_ID [--windows 40] [--seq 1024]
"""
import argparse
import json
import math
import time

import ml_dtypes
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

BLOCK = 32
EMAX = {"mxint8": 0, "mxfp8": 8, "mxfp4": 2}      # largest element exponent
FP4_GRID = torch.tensor([0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0])


def round_fp4(y):
    """Round to the nearest FP4 E2M1 value, ties to even (OCP MX)."""
    a = y.abs().clamp(max=6.0)
    grid = FP4_GRID.to(a.device, a.dtype)
    idx = torch.bucketize(a, (grid[1:] + grid[:-1]) / 2)          # nearest, ties up
    # ties: midpoints where the lower neighbour has the even code
    mids = (grid[1:] + grid[:-1]) / 2
    tie_low = torch.tensor([True, False, True, False, True, False, True], device=a.device)
    for m in range(7):
        if tie_low[m]:
            idx = torch.where(a == mids[m], torch.full_like(idx, m), idx)
    return torch.sign(y) * grid[idx]


def mx_quant(x, fmt):
    """Quantise x to an MX format along its last dimension, blocks of 32."""
    if fmt == "none":
        return x
    shape = x.shape
    n = shape[-1]
    pad = (-n) % BLOCK
    xf = x.float()
    if pad:
        xf = F.pad(xf, (0, pad))
    xb = xf.reshape(-1, BLOCK)
    amax = xb.abs().amax(dim=1, keepdim=True)
    e = torch.floor(torch.log2(amax.clamp(min=2.0 ** -127))) - EMAX[fmt]
    e = e.clamp(-127, 127)
    scale = torch.exp2(e)
    y = xb / scale
    if fmt == "mxfp8":
        y = y.clamp(-448, 448).to(torch.float8_e4m3fn).float()
    elif fmt == "mxfp4":
        y = round_fp4(y)
    elif fmt == "mxint8":
        y = torch.round(y * 64).clamp(-128, 127) / 64     # MXINT8: implied 2^-6
    q = (y * scale).reshape(*shape[:-1], n + pad)[..., :n]
    return q.to(x.dtype)


class MXLinear(nn.Module):
    """nn.Linear whose weights and inputs are rounded to MX formats."""

    def __init__(self, lin, w_fmt, a_fmt):
        super().__init__()
        self.weight_q = nn.Parameter(mx_quant(lin.weight.data, w_fmt), requires_grad=False)
        self.bias = lin.bias
        self.a_fmt = a_fmt

    def forward(self, x):
        return F.linear(mx_quant(x, self.a_fmt), self.weight_q, self.bias)


def self_check():
    """Compare this file's rounding against the ml_dtypes library."""
    torch.manual_seed(0)
    y = torch.randn(200000) * 3
    ours8 = y.clamp(-448, 448).to(torch.float8_e4m3fn).float().numpy()
    ref8 = np.clip(y.numpy(), -448, 448).astype(ml_dtypes.float8_e4m3fn).astype(np.float32)
    ours4 = round_fp4(y).numpy()
    ref4 = np.clip(y.numpy(), -6, 6).astype(ml_dtypes.float4_e2m1fn).astype(np.float32)
    # exact ties, to exercise the tie rule
    ties = torch.tensor([0.25, 0.75, 1.25, 1.75, 2.5, 3.5, 5.0, -0.25, -2.5, -5.0])
    ok_t = np.array_equal(round_fp4(ties).numpy(),
                          ties.numpy().astype(ml_dtypes.float4_e2m1fn).astype(np.float32))
    return dict(fp8_mismatches=int((ours8 != ref8).sum()),
                fp4_mismatches=int((ours4 != ref4).sum()),
                fp4_ties_match=bool(ok_t), samples=len(y))


def swap_linears(model, w_fmt, a_fmt):
    layers = model.model.layers
    for layer in layers:
        for name, mod in list(layer.named_modules()):
            if isinstance(mod, nn.Linear):
                parent = layer.get_submodule(name.rsplit(".", 1)[0]) if "." in name else layer
                setattr(parent, name.rsplit(".", 1)[-1], MXLinear(mod, w_fmt, a_fmt))


@torch.no_grad()
def perplexity(model, ids, seq, windows):
    nll, count = 0.0, 0
    for w in range(windows):
        chunk = ids[:, w * seq:(w + 1) * seq]
        out = model(chunk, labels=chunk)
        n = chunk.shape[1] - 1
        nll += out.loss.item() * n
        count += n
    return math.exp(nll / count), count


def main():
    from datasets import load_dataset
    from transformers import AutoModelForCausalLM, AutoTokenizer

    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--windows", type=int, default=40)
    ap.add_argument("--seq", type=int, default=1024)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    torch.set_num_threads(max(1, torch.get_num_threads()))

    check = self_check()
    print("rounding self-check vs ml_dtypes:", check, flush=True)

    tok = AutoTokenizer.from_pretrained(args.model)
    text = "\n\n".join(load_dataset("Salesforce/wikitext", "wikitext-2-raw-v1", split="test")["text"])
    ids = tok(text, return_tensors="pt").input_ids
    windows = min(args.windows, ids.shape[1] // args.seq)

    configs = [
        ("FP32 (reference)",            "none",   "none"),
        ("MXINT8",                      "mxint8", "mxint8"),
        ("MXFP8 E4M3",                  "mxfp8",  "mxfp8"),
        ("MXFP4 E2M1",                  "mxfp4",  "mxfp4"),
        ("MXFP4 weights + MXFP8 acts",  "mxfp4",  "mxfp8"),
    ]
    results = []
    base = None
    for label, wf, af in configs:
        t0 = time.time()
        model = AutoModelForCausalLM.from_pretrained(args.model, torch_dtype=torch.float32)
        model.eval()
        swap_linears(model, wf, af)
        ppl, ntok = perplexity(model, ids, args.seq, windows)
        base = ppl if base is None else base
        r = dict(config=label, weights=wf, activations=af, perplexity=round(ppl, 3),
                 change_pct=round(100 * (ppl / base - 1), 2), tokens=ntok,
                 seconds=round(time.time() - t0))
        results.append(r)
        print(json.dumps(r), flush=True)
        del model

    summary = dict(model=args.model, dataset="wikitext-2-raw-v1 test", seq=args.seq,
                   windows=windows, self_check=check, results=results)
    if args.out:
        with open(args.out, "w") as fh:
            json.dump(summary, fh, indent=2)


if __name__ == "__main__":
    main()
