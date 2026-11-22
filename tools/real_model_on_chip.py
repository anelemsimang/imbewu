#!/usr/bin/env python3
"""Run real numbers from a public language model through the Imbewu
multi-format engine (rtl/systolic_mx.v) in simulation.

Steps:
  1. Load the model, feed it a sentence from WikiText-2, and capture the real
     activations going into one of its layers, plus that layer's weights.
  2. Take a 16 x 896 slice of activations (16 tokens) and the weights of the
     first 16 output channels, and round both to an MX format
     (INT8 / FP8 E4M3 / FP4 E2M1, blocks of 32 sharing one scale).
  3. Each block of 32 becomes one job for the 16x16 engine (28 jobs).
  4. Simulate the chip design, read its output rows, add up the blocks.
  5. Check that the chip's answer equals, exactly, the same maths done in
     software, and measure how far it is from the original full-precision
     (FP32) answer.

Usage: python3 tools/real_model_on_chip.py [MODEL] [LAYER] [OUT_JSON]
"""
import json
import os
import subprocess
import sys
from fractions import Fraction

import ml_dtypes
import numpy as np
import torch

sys.path.insert(0, os.path.dirname(__file__))
from accuracy_eval import EMAX, mx_quant          # noqa: E402
from gen_mx_vectors import write_vectors          # noqa: E402

N, BLOCK = 16, 32
FMT_CODE = {"mxint8": 0, "mxfp8": 1, "mxfp4": 2}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build", "real")


def block_codes(v, fmt):
    """One block of 32 floats -> (element codes, E8M0 scale code)."""
    amax = float(np.abs(v).max())
    e = int(np.floor(np.log2(max(amax, 2.0 ** -127)))) - EMAX[fmt]
    e = max(-127, min(127, e))
    y = v / (2.0 ** e)
    if fmt == "mxfp8":
        codes = np.clip(y, -448, 448).astype(ml_dtypes.float8_e4m3fn).view(np.uint8)
    elif fmt == "mxfp4":
        codes = np.clip(y, -6, 6).astype(ml_dtypes.float4_e2m1fn).view(np.uint8) & 0xF
    else:
        codes = (np.clip(np.round(y * 64), -128, 127).astype(np.int64) & 0xFF).astype(np.uint8)
    return [int(c) for c in codes], e + 127


def capture(model_id, layer):
    from datasets import load_dataset
    from transformers import AutoModelForCausalLM, AutoTokenizer
    tok = AutoTokenizer.from_pretrained(model_id)
    model = AutoModelForCausalLM.from_pretrained(model_id, torch_dtype=torch.float32).eval()
    lines = [t for t in load_dataset("Salesforce/wikitext", "wikitext-2-raw-v1",
                                     split="test")["text"] if len(t) > 200]
    ids = tok(lines[0], return_tensors="pt").input_ids[:, :64]
    target = model.model.layers[layer].mlp.gate_proj
    got = {}
    def hook(module, inputs, output):            # record the input, change nothing
        got.setdefault("x", inputs[0].detach())
    h = target.register_forward_hook(hook)
    with torch.no_grad():
        model(ids)
    h.remove()
    x = got["x"][0, -N:, :].double().numpy()          # 16 tokens x K
    w = target.weight.detach().double().numpy()[:N, :] # 16 outputs x K
    return x, w, lines[0][:80]


def run_format(x, w, fmt):
    K = x.shape[1]
    jobs = []
    for b in range(K // BLOCK):
        A, sa, B_cols, sb = [], [], [], []
        for i in range(N):
            c, s = block_codes(x[i, b * BLOCK:(b + 1) * BLOCK], fmt)
            A.append(c); sa.append(s)
        for j in range(N):
            c, s = block_codes(w[j, b * BLOCK:(b + 1) * BLOCK], fmt)
            B_cols.append(c); sb.append(s)
        B = [[B_cols[j][k] for j in range(N)] for k in range(BLOCK)]
        beats = BLOCK // 2 if fmt == "mxfp4" else BLOCK
        jobs.append(dict(fmt=FMT_CODE[fmt], beats=beats, K=BLOCK, A=A, B=B, sa=sa, sb=sb))

    os.makedirs(BUILD, exist_ok=True)
    pre = os.path.join(BUILD, f"real_{fmt}")
    write_vectors(N, jobs, pre)
    sim = os.path.join(BUILD, "tb_mx_16")
    if not os.path.exists(sim):
        subprocess.run(["iverilog", "-g2012", f"-DGRID_N={N}", "-o", sim,
                        os.path.join(ROOT, "rtl/pe_mx.v"), os.path.join(ROOT, "rtl/systolic_mx.v"),
                        os.path.join(ROOT, "tests/tb_systolic_mx.v")], check=True)
    dump = pre + "_chip_out.hex"
    log = subprocess.run(["vvp", "-n", sim, f"+PRE={pre}", f"+DUMP={dump}"],
                         check=True, capture_output=True, text=True).stdout
    sim_pass = "PASS" in log

    # Add up the chip's block results
    extra = Fraction(1, 4096) if fmt == "mxint8" else Fraction(1)   # MXINT8 implied 2^-6 each
    chip = [[Fraction(0)] * N for _ in range(N)]
    rows = open(dump).read().split()
    for r, line in enumerate(rows):
        word = int(line, 16)
        i = r % N
        for j in range(N):
            e = (word >> (j * 10)) & 0x3FF
            e = e - 1024 if e >= 512 else e
            v = (word >> (N * 10 + j * 48)) & ((1 << 48) - 1)
            v = v - (1 << 48) if v >= (1 << 47) else v
            chip[i][j] += Fraction(v) * Fraction(2) ** e * extra

    # Same maths in software (independent path: torch MX rounding, exact sums)
    xq = mx_quant(torch.tensor(x), fmt).numpy()
    wq = mx_quant(torch.tensor(w), fmt).numpy()
    exact_match = all(
        chip[i][j] == sum(Fraction(float(xq[i, k])) * Fraction(float(wq[j, k])) for k in range(K))
        for i in range(N) for j in range(N))

    ref = x @ w.T
    c = np.array([[float(chip[i][j]) for j in range(N)] for i in range(N)])
    rel_err = float(np.linalg.norm(c - ref) / np.linalg.norm(ref))
    return dict(format=fmt, jobs=len(jobs), sim_pass=sim_pass, exact_match_software=exact_match,
                relative_error_vs_fp32_pct=round(100 * rel_err, 3))


def main():
    model_id = sys.argv[1] if len(sys.argv) > 1 else "Qwen/Qwen2.5-0.5B"
    layer = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    out = sys.argv[3] if len(sys.argv) > 3 else None
    x, w, sample = capture(model_id, layer)
    res = dict(model=model_id, layer=layer, matrix="mlp.gate_proj", tile=f"{N}x{x.shape[1]} x {x.shape[1]}x{N}",
               text_sample=sample, results=[])
    for fmt in ("mxint8", "mxfp8", "mxfp4"):
        r = run_format(x, w, fmt)
        print(json.dumps(r), flush=True)
        res["results"].append(r)
    if out:
        with open(out, "w") as fh:
            json.dump(res, fh, indent=2)


if __name__ == "__main__":
    main()
