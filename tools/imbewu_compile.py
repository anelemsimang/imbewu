#!/usr/bin/env python3
"""imbewu_compile.py - first step of the Imbewu software stack (workstream W3).

Plain language: this turns a PyTorch linear layer (the matrix multiply that
makes up most of a language model) and a batch of inputs into work for the
Imbewu tile, runs the simulated tile, and turns the tile's answers back
into a PyTorch tensor. It does what a chip's compiler and runtime do:
  1. choose number formats (for example FP8 activations x FP4 weights) and
     round the numbers into OCP MX blocks of 32 with shared scales;
  2. pad the sizes to what the engine handles (multiples of N, K of 32);
  3. cut the layer into commands that fit the tile's memory halves, with
     each group of weights fetched once and reused for every batch of
     tokens (tile_v3 weight slots);
  4. lay everything out in main memory (the "driver contract", layout v3);
  5. run the tile simulation and read the answers back.
Checks: the tile's answers must equal, bit for bit, an independent software
version of the same arithmetic; and their error against PyTorch's own
full-precision answer is reported.

Library use:  y, report = imbewu_linear(layer, x, a_fmt="mxfp8", w_fmt="mxfp4")
Command line: python3 tools/imbewu_compile.py [MODEL] [LAYER] [TOKENS] [OUTPUTS]
"""
import json
import os
import struct
import subprocess
import sys

import numpy as np
import torch

sys.path.insert(0, os.path.dirname(__file__))
from fp32_ref import fadd_ref                      # noqa: E402
from gen_mx_vectors import value_x512              # noqa: E402
from gen_tile_v1_vectors import pack               # noqa: E402
from real_model_on_chip import block_codes         # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FMT = {"mxint8": 0, "mxfp8": 1, "mxfp4": 2}
BLOCK, HALF, MAX_CMDS, OUT_BASE = 32, 1024, 16, 1 << 18
RTL = ["rtl/mx_mul.v", "rtl/fp32_add_fx.v", "rtl/pe_v5.v", "rtl/systolic_v5.v",
       os.environ.get("IMBEWU_MATMUL", "rtl/matmul_unit.v"),     # replaceable for planted-bug checks
       "rtl/sram.v", "rtl/tile_v3.v", "tests/tb_tile_v1.v"]


def quantise_rows(m, fmt):
    """Rows of a matrix -> per row, per block of 32: (codes, scale code)."""
    nb = m.shape[1] // BLOCK
    return [[block_codes(m[r, b * BLOCK:(b + 1) * BLOCK], fmt) for b in range(nb)]
            for r in range(m.shape[0])]


def values_x512(q, f):
    """Exact element values (times 2^9) as an integer array [rows, K]."""
    def v(c):
        if f == 1 and c in (0x7F, 0xFF):
            return 0                       # FP8 "not a number": never produced by rounding
        return value_x512(2, c & 15) if f == 2 else value_x512(f, c)
    table = np.array([v(c) for c in range(256)], dtype=np.int64)
    codes = np.array([[c for codes, _ in row for c in codes] for row in q], dtype=np.int64)
    return table[codes]


def plan_layer(x, w, N, a_fmt, w_fmt, packed=True):
    """Make the memory image, command list and expected answers."""
    M0, K0 = x.shape
    Nout0 = w.shape[0]
    K = -(-K0 // BLOCK) * BLOCK
    M = -(-M0 // N) * N
    Nout = -(-Nout0 // N) * N
    xp = np.zeros((M, K)); xp[:M0, :K0] = x
    wp = np.zeros((Nout, K)); wp[:Nout0, :K0] = w
    fa, fb = FMT[a_fmt], FMT[w_fmt]
    pair = fa == 2 and fb == 2
    # D-020: in a mixed job the FP4 side is stored two numbers per byte
    pk_a = packed and fa == 2 and fb != 2
    pk_b = packed and fb == 2 and fa != 2
    beats = K // 2 if pair else K
    bb = BLOCK // 2 if pair else BLOCK
    KB = K // BLOCK
    # as many tiles per command as the SRAM halves allow
    MT = max(1, min(M // N, HALF // (beats // 2 if pk_a else beats), HALF // N))
    NT = max(1, min(Nout // N, HALF // (beats // 2 if pk_b else beats), HALF // (MT * N)))
    while (M // N) % MT: MT -= 1
    while (Nout // N) % NT: NT -= 1
    groups, batches = Nout // (N * NT), M // (N * MT)
    if groups * batches > MAX_CMDS:
        raise ValueError(f"layer needs {groups * batches} commands; this tile holds {MAX_CMDS}")
    qa, qw = quantise_rows(xp, a_fmt), quantise_rows(wp, w_fmt)

    def lane(f, c):
        return c & 15 if f == 2 else c

    def word(lanes, width=8):
        out = 0
        for n, v in enumerate(lanes):
            out |= v << (n * width)
        return out

    mem, cmds = [], []
    out_ptr = OUT_BASE
    for g in range(groups):                       # one group of weights ...
        col0 = g * NT * N
        for p in range(batches):                  # ... reused by every batch of tokens
            row0 = p * MT * N
            A, SA, B, SB = [], [], [], []
            for mt in range(MT):
                rows = [qa[row0 + mt * N + i] for i in range(N)]
                for t in range(beats // 2 if pk_a else beats):
                    if pk_a:
                        A.append(word([rows[i][(2 * t) // BLOCK][0][(2 * t) % BLOCK] |
                                       (rows[i][(2 * t + 1) // BLOCK][0][(2 * t + 1) % BLOCK] << 4)
                                       for i in range(N)]))
                    elif pair:
                        A.append(word([rows[i][(2 * t) // BLOCK][0][(2 * t) % BLOCK] |
                                       (rows[i][(2 * t + 1) // BLOCK][0][(2 * t + 1) % BLOCK] << 4)
                                       for i in range(N)]))
                    else:
                        A.append(word([lane(fa, rows[i][t // BLOCK][0][t % BLOCK]) for i in range(N)]))
                for kb in range(KB):
                    SA.append(word([rows[i][kb][1] for i in range(N)]))
            if p == 0:
                for nt in range(NT):
                    cols = [qw[col0 + nt * N + j] for j in range(N)]
                    for t in range(beats // 2 if pk_b else beats):
                        if pk_b:
                            B.append(word([cols[j][(2 * t) // BLOCK][0][(2 * t) % BLOCK] |
                                           (cols[j][(2 * t + 1) // BLOCK][0][(2 * t + 1) % BLOCK] << 4)
                                           for j in range(N)]))
                        elif pair:
                            B.append(word([cols[j][(2 * t) // BLOCK][0][(2 * t) % BLOCK] |
                                           (cols[j][(2 * t + 1) // BLOCK][0][(2 * t + 1) % BLOCK] << 4)
                                           for j in range(N)]))
                        else:
                            B.append(word([lane(fb, cols[j][t // BLOCK][0][t % BLOCK]) for j in range(N)]))
                    for kb in range(KB):
                        SB.append(word([cols[j][kb][1] for j in range(N)]))
            n_c = MT * N * NT
            in_addr = len(mem)
            mem.extend(A + SA + B + SB)
            cmds.append(pack([(in_addr, 20), (len(A), 16), (len(B), 16), (len(SA), 12),
                              (len(SB), 12), (out_ptr, 20), (n_c, 16), (MT, 8), (NT, 8),
                              (beats, 16), (bb, 16), (KB, 16), (fa, 2), (fb, 2),
                              (g % 2, 1), (int(pk_a or pk_b), 1), (0, 18)]))
            out_ptr += 4 * n_c
    # expected answers from an independent software path: exact block sums
    # (integers), one FP32 rounding per block (exact fractions)
    va, vw = values_x512(qa, fa), values_x512(qw, fb)
    adj = 6 * (fa == 0) + 6 * (fb == 0)
    expect = np.zeros((M, Nout), dtype=np.uint32)
    for m in range(M):
        for n in range(Nout):
            acc = 0
            for kb in range(KB):
                s = int(np.dot(va[m, kb * BLOCK:(kb + 1) * BLOCK], vw[n, kb * BLOCK:(kb + 1) * BLOCK]))
                acc = fadd_ref(acc, s, qa[m][kb][1] + qw[n][kb][1] - 272 - adj)
            expect[m, n] = acc
    total_beats = groups * batches * MT * NT * beats
    return dict(mem=mem, cmds=cmds, expect=expect, M0=M0, Nout0=Nout0, M=M, Nout=Nout,
                N=N, MT=MT, NT=NT, groups=groups, batches=batches, beats=beats,
                total_beats=total_beats, outmap_rows=_outmap(groups, batches, MT, NT, N))


def _outmap(groups, batches, MT, NT, N):
    """For each C word in answer order: (row, first column) of its N answers."""
    out = []
    for g in range(groups):
        for p in range(batches):
            for mt in range(MT):
                for i in range(N):
                    for nt in range(NT):
                        out.append((p * MT * N + mt * N + i, g * NT * N + nt * N))
    return out


def run_tile(plan, work, lat=40, every=1):
    """Write the files, run the tile simulation, read the answers back."""
    N = plan["N"]
    os.makedirs(work, exist_ok=True)
    pre = os.path.join(work, "layer")
    hw = (8 * N + 3) // 4
    with open(pre + "_mem.hex", "w") as fh:
        fh.writelines(f"{v:0{hw}x}\n" for v in plan["mem"])
    with open(pre + "_cmd.hex", "w") as fh:
        fh.writelines(f"{c:050x}\n" for c in plan["cmds"])
    # expected words (address + data), in C-word order, 4 memory words each
    exp_words = []
    for cw, (r, c0) in enumerate(plan["outmap_rows"]):
        word = 0
        for j in range(N):
            word |= int(plan["expect"][r, c0 + j]) << (32 * j)
        for q in range(4):
            exp_words.append((OUT_BASE + 4 * cw + q, (word >> (8 * N * q)) & ((1 << (8 * N)) - 1)))
    with open(pre + "_exp.hex", "w") as fh:
        fh.writelines(f"{a:05x}{d:0{hw}x}\n" for a, d in exp_words)
    with open(pre + "_meta.hex", "w") as fh:
        fh.write(f"{len(plan['cmds']):x}\n{len(plan['mem']):x}\n{len(exp_words):x}\n{plan['total_beats']:x}\n")
    sim = os.path.join(work, f"tb_{N}")
    if not os.path.exists(sim):
        subprocess.run(["iverilog", "-g2012", f"-DGRID_N={N}", "-DTILE_V3", "-o", sim] +
                       [os.path.join(ROOT, f) for f in RTL], check=True)
    dump = pre + "_dump.hex"
    log = subprocess.run(["vvp", "-n", sim, f"+PRE={pre}", f"+LAT={lat}", f"+EVERY={every}",
                          f"+DUMP={dump}"], check=True, capture_output=True, text=True).stdout
    # undefined bits ("x") mean the tile produced no valid answer: count as wrong
    raw = open(dump).read().split()
    undefined = any(("x" in l or "z" in l) for l in raw)
    words = [int(l.replace("x", "0").replace("z", "0"), 16) for l in raw]
    y_bits = np.zeros((plan["M"], plan["Nout"]), dtype=np.uint32)
    for cw, (r, c0) in enumerate(plan["outmap_rows"]):
        full = 0
        for q in range(4):
            full |= words[4 * cw + q] << (8 * N * q)
        for j in range(N):
            y_bits[r, c0 + j] = (full >> (32 * j)) & 0xFFFFFFFF
    return y_bits, (log + "\nUNDEFINED answers read back\n") if undefined else log


def imbewu_linear(layer, x, a_fmt="mxfp8", w_fmt="mxfp4", N=16, work=None, packed=True):
    """Run y = layer(x) (no bias) on the simulated Imbewu tile."""
    w = layer.weight.detach().double().numpy()
    xn = x.detach().double().numpy()
    plan = plan_layer(xn, w, N, a_fmt, w_fmt, packed)
    work = work or os.path.join(ROOT, "build", "compile")
    y_bits, log = run_tile(plan, work)
    exact = bool(np.array_equal(y_bits, plan["expect"])) and "UNDEFINED" not in log
    y = y_bits.view(np.float32)[:plan["M0"], :plan["Nout0"]].astype(np.float64)
    ref = xn @ w.T
    err = float(np.linalg.norm(y - ref) / np.linalg.norm(ref))
    ticks = [l for l in log.splitlines() if "ticks busy" in l]
    report = dict(activations=a_fmt, weights=w_fmt, engine=f"{N}x{N}", fp4_packed=packed,
                  commands=len(plan["cmds"]), tiles_per_command=f"{plan['MT']}x{plan['NT']}",
                  weight_groups=plan["groups"], token_batches=plan["batches"],
                  bit_exact_vs_reference=exact, tile_pass="PASS" in log,
                  relative_error_vs_pytorch_fp32_pct=round(100 * err, 3),
                  tile_timing=ticks[0].split(": ", 1)[1] if ticks else "")
    return torch.tensor(y), report


def main():
    model_id = sys.argv[1] if len(sys.argv) > 1 else "Qwen/Qwen2.5-0.5B"
    layer_i = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    tokens = int(sys.argv[3]) if len(sys.argv) > 3 else 32
    outs = int(sys.argv[4]) if len(sys.argv) > 4 else 128
    from datasets import load_dataset
    from transformers import AutoModelForCausalLM, AutoTokenizer
    tok = AutoTokenizer.from_pretrained(model_id)
    model = AutoModelForCausalLM.from_pretrained(model_id, torch_dtype=torch.float32).eval()
    text = [t for t in load_dataset("Salesforce/wikitext", "wikitext-2-raw-v1",
                                    split="test")["text"] if len(t) > 200][0]
    ids = tok(text, return_tensors="pt").input_ids[:, :tokens]
    layer = model.model.layers[layer_i].mlp.gate_proj
    got = {}
    def hook(module, inputs, output):      # record the input; return nothing, change nothing
        got.setdefault("x", inputs[0].detach())
    h = layer.register_forward_hook(hook)
    with torch.no_grad():
        model(ids)
    h.remove()
    x = got["x"][0]
    sub = torch.nn.Linear(layer.in_features, outs, bias=False)
    sub.weight.data = layer.weight.data[:outs].clone()
    results = []
    for a_fmt, w_fmt in (("mxfp8", "mxfp4"), ("mxfp8", "mxfp8")):
        y, rep = imbewu_linear(sub, x, a_fmt, w_fmt,
                               work=os.path.join(ROOT, "build", "compile", f"{a_fmt}_{w_fmt}"))
        rep.update(model=model_id, layer=f"layers.{layer_i}.mlp.gate_proj (first {outs} outputs)",
                   tokens=int(x.shape[0]), K=int(x.shape[1]), output_shape=list(y.shape))
        print(json.dumps(rep), flush=True)
        results.append(rep)
    os.makedirs(os.path.join(ROOT, "results"), exist_ok=True)
    with open(os.path.join(ROOT, "results", "compile_qwen0.5b_gate_proj.json"), "w") as fh:
        json.dump(results, fh, indent=2)


if __name__ == "__main__":
    main()
