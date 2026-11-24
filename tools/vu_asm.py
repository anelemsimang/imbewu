#!/usr/bin/env python3
"""Assembler, exact emulator and programs for the vector unit (rtl/vu_v1.v).

The emulator does each instruction exactly as the hardware does (NumPy
float32 for add, subtract and multiply, which is IEEE 754 like the
hardware; the same bit rules for max/min, floor, 2^n and the first-guess
instructions; the same pairwise order for lane sums). So the hardware's
results must equal the emulator's bit for bit, and the emulator can be
compared with PyTorch to measure how accurate each program is.

Programs (all on rows of W vectors of L lanes, i.e. rows of W*L numbers):
  softmax(W)        y = exp(x - max x) / sum(exp(x - max x))
  rmsnorm(W, n)     y = x / sqrt(mean(x^2) + eps) * gamma
  silu(W)           y = x * sigmoid(x) = x / (1 + exp(-x))
"""
import numpy as np

OPS = dict(HALT=0, LD=1, ST=2, ADD=3, SUB=4, MUL=5, MAX=6, MIN=7, RSUM=8, RMAX=9,
           CONST=10, FLOOR=11, POW2I=12, RCPS=13, RSQS=14,
           # version 2 (rtl/vu_v2.v): special functions and constant operands
           EX2=15, RCP=16, ADDC=17, SUBC=18, MULC=19, MAXC=20, MINC=21)


# ---- version 2 special functions, defined exactly (integer steps) -------------
# The hardware (rtl/vu_v2.v) does exactly these steps, so results match bit
# for bit. Accuracy against exact maths is measured by tests/run_vu_tests.py.
EX2_T = [round(2.0 ** (i / 64) * 2 ** 23) for i in range(64)]       # 2^(i/64), 1.23 fixed
EX2_L1 = round(0.6931471805599453 * 2 ** 32)                       # ln 2
EX2_L2 = round(0.6931471805599453 ** 2 / 2 * 2 ** 32)              # (ln 2)^2 / 2
RCP_C = [(round(2 ** 31 / a), round(2 ** 31 / a ** 2), round(2 ** 31 / a ** 3))
         for a in ((2 ** 23 + (i << 16) + (1 << 15)) / 2 ** 23 for i in range(128))]


def ex2_bits(a):
    """2^x for an FP32 bit pattern; x is clamped to -126..127 (so the result
    is always a normal number). 64-entry table of 2^(i/64), then a
    second-order correction for the remaining fraction (< 1/64)."""
    s, E, F = a >> 31, (a >> 23) & 255, a & 0x7FFFFF
    if E >= 134:                                     # |x| >= 128 (or inf / NaN)
        X = (-126 << 24) if s else (127 << 24)
    else:
        M = (F | (1 << 23)) if E else F
        sh = E - 126 if E else -125                  # value * 2^24 = M * 2^(E - 126)
        if sh >= 0:
            mag, lost = M << sh, False
        else:
            mag, lost = M >> -sh, (M & ((1 << -sh) - 1)) != 0
        X = -mag - (1 if lost else 0) if s else mag  # floor(x * 2^24)
        X = max(-126 << 24, min(127 << 24, X))
    n, fr = X >> 24, X & 0xFFFFFF
    i, d = fr >> 18, fr & 0x3FFFF
    e2 = (1 << 30) + ((d * EX2_L1) >> 26) + ((((d * d) >> 18) * EX2_L2) >> 32)
    m = (EX2_T[i] * e2) >> 30
    if m >= 1 << 24:
        m >>= 1
        n += 1
    return ((n + 127) << 23) | (m & 0x7FFFFF)


def rcp_bits(a):
    """1/x for an FP32 bit pattern. Zero and tiny (subnormal) inputs give
    infinity; results below the normal range become zero. 128-entry table
    of 1/a, 1/a^2, 1/a^3 at the middle of each step, then a second-order
    correction."""
    s, E, F = a >> 31, (a >> 23) & 255, a & 0x7FFFFF
    if E == 0:
        return (s << 31) | 0x7F800000
    if E == 255:
        return s << 31
    M = F | (1 << 23)
    i = (M >> 16) & 127
    dl = M - ((1 << 23) + (i << 16) + (1 << 15))     # -2^15 .. 2^15 - 1
    c0, c1, c2 = RCP_C[i]
    R = c0 - ((c1 * dl) >> 23) + ((c2 * ((dl * dl) >> 23)) >> 23)
    if R >= 1 << 31:
        field, m = 254 - E, R >> 8
    else:
        field, m = 253 - E, R >> 7
    if field <= 0:
        return s << 31
    return (s << 31) | (field << 23) | (m & 0x7FFFFF)


def f32(x):
    return np.float32(x)


def bits(x):
    return int(np.array(x, dtype=np.float32).view(np.uint32))


def from_bits(b):
    return np.array(b & 0xFFFFFFFF, dtype=np.uint32).view(np.float32)[()]


class Program:
    """Builds a program: instruction words plus a constant table."""

    def __init__(self):
        self.code, self.consts = [], []

    def ins(self, op, vd=0, va=0, vb=0, imm=0):
        self.code.append((OPS[op] << 26) | (vd << 23) | (va << 20) | (vb << 17) | imm)

    def const(self, vd, value):
        b = bits(value)
        if b not in self.consts:
            self.consts.append(b)
        self.ins("CONST", vd, imm=self.consts.index(b))

    def cidx(self, value):
        """Index of a constant in the table (added if new)."""
        b = bits(value)
        if b not in self.consts:
            self.consts.append(b)
        return self.consts.index(b)

    def words(self):
        return self.code + [0]                 # HALT at the end


# ---- building blocks -------------------------------------------------------
LOG2E = 1.4426950408889634
def _coefs():
    import math
    return [math.log(2) ** k / math.factorial(k) for k in range(8)]


def emit_exp(p, x, out, t1, t2, t3):
    """out = exp(x). Uses temporaries t1, t2, t3 (x is kept)."""
    c = _coefs()
    p.const(t1, LOG2E)
    p.ins("MUL", t1, x, t1)                    # t = x * log2(e)
    p.const(t2, -126.0); p.ins("MAX", t1, t1, t2)
    p.const(t2, 127.0);  p.ins("MIN", t1, t1, t2)
    p.ins("FLOOR", t2, t1)                     # n = floor(t)
    p.ins("SUB", t1, t1, t2)                   # f = t - n, in [0, 1)
    p.ins("POW2I", t2, t2)                     # 2^n
    p.const(out, c[7])                         # 2^f = e^(f ln 2), degree-7 series
    for k in range(6, -1, -1):
        p.ins("MUL", out, out, t1)
        p.const(t3, c[k])
        p.ins("ADD", out, out, t3)
    p.ins("MUL", out, out, t2)                 # 2^f * 2^n


def emit_recip(p, a, out, t1, t2, iters=3):
    """out = 1 / a (a > 0): first guess, then Newton steps r = r (2 - a r)."""
    p.ins("RCPS", out, a)
    p.const(t2, 2.0)
    for _ in range(iters):
        p.ins("MUL", t1, a, out)
        p.ins("SUB", t1, t2, t1)
        p.ins("MUL", out, out, t1)


def emit_rsqrt(p, a, out, t1, t2, iters=3):
    """out = 1 / sqrt(a) (a > 0): first guess, then r = r (1.5 - 0.5 a r^2)."""
    p.ins("RSQS", out, a)
    for _ in range(iters):
        p.ins("MUL", t1, out, out)
        p.ins("MUL", t1, t1, a)
        p.const(t2, 0.5); p.ins("MUL", t1, t1, t2)
        p.const(t2, 1.5); p.ins("SUB", t1, t2, t1)
        p.ins("MUL", out, out, t1)


# ---- programs ----------------------------------------------------------------
def softmax(W, src=0, dst=64, tmp=128, ver=1):
    if ver == 2:
        return softmax_v2(W, src, dst, tmp)
    p = Program()
    p.ins("LD", 0, imm=src)                    # v0 = running max
    for i in range(1, W):
        p.ins("LD", 1, imm=src + i); p.ins("MAX", 0, 0, 1)
    p.ins("RMAX", 0, 0)                        # max over the whole row, every lane
    p.const(7, 0.0)                            # v7 = running sum
    for i in range(W):
        p.ins("LD", 1, imm=src + i)
        p.ins("SUB", 1, 1, 0)                  # x - max
        emit_exp(p, 1, 2, 3, 4, 5)             # v2 = exp(x - max)
        p.ins("ST", va=2, imm=tmp + i)
        p.ins("ADD", 7, 7, 2)
    p.ins("RSUM", 7, 7)                        # total
    emit_recip(p, 7, 6, 3, 4)                  # v6 = 1 / total
    for i in range(W):
        p.ins("LD", 1, imm=tmp + i)
        p.ins("MUL", 1, 1, 6)
        p.ins("ST", va=1, imm=dst + i)
    return p


def rmsnorm(W, n, eps=1e-6, src=0, gamma=32, dst=64, ver=1):
    if ver == 2:
        return rmsnorm_v2(W, n, eps, src, gamma, dst)
    p = Program()
    p.const(7, 0.0)
    for i in range(W):
        p.ins("LD", 1, imm=src + i)
        p.ins("MUL", 1, 1, 1)
        p.ins("ADD", 7, 7, 1)
    p.ins("RSUM", 7, 7)                        # sum of squares
    p.const(2, 1.0 / n); p.ins("MUL", 7, 7, 2) # mean
    p.const(2, eps);     p.ins("ADD", 7, 7, 2) # + eps
    emit_rsqrt(p, 7, 6, 3, 4)                  # v6 = 1 / sqrt(mean + eps)
    for i in range(W):
        p.ins("LD", 1, imm=src + i)
        p.ins("MUL", 1, 1, 6)
        p.ins("LD", 2, imm=gamma + i)
        p.ins("MUL", 1, 1, 2)
        p.ins("ST", va=1, imm=dst + i)
    return p


def silu(W, src=0, dst=64, ver=1):
    if ver == 2:
        return silu_v2(W, src, dst)
    p = Program()
    for i in range(W):
        p.ins("LD", 0, imm=src + i)
        p.const(1, -1.0); p.ins("MUL", 1, 0, 1)      # -x
        emit_exp(p, 1, 2, 3, 4, 5)                   # exp(-x)
        p.const(3, 1.0); p.ins("ADD", 2, 2, 3)       # 1 + exp(-x)
        emit_recip(p, 2, 6, 3, 4)                    # 1 / (1 + exp(-x))
        p.ins("MUL", 0, 0, 6)
        p.ins("ST", va=0, imm=dst + i)
    return p


# ---- version 2 programs (special functions, constant operands) ----------------
def softmax_v2(W, src=0, dst=64, tmp=128):
    p = Program()
    p.ins("LD", 0, imm=src)                    # v0 = running max
    for i in range(1, W):
        p.ins("LD", 1, imm=src + i); p.ins("MAX", 0, 0, 1)
    p.ins("RMAX", 0, 0)
    l2e = p.cidx(LOG2E)
    p.const(7, 0.0)                            # v7 = running sum
    for i in range(W):
        p.ins("LD", 1, imm=src + i)
        p.ins("SUB", 1, 1, 0)                  # x - max
        p.ins("MULC", 1, 1, imm=l2e)           # times log2(e)
        p.ins("EX2", 2, 1)                     # exp(x - max)
        p.ins("ST", va=2, imm=tmp + i)
        p.ins("ADD", 7, 7, 2)
    p.ins("RSUM", 7, 7)
    p.ins("RCP", 6, 7)                         # 1 / total
    for i in range(W):
        p.ins("LD", 1, imm=tmp + i)
        p.ins("MUL", 1, 1, 6)
        p.ins("ST", va=1, imm=dst + i)
    return p


def rmsnorm_v2(W, n, eps=1e-6, src=0, gamma=32, dst=64):
    p = Program()
    p.const(7, 0.0)
    for i in range(W):
        p.ins("LD", 1, imm=src + i)
        p.ins("MUL", 1, 1, 1)
        p.ins("ADD", 7, 7, 1)
    p.ins("RSUM", 7, 7)
    p.ins("MULC", 7, 7, imm=p.cidx(1.0 / n))   # mean
    p.ins("ADDC", 7, 7, imm=p.cidx(eps))       # + eps
    emit_rsqrt(p, 7, 6, 3, 4)                  # once per row: kept in software
    for i in range(W):
        p.ins("LD", 1, imm=src + i)
        p.ins("MUL", 1, 1, 6)
        p.ins("LD", 2, imm=gamma + i)
        p.ins("MUL", 1, 1, 2)
        p.ins("ST", va=1, imm=dst + i)
    return p


def silu_v2(W, src=0, dst=64):
    p = Program()
    nl2e, one = p.cidx(-LOG2E), p.cidx(1.0)
    for i in range(W):
        p.ins("LD", 0, imm=src + i)
        p.ins("MULC", 1, 0, imm=nl2e)          # -x log2(e)
        p.ins("EX2", 2, 1)                     # exp(-x)
        p.ins("ADDC", 2, 2, imm=one)           # 1 + exp(-x)
        p.ins("RCP", 6, 2)                     # 1 / (1 + exp(-x))
        p.ins("MUL", 0, 0, 6)
        p.ins("ST", va=0, imm=dst + i)
    return p


# ---- exact emulator --------------------------------------------------------------
def _lt(a, b):
    """The hardware's a < b on FP32 bit patterns (no NaNs)."""
    sa, sb = a >> 31, b >> 31
    ma, mb = a & 0x7FFFFFFF, b & 0x7FFFFFFF
    if sa != sb:
        return sa == 1 and not (ma == 0 and mb == 0)
    return ma > mb if sa else ma < mb


def _floor(a):
    ex = (a >> 23) & 0xFF
    if ex >= 150:
        mask = 0xFFFFFFFF
    elif ex < 127:
        mask = 0x80000000
    else:
        mask = ~(0x007FFFFF >> (ex - 127)) & 0xFFFFFFFF
    tr = a & mask
    if (a >> 31) and tr != a:
        return bits(from_bits(tr) + f32(-1.0))
    return tr


def _pow2i(a):
    ex = (a >> 23) & 0xFF
    mm = (1 << 23) | (a & 0x7FFFFF)
    if ex < 127:
        k = 0
    elif ex > 133:
        k = 200
    else:
        k = (mm >> 16) >> (134 - ex)
    n = -k if a >> 31 else k
    n = max(-126, min(127, n))
    return ((n + 127) & 0xFF) << 23


def _tree(vals, fn):
    while len(vals) > 1:
        vals = [fn(vals[2 * i], vals[2 * i + 1]) for i in range(len(vals) // 2)]
    return vals[0]


def emulate(prog, vmem, L):
    """Run a program. vmem: dict address -> list of L FP32 bit patterns."""
    vr = [[0] * L for _ in range(8)]
    consts = prog.consts
    add = lambda a, b: bits(from_bits(a) + from_bits(b))
    sub = lambda a, b: bits(from_bits(a) - from_bits(b))
    mul = lambda a, b: bits(from_bits(a) * from_bits(b))
    ticks = 0
    with np.errstate(all="ignore"):
        for w in prog.words():
            ticks += 1
            op, vd, va, vb, imm = w >> 26, (w >> 23) & 7, (w >> 20) & 7, (w >> 17) & 7, w & 0x1FFFF
            A, B = vr[va], vr[vb]
            if op == 0:
                break
            elif op == 1: vr[vd] = list(vmem[imm & 0xFF])
            elif op == 2: vmem[imm & 0xFF] = list(A)
            elif op == 3: vr[vd] = [add(a, b) for a, b in zip(A, B)]
            elif op == 4: vr[vd] = [sub(a, b) for a, b in zip(A, B)]
            elif op == 5: vr[vd] = [mul(a, b) for a, b in zip(A, B)]
            elif op == 6: vr[vd] = [b if _lt(a, b) else a for a, b in zip(A, B)]
            elif op == 7: vr[vd] = [a if _lt(a, b) else b for a, b in zip(A, B)]
            elif op == 8: vr[vd] = [_tree(list(A), add)] * L
            elif op == 9: vr[vd] = [_tree(list(A), lambda x, y: y if _lt(x, y) else x)] * L
            elif op == 10: vr[vd] = [consts[imm & 63]] * L
            elif op == 11: vr[vd] = [_floor(a) for a in A]
            elif op == 12: vr[vd] = [_pow2i(a) for a in A]
            elif op == 13: vr[vd] = [(0x7EF311C3 - (a & 0x7FFFFFFF)) & 0xFFFFFFFF for a in A]
            elif op == 14: vr[vd] = [(0x5F3759DF - ((a & 0x7FFFFFFF) >> 1)) & 0xFFFFFFFF for a in A]
            elif op == 15: vr[vd] = [ex2_bits(a) for a in A]
            elif op == 16: vr[vd] = [rcp_bits(a) for a in A]
            elif op in (17, 18, 19, 20, 21):
                c = consts[imm & 63]
                f = {17: lambda a: add(a, c), 18: lambda a: sub(a, c), 19: lambda a: mul(a, c),
                     20: lambda a: c if _lt(a, c) else a, 21: lambda a: a if _lt(a, c) else c}[op]
                vr[vd] = [f(a) for a in A]
    return vmem, ticks
