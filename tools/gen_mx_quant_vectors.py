#!/usr/bin/env python3
"""Test data for rtl/mx_quant.v (FP32 -> MX blocks).

Expected codes come from the compiler's own rounding (block_codes in
tools/real_model_on_chip.py, which uses ml_dtypes), not from a copy of the
hardware's method.

Usage: python3 tools/gen_mx_quant_vectors.py N BLOCKS OUT_PREFIX [SEED]
Writes OUT_PREFIX_in.hex (one FP32 word of N lanes per line; a block is
32/N lines), _fmt.hex (format per block), _exp.hex (per block: 32 codes as
one 256-bit hex word, then the scale byte, on one line).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from real_model_on_chip import block_codes          # noqa: E402

FMTS = ["mxint8", "mxfp8", "mxfp4"]
GRID = {"mxfp8": (3, -6), "mxfp4": (1, 0)}           # mantissa bits, smallest normal exponent
EMAX = {"mxint8": 0, "mxfp8": 8, "mxfp4": 2}


def f32(v):
    return np.array(v, dtype=np.float64).astype(np.float32)


def tie_block(rng, fmt):
    """Values exactly half-way between two codes (after scaling)."""
    e = int(rng.integers(-120, 110))
    vals = []
    for _ in range(32):
        if fmt == "mxint8":
            k = int(rng.integers(-127, 127)) + 0.5
            y = k / 64
        else:
            mb, emin = GRID[fmt]
            q = int(rng.integers(emin - 1, EMAX[fmt] + 1))
            step = 2.0 ** (max(q, emin) - mb)
            base = int(rng.integers(0, 2 ** (mb + 1)))
            y = (2.0 ** max(q, emin) if q >= emin else 0) + (base + 0.5) * step
            y *= rng.choice([-1, 1])
        vals.append(y * 2.0 ** e)
    # make one value the block's largest, so the scale is the intended one
    vals[int(rng.integers(0, 32))] = (2.0 ** (EMAX[fmt] + e)) * rng.choice([-1, 1]) * 1.5
    return f32(vals)


def block(rng, kind, fmt):
    if kind == "normal":
        return f32(rng.standard_normal(32) * 2.0 ** int(rng.integers(-130, 120)))
    if kind == "wide":                                   # big and tiny together
        return f32(rng.standard_normal(32) * 2.0 ** rng.integers(-149, 127, 32).astype(np.float64))
    if kind == "sub":                                    # FP32 subnormal inputs
        return (rng.integers(-2 ** 23, 2 ** 23, 32).astype(np.float64) * 2.0 ** -149).astype(np.float32)
    if kind == "zero":
        v = np.zeros(32, dtype=np.float32)
        v[rng.integers(0, 32, 5)] = -0.0
        return v
    if kind == "few":                                    # mostly zeros, a few numbers
        v = np.zeros(32, dtype=np.float32)
        v[rng.integers(0, 32, 3)] = f32(rng.standard_normal(3) * 2.0 ** int(rng.integers(-100, 100)))
        return v
    if kind == "edge":                                   # around the largest codes and powers of two
        e = int(rng.integers(-100, 100))
        top = {"mxint8": 127 / 64, "mxfp8": 448.0, "mxfp4": 6.0}[fmt]
        cands = [top, np.nextafter(np.float32(top), np.float32(1e9)), top * 1.03, top * 1.0714, 2.0 ** EMAX[fmt],
                 np.nextafter(np.float32(2.0 ** (EMAX[fmt] + 1)), np.float32(0)), 1.0, 0.5, 2.0 ** -9, 2.0 ** -10,
                 1.5 * 2.0 ** -10, 0.25, 0.75, 3.0 * 2.0 ** -10]
        y = np.array([cands[i] for i in rng.integers(0, len(cands), 32)]) * rng.choice([-1, 1], 32)
        return f32(y * 2.0 ** e)
    return tie_block(rng, fmt)


def main():
    N, nblk = int(sys.argv[1]), int(sys.argv[2])
    pre = sys.argv[3]
    rng = np.random.default_rng(int(sys.argv[4]) if len(sys.argv) > 4 else 5)
    kinds = ["normal", "wide", "sub", "zero", "few", "edge", "tie", "tie"]
    fin, ffmt, fexp = [], [], []
    for b in range(nblk):
        fmt = FMTS[int(rng.integers(0, 3))]
        v = block(rng, kinds[b % len(kinds)], fmt)
        codes, scale = block_codes(v.astype(np.float64), fmt)
        bits = v.view(np.uint32)
        for w in range(32 // N):
            word = 0
            for lane in range(N):
                word |= int(bits[w * N + lane]) << (32 * lane)
            fin.append(f"{word:0{8 * N}x}")
        ffmt.append(f"{FMTS.index(fmt):x}")
        cw = 0
        for i, c in enumerate(codes):
            cw |= (c & 0xFF) << (8 * i)
        fexp.append(f"{cw:064x}{scale & 0xFF:02x}")
    for suffix, lines in (("_in.hex", fin), ("_fmt.hex", ffmt), ("_exp.hex", fexp)):
        with open(pre + suffix, "w") as fh:
            fh.write("\n".join(lines) + "\n")
    print(f"mx_quant vectors: {nblk} blocks, N={N}")


if __name__ == "__main__":
    main()
