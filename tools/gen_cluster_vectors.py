#!/usr/bin/env python3
"""Test data for the multi-tile cluster (rtl/cluster.v).

One layer: P batches of N tokens times G groups of N output channels, K
inputs, FP8 x FP8 (MX). The G weight groups are shared out among T tiles
(group g goes to tile g mod T); each tile fetches each of its groups once
and reuses it for every batch of tokens (tile_v3 weight slots). Expected
answers come from the independent reference (exact block sums, one FP32
rounding per block). Main memory holds ONE copy of each batch of tokens
(A, then its scales), shared by every command and tile that uses it, and
one copy of each group's weights (B, then its scales) at its own address,
which the command gives in its w_at field (tile_v3.v).

Usage: python3 tools/gen_cluster_vectors.py N T G P KBLOCKS OUT_PREFIX [SEED] [OFF]
  OFF: bit mask of tiles switched off (spare / faulty); they get no work and
  the groups are shared among the working tiles.
Writes OUT_PREFIX_mem.hex, _cmd<t>.hex (one per tile), _exp.hex, _meta.hex
(T, memory words, answer words, engine beats, then commands per tile).
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from fp32_ref import fadd_ref                       # noqa: E402
from gen_tile_v1_vectors import HALF, pack          # noqa: E402
from gen_v4_vectors import FP8, rand_code, val      # noqa: E402

BLOCK = 32


def main():
    N, T, G, P, KB = (int(v) for v in sys.argv[1:6])
    pre = sys.argv[6]
    random.seed(int(sys.argv[7]) if len(sys.argv) > 7 else 11)
    off = int(sys.argv[8]) if len(sys.argv) > 8 else 0
    live = [t for t in range(T) if not (off >> t) & 1]
    assert live, "no working tile"
    K = BLOCK * KB
    M, NO = P * N, G * N
    A = [[rand_code(FP8, "rand") for _ in range(K)] for _ in range(M)]       # tokens x K
    W = [[rand_code(FP8, "rand") for _ in range(K)] for _ in range(NO)]      # outputs x K
    sa = [[random.randrange(112, 142) for _ in range(KB)] for _ in range(M)]
    sw = [[random.randrange(112, 142) for _ in range(KB)] for _ in range(NO)]
    assert K <= HALF and G * P <= 16 * len(live)

    def word(lanes, width=8):
        out = 0
        for n, v in enumerate(lanes):
            out |= v << (n * width)
        return out

    def a_words(p):
        return [word([A[p * N + i][t] for i in range(N)]) for t in range(K)]

    def sa_words(p):
        return [word([sa[p * N + i][kb] for i in range(N)]) for kb in range(KB)]

    def b_words(g):
        return [word([W[g * N + j][t] for j in range(N)]) for t in range(K)]

    def sb_words(g):
        return [word([sw[g * N + j][kb] for j in range(N)]) for kb in range(KB)]

    # expected answers, C[m][n]
    C = [[0] * NO for _ in range(M)]
    for m in range(M):
        for n in range(NO):
            acc = 0
            for kb in range(KB):
                s = sum(val(FP8, A[m][k]) * val(FP8, W[n][k]) for k in range(kb * BLOCK, (kb + 1) * BLOCK))
                acc = fadd_ref(acc, s, sa[m][kb] + sw[n][kb] - 272)
            C[m][n] = acc

    mem, exp, cmds = [], [], [[] for _ in range(T)]
    a_at, w_at = [], []
    for p in range(P):                               # tokens: one shared copy per batch
        a_at.append(len(mem))
        mem.extend(a_words(p) + sa_words(p))
    for g in range(G):                               # weights: one copy per group, at 4 x w_at
        mem.extend([0] * (-len(mem) % 4))
        w_at.append(len(mem) // 4)
        mem.extend(b_words(g) + sb_words(g))
    assert len(mem) < 1 << 18
    out_ptr = 1 << 18
    for li, t in enumerate(live):                     # group g -> the (g mod live)th working tile
        for slot_i, g in enumerate(range(li, G, len(live))):
            for p in range(P):
                load_b = p == 0
                cmds[t].append(pack([(a_at[p], 20), (K, 16), (K if load_b else 0, 16), (KB, 12),
                                     (KB if load_b else 0, 12), (out_ptr, 20), (N, 16), (1, 8), (1, 8),
                                     (K, 16), (BLOCK, 16), (KB, 16), (FP8, 2), (FP8, 2),
                                     (slot_i % 2, 1), (0, 1), (w_at[g], 18)]))
                for i in range(N):                     # C word i = row p*N+i, columns of group g
                    full = word([C[p * N + i][g * N + j] for j in range(N)], 32)
                    for q in range(4):
                        exp.append((out_ptr, (full >> (8 * N * q)) & ((1 << (8 * N)) - 1)))
                        out_ptr += 1
    hw = (8 * N + 3) // 4
    with open(pre + "_mem.hex", "w") as fh:
        fh.writelines(f"{w:0{hw}x}\n" for w in mem)
    for t in range(T):
        with open(pre + f"_cmd{t}.hex", "w") as fh:
            fh.writelines(f"{c:050x}\n" for c in cmds[t])
    with open(pre + "_exp.hex", "w") as fh:
        fh.writelines(f"{a:05x}{d:0{hw}x}\n" for a, d in exp)
    beats = G * P * K
    with open(pre + "_meta.hex", "w") as fh:
        fh.write(f"{T:x}\n{len(mem):x}\n{len(exp):x}\n{beats:x}\n" + "".join(f"{len(c):x}\n" for c in cmds))
    print(f"cluster vectors: {T} tiles, layer {M} tokens x {NO} outputs x K {K}, "
          f"{G * P} commands, {len(mem)} input words, {len(exp)} answer words")


if __name__ == "__main__":
    main()
