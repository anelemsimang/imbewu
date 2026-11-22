#!/usr/bin/env python3
"""Test data for the tile (rtl/tile_v1.v): a list of matrix multiplies laid
out in main memory, the tile's command list, and the expected answers.

Usage: python3 tools/gen_tile_v1_vectors.py N NCMDS OUT_PREFIX [SEED] [SHAPE]
  SHAPE "mixed" (default): random shapes and formats per command
  SHAPE "same":  every command 2x2 tiles, K = 64, FP8 x FP4 (little reuse)
  SHAPE "reuse": every command 3x3 tiles, K = 96, FP8 x FP4 (more reuse)
Writes: OUT_PREFIX_mem.hex   main-memory image (one N-byte word per line)
        OUT_PREFIX_cmd.hex   one 200-bit command per line
        OUT_PREFIX_exp.hex   expected words of every answer region
        OUT_PREFIX_meta.hex  commands, memory words, expected words, beats
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gen_tile_vectors import build   # noqa: E402

HALF = 1024          # SRAM words per half (tile_v1 SAW = 10)


def pack(fields):
    w = 0
    for v, width in fields:
        w = (w << width) | (v & ((1 << width) - 1))
    return w


def main():
    N, ncmd = int(sys.argv[1]), int(sys.argv[2])
    pre = sys.argv[3]
    random.seed(int(sys.argv[4]) if len(sys.argv) > 4 else 7)
    shape = sys.argv[5] if len(sys.argv) > 5 else "mixed"
    mem, cmds, exp = [], [], []
    out_base = 1 << 18                           # answers go in the top half
    out_ptr = out_base
    total_beats = 0
    for k in range(ncmd):
        if shape == "same":
            MT, NT, KB, fa, fb = 2, 2, 2, 1, 2
        elif shape == "reuse":                    # more work per word fetched
            MT, NT, KB, fa, fb = 3, 3, 3, 1, 2
        else:
            fa, fb = random.choice([(1, 1), (0, 0), (2, 2), (1, 2), (0, 2)])
            MT, NT, KB = random.randrange(1, 4), random.randrange(1, 4), random.randrange(1, 4)
        r = build(N, MT, NT, KB, fa, fb)
        c = r["cfg"]
        assert max(len(r["a"]), len(r["b"]), len(r["c"])) <= HALF
        in_addr = len(mem)
        for key in ("a", "b", "sa", "sb"):
            mem.extend(r[key])
        cmds.append(pack([(in_addr, 20), (len(r["a"]), 16), (len(r["b"]), 16),
                          (len(r["sa"]), 12), (len(r["sb"]), 12), (out_ptr, 20),
                          (len(r["c"]), 16), (c["mt"], 8), (c["nt"], 8), (c["beats"], 16),
                          (c["bb"], 16), (c["nb"], 16), (c["fa"], 2), (c["fb"], 2), (0, 20)]))
        for cw in r["c"]:                         # each C word = 4 memory words
            for q in range(4):
                exp.append((out_ptr, (cw >> (8 * N * q)) & ((1 << (8 * N)) - 1)))
                out_ptr += 1
        total_beats += c["mt"] * c["nt"] * c["beats"]
    hw = (8 * N + 3) // 4
    with open(pre + "_mem.hex", "w") as fh:
        fh.writelines(f"{w:0{hw}x}\n" for w in mem)
    with open(pre + "_cmd.hex", "w") as fh:
        fh.writelines(f"{w:050x}\n" for w in cmds)
    with open(pre + "_exp.hex", "w") as fh:
        fh.writelines(f"{a:05x}{w:0{hw}x}\n" for a, w in exp)
    with open(pre + "_meta.hex", "w") as fh:
        fh.write(f"{ncmd:x}\n{len(mem):x}\n{len(exp):x}\n{total_beats:x}\n")
    print(f"tile_v1 vectors: {ncmd} commands, {len(mem)} input words, "
          f"{len(exp)} answer words, {total_beats} engine beats")


if __name__ == "__main__":
    main()
