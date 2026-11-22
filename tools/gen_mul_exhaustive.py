#!/usr/bin/env python3
"""Expected product for EVERY input of rtl/mx_mul.v: 16 format pairs x
256 x 256 = 1,048,576 cases, values from ml_dtypes. Bit 48 marks a skipped
case (uses the FP8 "not a number" code, not supported yet).
Usage: python3 tools/gen_mul_exhaustive.py OUT_HEX"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gen_mx_vectors import FP8_NAN, value_x512   # noqa: E402

FP8, FP4, RSV = 1, 2, 3


def v(f, c):
    if f == RSV:
        return 0
    return value_x512(FP4, c & 15) if f == FP4 else value_x512(f, c)


def main():
    skipped = 0
    with open(sys.argv[1], "w") as fh:
        for fa in range(4):
            for fb in range(4):
                for a in range(256):
                    for b in range(256):
                        if (fa == FP8 and a in FP8_NAN) or (fb == FP8 and b in FP8_NAN):
                            fh.write(f"{1 << 48:013x}\n"); skipped += 1; continue
                        if fa == FP4 and fb == FP4:
                            p = v(FP4, a) * v(FP4, b) + v(FP4, a >> 4) * v(FP4, b >> 4)
                        else:
                            p = v(fa, a) * v(fb, b)
                        fh.write(f"{p & ((1 << 48) - 1):013x}\n")
    print(f"multiplier exhaustive: {16 * 65536} cases, {skipped} marked skip")


if __name__ == "__main__":
    main()
