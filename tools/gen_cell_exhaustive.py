#!/usr/bin/env python3
"""Expected product for EVERY possible input of one multi-format cell.

For each format (INT8, FP8 E4M3, FP4 E2M1, reserved) and every pair of 8-bit
inputs a, b (65,536 pairs), write the exact product the cell must add to its
total, in units of 2^-18. Values come from ml_dtypes (independent of the
chip design). Bit 48 of each word marks a case that is skipped because it
involves the FP8 "not a number" code, which the cell does not handle yet.

Usage: python3 tools/gen_cell_exhaustive.py OUT_HEX
"""
import sys

from gen_mx_vectors import FP4, FP8, FP8_NAN, INT8, value_x512


def product(fmt, a, b):
    if fmt == INT8 or fmt == FP8:
        return value_x512(fmt, a) * value_x512(fmt, b)
    if fmt == FP4:
        return (value_x512(FP4, a & 15) * value_x512(FP4, b & 15) +
                value_x512(FP4, a >> 4) * value_x512(FP4, b >> 4))
    return 0                                     # fmt 3: reserved, zero


def main():
    skipped = 0
    with open(sys.argv[1], "w") as fh:
        for fmt in range(4):
            for a in range(256):
                for b in range(256):
                    if fmt == FP8 and (a in FP8_NAN or b in FP8_NAN):
                        fh.write(f"{1 << 48:013x}\n")
                        skipped += 1
                        continue
                    p = product(fmt, a, b)
                    fh.write(f"{p & ((1 << 48) - 1):013x}\n")
    print(f"cell exhaustive: {4 * 65536} cases, {skipped} FP8 NaN cases marked skip")


if __name__ == "__main__":
    main()
