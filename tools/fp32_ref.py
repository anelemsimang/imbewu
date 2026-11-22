#!/usr/bin/env python3
"""Independent reference for FP32 rounding, used to check rtl/fp32_add_fx.v
and the version 4 engine.

Works with exact fractions (Python's Fraction), then rounds once to the
nearest FP32 value, ties to even, with subnormals and overflow to infinity,
following IEEE 754. It shares no code or method with the Verilog design.

Usage: python3 tools/fp32_ref.py OUT_PREFIX [COUNT]
  writes OUT_PREFIX_stim.hex (acc, x, e) and OUT_PREFIX_exp.hex (sum)
"""
import random
import sys
from fractions import Fraction

INF = "inf"


def bits_to_value(b):
    """FP32 bits -> Fraction, or (INF, sign) for infinity."""
    s = -1 if b >> 31 else 1
    ex = (b >> 23) & 0xFF
    fr = b & 0x7FFFFF
    if ex == 0xFF:
        assert fr == 0, "NaN never expected"
        return (INF, s)
    if ex == 0:
        return s * Fraction(fr, 1 << 149)
    return s * Fraction((1 << 23) | fr) * Fraction(2) ** (ex - 150)


def round_fp32(v, sign_if_zero=0):
    """Exact Fraction -> FP32 bits (round to nearest, ties to even)."""
    if v == 0:
        return sign_if_zero << 31
    sign = 1 if v < 0 else 0
    a = -v if sign else v
    # exponent t with 2^t <= a < 2^(t+1)
    t = a.numerator.bit_length() - a.denominator.bit_length()
    if Fraction(2) ** t > a:
        t -= 1
    lsb = max(t - 23, -149)
    q = a / Fraction(2) ** lsb
    n = q.numerator // q.denominator
    rem = q - n
    if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and n % 2 == 1):
        n += 1
    if n == 1 << 24:
        n >>= 1
        lsb += 1
    if n < (1 << 23):                       # subnormal or zero
        return (sign << 31) | n
    biased = lsb + 150
    if biased >= 255:
        return (sign << 31) | (0xFF << 23)
    return (sign << 31) | (biased << 23) | (n - (1 << 23))


def fadd_ref(acc_bits, x, e):
    """round(acc + x * 2^e), as specified in rtl/fp32_add_fx.v."""
    a = bits_to_value(acc_bits)
    if isinstance(a, tuple):
        return acc_bits                     # infinity stays infinity
    total = a + Fraction(x) * Fraction(2) ** e
    if total == 0:
        return 0                            # exact zero is +0
    return round_fp32(total, 1 if total < 0 else 0)


def no_nan(acc):
    if (acc >> 23) & 0xFF == 0xFF and acc & 0x7FFFFF:
        acc &= 0xFF800000                   # NaN never occurs: make it infinity
    return acc


def rand_case():
    acc, x, e = _rand_case()
    return no_nan(acc), x, e


def _rand_case():
    style = random.random()
    if style < 0.2:                         # acc and x close: cancellation, ties
        acc = round_fp32(Fraction(random.randrange(-(1 << 30), 1 << 30)) * Fraction(2) ** random.randrange(-40, 40))
        av = bits_to_value(acc)
        e = random.randrange(-60, 40)
        x = int(-av / Fraction(2) ** e) + random.randrange(-3, 4) if av != 0 else random.randrange(-9, 9)
        x = max(-(1 << 47), min((1 << 47) - 1, x))
        return acc, x, e
    if style < 0.35:                        # tiny results: subnormals and underflow
        acc = random.choice([0, random.randrange(1 << 23), (1 << 31) | random.randrange(1 << 23),
                             random.randrange(1 << 31)])
        return acc, random.randrange(-(1 << 20), 1 << 20), random.randrange(-284, -150)
    if style < 0.45:                        # huge results: overflow
        acc = random.randrange(1 << 32)
        if (acc >> 23) & 0xFF == 0xFF:
            acc &= ~(1 << 23)               # exponent 0xFE: largest finite
        return acc, random.randrange(-(1 << 47), 1 << 47), random.randrange(60, 237)
    if style < 0.5:                         # infinity in, zero x
        return random.choice([0x7F800000, 0xFF800000, 0, 0x80000000]), random.choice([0, 5, -7]), random.randrange(-284, 237)
    acc = random.randrange(1 << 32)
    if (acc >> 23) & 0xFF == 0xFF and acc & 0x7FFFFF:
        acc &= 0xFF800000                   # no NaN
    bits = random.randrange(1, 48)
    x = random.randrange(-(1 << bits), 1 << bits)
    x = max(-(1 << 47), min((1 << 47) - 1, x))
    return acc, x, random.randrange(-284, 237)


def main():
    pre = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 200000
    random.seed(4242)
    stim, exp = [], []
    for _ in range(count):
        acc, x, e = rand_case()
        stim.append(f"{acc:08x}{x & ((1 << 48) - 1):012x}{e & 0x7FF:03x}")
        exp.append(f"{fadd_ref(acc, x, e):08x}")
    open(pre + "_stim.hex", "w").write("\n".join(stim) + "\n")
    open(pre + "_exp.hex", "w").write("\n".join(exp) + "\n")
    print(f"fp32 adder vectors: {count}")


if __name__ == "__main__":
    main()
