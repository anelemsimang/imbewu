#!/usr/bin/env python3
"""Test vectors for rtl/fp32_ops.v: FP32 add and multiply, expected results
from NumPy's float32 arithmetic (IEEE 754, round to nearest even), which is
independent of the design. Many cases are aimed at the hard spots: exact
ties, cancellation, subnormals, overflow, signed zeros, infinities.
Usage: python3 tools/gen_fp32_ops_vectors.py OUT_PREFIX [COUNT]"""
import random
import sys

import numpy as np


def f2b(f):
    return int(np.array(f, dtype=np.float32).view(np.uint32))


def b2f(b):
    return np.array(b, dtype=np.uint32).view(np.float32)


def rand_bits():
    r = random.random()
    if r < 0.1:
        return random.choice([0, 0x80000000, 0x7F800000, 0xFF800000, 0x3F800000, 0xBF800000,
                              0x00000001, 0x807FFFFF, 0x7F7FFFFF, 0xFF7FFFFF, 0x00800000])
    if r < 0.25:                                   # subnormals and tiny normals
        return random.randrange(2) << 31 | random.randrange(0, 1 << 24)
    if r < 0.35:                                   # huge
        return random.randrange(2) << 31 | random.randrange(0xFE, 0xFF) << 23 | random.randrange(1 << 23)
    while True:
        b = random.randrange(1 << 32)
        if (b >> 23) & 0xFF != 0xFF:
            return b


def pair():
    a = rand_bits()
    r = random.random()
    if r < 0.15:                                   # near-cancellation
        b = (a ^ 0x80000000) + random.randrange(-3, 4)
    elif r < 0.3:                                  # close exponents
        b = (a & 0xFF800000) ^ (random.randrange(2) << 31) | random.randrange(1 << 23)
        b += random.randrange(-2, 3) << 23
    elif r < 0.4:                                  # ties: halfway cases for add
        b = (a & 0x7F800000) - (24 << 23) | (random.randrange(2) << 31)
    else:
        b = rand_bits()
    b &= 0xFFFFFFFF
    if (b >> 23) & 0xFF == 0xFF and b & 0x7FFFFF:
        b &= 0xFF800000
    return a, b


def main():
    pre = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 200000
    random.seed(99)
    stim, exp = [], []
    with np.errstate(all="ignore"):
        for _ in range(count):
            a, b = pair()
            s = f2b(b2f(a) + b2f(b))
            p = f2b(b2f(a) * b2f(b))
            if np.isnan(b2f(s)): s = 0x7FC00000
            if np.isnan(b2f(p)): p = 0x7FC00000
            stim.append(f"{a:08x}{b:08x}")
            exp.append(f"{s:08x}{p:08x}")
    open(pre + "_stim.hex", "w").write("\n".join(stim) + "\n")
    open(pre + "_exp.hex", "w").write("\n".join(exp) + "\n")
    print(f"fp32 ops vectors: {count}")


if __name__ == "__main__":
    main()
