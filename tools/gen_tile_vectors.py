#!/usr/bin/env python3
"""Test data for the tiling controller (rtl/matmul_unit.v).

Makes random matrices A (M x K) and B (K x Nc) in MX formats, lays them out
in memory the way the controller expects (see matmul_unit.v), and computes
the expected C with the independent reference (exact block totals, one FP32
rounding per block: same rule as the version 4/5 engines).

Usage: python3 tools/gen_tile_vectors.py N MT NT KBLOCKS FA FB OUT_PREFIX [SEED]
  M = MT*N, Nc = NT*N, K = 32*KBLOCKS; formats 0 INT8, 1 FP8, 2 FP4
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from fp32_ref import fadd_ref                         # noqa: E402
from gen_v4_vectors import FP4, INT8, rand_code, val  # noqa: E402

BLOCK = 32


def main():
    N, MT, NT, KB, fa, fb = (int(v) for v in sys.argv[1:7])
    pre = sys.argv[7]
    random.seed(int(sys.argv[8]) if len(sys.argv) > 8 else 1)
    M, Nc, K = MT * N, NT * N, BLOCK * KB
    pair = fa == FP4 and fb == FP4
    A = [[rand_code(fa, "rand") for _ in range(K)] for _ in range(M)]
    B = [[rand_code(fb, "rand") for _ in range(Nc)] for _ in range(K)]
    sa = [[random.randrange(112, 142) for _ in range(KB)] for _ in range(M)]
    sb = [[random.randrange(112, 142) for _ in range(Nc)] for _ in range(KB)]

    beats = K // 2 if pair else K
    bb = BLOCK // 2 if pair else BLOCK

    def lane(fmt, code):
        return (code & 15) | (random.randrange(16) << 4) if fmt == FP4 else code

    def word(lanes, width=8):
        w = 0
        for n, v in enumerate(lanes):
            w |= v << (n * width)
        return w

    hexw = lambda bits: (bits + 3) // 4
    with open(pre + "_a.hex", "w") as fh:
        for mt in range(MT):
            for t in range(beats):
                if pair:
                    ln = [A[mt * N + i][2 * t] | (A[mt * N + i][2 * t + 1] << 4) for i in range(N)]
                else:
                    ln = [lane(fa, A[mt * N + i][t]) for i in range(N)]
                fh.write(f"{word(ln):0{hexw(8 * N)}x}\n")
    with open(pre + "_b.hex", "w") as fh:
        for nt in range(NT):
            for t in range(beats):
                if pair:
                    ln = [B[2 * t][nt * N + j] | (B[2 * t + 1][nt * N + j] << 4) for j in range(N)]
                else:
                    ln = [lane(fb, B[t][nt * N + j]) for j in range(N)]
                fh.write(f"{word(ln):0{hexw(8 * N)}x}\n")
    with open(pre + "_sa.hex", "w") as fh:
        for mt in range(MT):
            for kb in range(KB):
                fh.write(f"{word([sa[mt * N + i][kb] for i in range(N)]):0{hexw(8 * N)}x}\n")
    with open(pre + "_sb.hex", "w") as fh:
        for nt in range(NT):
            for kb in range(KB):
                fh.write(f"{word([sb[kb][nt * N + j] for j in range(N)]):0{hexw(8 * N)}x}\n")

    adj = 6 * (fa == INT8) + 6 * (fb == INT8)
    with open(pre + "_c.hex", "w") as fh:
        for m in range(M):
            for nt in range(NT):
                row = []
                for j in range(N):
                    n = nt * N + j
                    acc = 0
                    for kb in range(KB):
                        s = sum(val(fa, A[m][k]) * val(fb, B[k][n])
                                for k in range(kb * BLOCK, (kb + 1) * BLOCK))
                        acc = fadd_ref(acc, s, sa[m][kb] + sb[kb][n] - 272 - adj)
                    row.append(acc)
                fh.write(f"{word(row, 32):0{hexw(32 * N)}x}\n")
    with open(pre + "_cfg.hex", "w") as fh:
        fh.write(f"{MT:x}\n{NT:x}\n{beats:x}\n{bb:x}\n{KB:x}\n{fa:x}\n{fb:x}\n")
    print(f"tile vectors: C {M}x{Nc}, K {K}, {MT * NT} jobs of {beats} beats")


if __name__ == "__main__":
    main()
