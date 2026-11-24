#!/usr/bin/env python3
"""The vector unit's one-instruction 2^x and 1/x (rtl/vu_v2.v) against their
exact definitions (tools/vu_asm.py: ex2_bits, rcp_bits), on random bit
patterns of every exponent and on edge cases: zeros, infinities, tiny
(subnormal) numbers, the clamp limits of 2^x, and the ends of 1/x's range.
Usage: python3 tests/run_vu2_special.py [ROUNDS]"""
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from vu_asm import OPS, bits, ex2_bits, rcp_bits      # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "build", "vu2s")
L = int(os.environ.get("IMBEWU_LANES", "16"))
VU2 = os.environ.get("IMBEWU_VU2", "rtl/vu_v2.v")
SIM = os.environ.get("IMBEWU_SIM")        # a simulation built elsewhere (e.g. the gate-level one)


def edge_values():
    v = [0, 0x80000000, 0x7F800000, 0xFF800000, 1, 0x80000001, 0x007FFFFF, 0x807FFFFF, 0x00800000]
    for x in (1.0, -1.0, 0.5, 2.0, 127.0, -126.0, 126.99999, -125.99999, 127.5, -126.5, 128.0, -128.0,
              1e-8, -1e-8, 3e38, -3e38, 1e-38, 1.9999999, 1.0000001, 0.75, 1e30, 5.9e-39):
        v.append(bits(np.float32(x)))
    for e in range(256):                 # every exponent, mantissas at both ends and the middle
        for m in (0, 1, 0x400000, 0x7FFFFF):
            v += [(e << 23) | m, 0x80000000 | (e << 23) | m]
    return v


def main():
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    assert rounds * 64 * L >= len(edge_values()), "too few rounds for all edge cases"
    os.makedirs(OUT, exist_ok=True)
    sim = SIM or os.path.join(OUT, "tb")
    SIM or subprocess.run(["iverilog", "-g2012", f"-DLANES={L}", "-DVU_V2", "-I", os.path.join(ROOT, "rtl"), "-o", sim] +
                   [os.path.join(ROOT, f) for f in ("rtl/fp32_add_fx.v", "rtl/fp32_ops.v", VU2, "tests/tb_vu.v")],
                   check=True)
    rng = np.random.default_rng(7)
    edges = edge_values()
    ok, checked = True, 0
    for r in range(rounds):
        for op in ("EX2", "RCP"):
            # 64 input vectors at 0..63; results at 128..191
            chunk = edges[r * 64 * L:(r + 1) * 64 * L]          # edge cases first, spread over rounds
            vals = chunk + [int(x) for x in rng.integers(0, 2 ** 32, 64 * L, dtype=np.uint64)]
            vals = (vals + [0] * (64 * L))[:64 * L]
            prog = []
            for a in range(64):
                prog += [(OPS["LD"] << 26) | a, (OPS[op] << 26) | (1 << 23), (OPS["ST"] << 26) | (1 << 20) | (128 + a)]
            prog.append(0)
            pre = os.path.join(OUT, f"{op}_{r}")
            with open(pre + "_imem.hex", "w") as fh:
                fh.writelines(f"{w:08x}\n" for w in prog)
            with open(pre + "_cmem.hex", "w") as fh:
                fh.write("00000000\n")
            with open(pre + "_vmem.hex", "w") as fh:
                for a in range(256):
                    word = sum(vals[a * L + i] << (32 * i) for i in range(L)) if a < 64 else 0
                    fh.write(f"{word:0{8 * L}x}\n")
            subprocess.run(["vvp", "-n", sim, f"+PRE={pre}"], capture_output=True, text=True, check=True)
            lines = open(pre + "_out.hex").read().split()
            f = ex2_bits if op == "EX2" else rcp_bits
            bad = 0
            for a in range(64):
                word = int(lines[128 + a], 16) if "x" not in lines[128 + a].lower() else -1
                for i in range(L):
                    got = (word >> (32 * i)) & 0xFFFFFFFF if word >= 0 else -1
                    want = f(vals[a * L + i])
                    if got != want:
                        bad += 1
                        if bad <= 3:
                            print(f"  {op}({vals[a * L + i]:08x}): hardware {got:08x}, definition {want:08x}")
            checked += 64 * L
            ok &= bad == 0
    print(f"{'PASS' if ok else 'FAIL'}  2^x and 1/x: {checked} inputs (every exponent, edge cases, random bit patterns), "
          f"hardware = definition bit for bit: {ok}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
