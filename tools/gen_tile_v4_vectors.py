#!/usr/bin/env python3
"""Test data for tile_v4 (rtl/tile_v4.v): three chained layers on one tile.

  command 0: X (tokens x K0) times W0, then the vector unit's program on
             every row (pmode 2), rounded to FP8 MX blocks -> region R1
  command 1: waits for command 0 (dep), reads R1 as its activations, times
             W1, rounded straight into MX blocks of format OUT1 (pmode 1)
             -> region R2
  command 2: waits for command 1, reads R2, times W2, FP32 answers (pmode 0)

Expected values come from independent references: exact block sums with
one FP32 rounding per block (fp32_ref.fadd_ref), the vector unit's
bit-exact emulator (vu_asm.emulate), and the compiler's MX rounding
(real_model_on_chip.block_codes). Every word of R1, R2 and the final
answers is checked.

Usage: python3 tools/gen_tile_v4_vectors.py N PROGRAM OUT1 OUT_PREFIX [SEED]
  PROGRAM: silu | softmax | rmsnorm      OUT1: mxint8 | mxfp8 | mxfp4
"""
import os
import random
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from fp32_ref import fadd_ref                       # noqa: E402
from gen_tile_v1_vectors import pack                # noqa: E402
from gen_v4_vectors import FP8, rand_code, val      # noqa: E402
from real_model_on_chip import block_codes          # noqa: E402
import vu_asm                                       # noqa: E402

BLOCK = 32
FMT = {"mxint8": 0, "mxfp8": 1, "mxfp4": 2}


def word(lanes, width=8):
    out = 0
    for n, v in enumerate(lanes):
        out |= (v & ((1 << width) - 1)) << (n * width)
    return out


def matmul(A, sa, fa, W, sw, fb, K):
    """A [M][K] codes, sa [M][KB]; W [NO][K] codes, sw [NO][KB] -> C bits [M][NO]."""
    KB = K // BLOCK
    adj = 6 * (fa == 0) + 6 * (fb == 0)       # MX INT8 elements are code / 64 (as the engine does)
    va = [[val(fa, c) for c in row] for row in A]
    vw = [[val(fb, c) for c in row] for row in W]
    C = []
    for m in range(len(A)):
        row = []
        for n in range(len(W)):
            acc = 0
            for kb in range(KB):
                s = sum(va[m][k] * vw[n][k] for k in range(kb * BLOCK, (kb + 1) * BLOCK))
                acc = fadd_ref(acc, s, sa[m][kb] + sw[n][kb] - 272 - adj)
            row.append(acc)
        C.append(row)
    return C


def main():
    N, prog_name, out1 = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    pre = sys.argv[4]
    random.seed(int(sys.argv[5]) if len(sys.argv) > 5 else 3)
    MT = 2                                    # token tiles: M = 2N tokens
    M = MT * N
    K0 = 64
    NT0 = 32 // N                             # 32 outputs: next layer's K (one MX block)
    NT1 = 64 // N                             # 64 outputs: two blocks
    NT2 = 2
    K1, K2 = NT0 * N, NT1 * N
    W_ = NT0                                  # vector-unit row length (words); one program for the run
    prog = {"silu": lambda: vu_asm.silu(W_),
            "softmax": lambda: vu_asm.softmax(W_),
            "rmsnorm": lambda: vu_asm.rmsnorm(W_, W_ * N)}[prog_name]()
    gamma = [vu_asm.bits(np.float32(random.uniform(0.5, 1.5))) for _ in range(W_ * N)]
    vpre = {32 + w: gamma[w * N:(w + 1) * N] for w in range(W_)} if prog_name == "rmsnorm" else {}

    def rand_mat(rows, K):
        return ([[rand_code(FP8, "rand") for _ in range(K)] for _ in range(rows)],
                [[random.randrange(112, 121) for _ in range(K // BLOCK)] for _ in range(rows)])

    X, sx = rand_mat(M, K0)
    W0, s0 = rand_mat(NT0 * N, K0)
    W1, s1 = rand_mat(NT1 * N, K1)
    W2, s2 = rand_mat(NT2 * N, K2)

    def post(C, NT, fmt, run_prog):
        """Rows of C (FP32 bits) -> (codes [M][NT*N], scales [M][KB]) as the tile does it."""
        codes, scales = [], []
        for r in range(M):
            vm = {w: C[r][w * N:(w + 1) * N] for w in range(NT)}
            if run_prog:
                vm.update({a: list(v) for a, v in vpre.items()})
                vm, _ = vu_asm.emulate(prog, vm, N)
                vals = [b for w in range(NT) for b in vm[64 + w]]
            else:
                vals = [b for w in range(NT) for b in vm[w]]
            f = np.array(vals, dtype=np.uint32).view(np.float32).astype(np.float64)
            rc, rs = [], []
            for b in range(NT * N // BLOCK):
                c, s = block_codes(f[b * BLOCK:(b + 1) * BLOCK], fmt)
                rc += c
                rs.append(s)
            codes.append(rc)
            scales.append(rs)
        return codes, scales

    def a_layout(codes, scales, K):
        """Input layout: tile m, column k -> word m*K + k (lane = token); then scales."""
        KB = K // BLOCK
        words = [word([codes[m * N + i][k] for i in range(N)]) for m in range(MT) for k in range(K)]
        words += [word([scales[m * N + i][kb] for i in range(N)]) for m in range(MT) for kb in range(KB)]
        return words

    def b_layout(Wm, sw, NT, K):
        KB = K // BLOCK
        words = [word([Wm[t * N + j][k] for j in range(N)]) for t in range(NT) for k in range(K)]
        words += [word([sw[t * N + j][kb] for j in range(N)]) for t in range(NT) for kb in range(KB)]
        return words

    # expected chain
    C0 = matmul(X, sx, FP8, W0, s0, FP8, K0)
    q1, e1 = post(C0, NT0, "mxfp8", True)
    f1 = FMT[out1]
    C1 = matmul(q1, e1, FMT["mxfp8"], W1, s1, FP8, K1)
    q2, e2 = post(C1, NT1, out1, False)
    C2 = matmul(q2, e2, f1, W2, s2, FP8, K2)

    # main memory
    mem = []
    def place(words, align=4):
        mem.extend([0] * (-len(mem) % align))
        at = len(mem)
        mem.extend(words)
        return at
    x_at = place(a_layout([[c for c in r] for r in X], sx, K0))
    w_at = [place(b_layout(W0, s0, NT0, K0)), place(b_layout(W1, s1, NT1, K1)), place(b_layout(W2, s2, NT2, K2))]
    R1, R2, OUT = 1 << 17, (1 << 17) + 4096, 1 << 18

    def cmd(in_addr, K, NT, out, slot, fa, pmode, pfmt, dep, wat):
        KB = K // BLOCK
        c = pack([(in_addr, 20), (MT * K, 16), (NT * K, 16), (MT * KB, 12), (NT * KB, 12), (out, 20),
                  (MT * N * NT, 16), (MT, 8), (NT, 8), (K, 16), (BLOCK, 16), (KB, 16), (fa, 2), (FP8, 2),
                  (slot, 1), (0, 1), (wat // 4, 18)])
        return (pmode << 222) | (pfmt << 220) | (dep << 219) | c

    cmds = [cmd(x_at, K0, NT0, R1, 0, FP8, 2, FMT["mxfp8"], 0, w_at[0]),
            cmd(R1, K1, NT1, R2, 1, FMT["mxfp8"], 1, f1, 1, w_at[1]),
            cmd(R2, K2, NT2, OUT, 0, f1, 0, 0, 1, w_at[2])]
    exp = []
    for at, words in ((R1, a_layout(q1, e1, K1)), (R2, a_layout(q2, e2, K2))):
        exp += [(at + i, w) for i, w in enumerate(words)]
    for r in range(M):
        for t in range(NT2):
            full = word(C2[r][t * N:(t + 1) * N], 32)
            cw = r * NT2 + t
            for q in range(4):
                exp.append((OUT + 4 * cw + q, (full >> (8 * N * q)) & ((1 << (8 * N)) - 1)))
    beats = MT * NT0 * K0 + MT * NT1 * K1 + MT * NT2 * K2

    hw = 2 * N
    with open(pre + "_mem.hex", "w") as fh:
        fh.writelines(f"{w:0{hw}x}\n" for w in mem)
    with open(pre + "_cmd.hex", "w") as fh:
        fh.writelines(f"{c:056x}\n" for c in cmds)
    with open(pre + "_exp.hex", "w") as fh:
        fh.writelines(f"{a:05x}{d:0{hw}x}\n" for a, d in exp)
    with open(pre + "_vui.hex", "w") as fh:
        fh.writelines(f"{w:08x}\n" for w in prog.words())
    with open(pre + "_vuc.hex", "w") as fh:
        fh.writelines(f"{c:08x}\n" for c in (prog.consts or [0]))
    with open(pre + "_vuv.hex", "w") as fh:               # address, then the word
        fh.writelines(f"{a:02x}{word(v, 32):0{8 * N}x}\n" for a, v in sorted(vpre.items()))
    with open(pre + "_meta.hex", "w") as fh:
        fh.write("".join(f"{v:x}\n" for v in (len(cmds), len(mem), len(exp), beats, len(prog.words()),
                                               max(1, len(prog.consts)), len(vpre))))
    print(f"tile_v4 vectors: {M} tokens; layers {K0}->{K1}->{K2}->{NT2 * N}; program {prog_name} "
          f"({len(prog.words())} instructions), middle output {out1}; {len(exp)} words checked")


if __name__ == "__main__":
    main()
