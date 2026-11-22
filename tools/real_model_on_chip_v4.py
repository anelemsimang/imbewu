#!/usr/bin/env python3
"""Real language-model numbers through the version 4 engine (rtl/systolic_v4.v).

As tools/real_model_on_chip.py, but now each output is ONE job covering the
whole row (K = 896 = 28 MX blocks), summed inside the chip into FP32, and the
two sides may use different formats. Configurations tried:
  FP8 x FP8, INT8 x INT8, FP4 x FP4, and FP8 activations x FP4 weights
  (the mixed mode chosen in decision D-015).
Checks: (1) the chip's FP32 answer equals, bit for bit, the independent
reference (block totals exact, one FP32 rounding per block);
(2) how far it is from the full-precision answer.

Usage: python3 tools/real_model_on_chip_v4.py [MODEL] [LAYER] [OUT_JSON]
"""
import json
import os
import struct
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from gen_v4_vectors import write_vectors                    # noqa: E402
from real_model_on_chip import block_codes, capture          # noqa: E402

N, BLOCK = 16, 32
FMT = {"mxint8": 0, "mxfp8": 1, "mxfp4": 2}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build", "real_v4")


def run(x, w, a_fmt, b_fmt, sim):
    K = x.shape[1]
    fa, fb = FMT[a_fmt], FMT[b_fmt]
    blocks = []
    for b in range(K // BLOCK):
        A, sa, Bc, sb = [], [], [], []
        for i in range(N):
            c, s = block_codes(x[i, b * BLOCK:(b + 1) * BLOCK], a_fmt)
            A.append(c); sa.append(s)
        for j in range(N):
            c, s = block_codes(w[j, b * BLOCK:(b + 1) * BLOCK], b_fmt)
            Bc.append(c); sb.append(s)
        blocks.append(dict(K=BLOCK, A=A, B=[[Bc[j][k] for j in range(N)] for k in range(BLOCK)],
                           sa=sa, sb=sb))
    job = dict(fa=fa, fb=fb, pair=(fa == 2 and fb == 2), blocks=blocks)
    pre = os.path.join(BUILD, f"real_{a_fmt}_{b_fmt}")
    write_vectors(N, [job], pre)
    log = subprocess.run(["vvp", "-n", sim, f"+PRE={pre}", f"+DUMP={pre}_chip.hex"],
                         check=True, capture_output=True, text=True).stdout
    rows = open(pre + "_chip.hex").read().split()
    chip = np.array([[struct.unpack(">f", ((int(r, 16) >> (32 * j)) & 0xFFFFFFFF).to_bytes(4, "big"))[0]
                      for j in range(N)] for r in rows])
    ref = x @ w.T
    err = float(np.linalg.norm(chip - ref) / np.linalg.norm(ref))
    beats = sum((bl["K"] + 1) // 2 if job["pair"] else bl["K"] for bl in blocks)
    return dict(activations=a_fmt, weights=b_fmt, blocks=len(blocks), beats=beats,
                bit_exact_vs_reference="PASS" in log,
                relative_error_vs_fp32_pct=round(100 * err, 3))


def main():
    model_id = sys.argv[1] if len(sys.argv) > 1 else "Qwen/Qwen2.5-0.5B"
    layer = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    out = sys.argv[3] if len(sys.argv) > 3 else None
    x, w, sample = capture(model_id, layer)
    os.makedirs(BUILD, exist_ok=True)
    # IMBEWU_ENGINE=v5 runs the version 5 engine (shared adders, 16 cells each)
    ver = os.environ.get("IMBEWU_ENGINE", "v4")
    sim = os.path.join(BUILD, f"tb_{ver}_16")
    flags = ["-DV5", "-DGROUP=16"] if ver == "v5" else []
    subprocess.run(["iverilog", "-g2012", f"-DGRID_N={N}", "-o", sim] + flags +
                   [os.path.join(ROOT, f) for f in ("rtl/mx_mul.v", "rtl/fp32_add_fx.v", f"rtl/pe_{ver}.v",
                                                    f"rtl/systolic_{ver}.v", "tests/tb_systolic_v4.v")],
                   check=True)
    res = dict(model=model_id, layer=layer, engine=ver, matrix="mlp.gate_proj",
               tile=f"{N}x{x.shape[1]} x {x.shape[1]}x{N}, one job", results=[])
    for a_fmt, b_fmt in (("mxint8", "mxint8"), ("mxfp8", "mxfp8"), ("mxfp4", "mxfp4"), ("mxfp8", "mxfp4")):
        r = run(x, w, a_fmt, b_fmt, sim)
        print(json.dumps(r), flush=True)
        res["results"].append(r)
    if out:
        with open(out, "w") as fh:
            json.dump(res, fh, indent=2)


if __name__ == "__main__":
    main()
