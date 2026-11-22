#!/usr/bin/env python3
"""Test data for tile_v2 (weights kept in the tile).

Groups of commands share one set of weights B: the first command of a group
loads B into a weight slot (alternating slots between groups); the others
reuse it and only bring new activations A. With RELOAD=1 every command
fetches B again (as tile_v1 must), for comparison.

Usage: python3 tools/gen_tile_v2_vectors.py N GROUPS PER_GROUP OUT_PREFIX [SEED] [RELOAD] [SHAPE] [SLOTS]
  SLOTS "alt" (default): groups alternate between the two weight slots
  SLOTS "one": every group uses slot 0, so new weights must wait for the
               previous group to finish (tests the slot safety rule)
  LAYOUT (9th argument) "v2" (default): A, B, A scales, B scales
         "v3": A, A scales, B, B scales (tile_v3 fetches weights separately)
  SHAPE "decode" (default): A = 1 tile of rows (few tokens), B = 3 tiles, K = 96
  SHAPE "mixed": random shapes and formats per group
Files as for gen_tile_v1_vectors.py.
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from gen_tile_v1_vectors import HALF, pack   # noqa: E402
from gen_tile_vectors import build           # noqa: E402


def main():
    N, groups, per = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    pre = sys.argv[4]
    random.seed(int(sys.argv[5]) if len(sys.argv) > 5 else 3)
    reload_all = len(sys.argv) > 6 and sys.argv[6] == "1"
    shape = sys.argv[7] if len(sys.argv) > 7 else "decode"
    slots = sys.argv[8] if len(sys.argv) > 8 else "alt"
    layout = sys.argv[9] if len(sys.argv) > 9 else "v2"
    mem, cmds, exp = [], [], []
    out_ptr = 1 << 18
    total_beats = 0
    for g in range(groups):
        if shape == "decode":
            # sizes can be changed with environment settings, to match the
            # RISC-V driver's compile-time settings (fw/tile_driver.c)
            NT, KB = int(os.environ.get("DEC_NT", 3)), int(os.environ.get("DEC_KB", 3))
            fa, fb = int(os.environ.get("DEC_FA", 1)), int(os.environ.get("DEC_FB", 2))
        else:
            fa, fb = random.choice([(1, 1), (0, 0), (2, 2), (1, 2), (0, 2)])
            NT, KB = random.randrange(1, 4), random.randrange(1, 4)
        raw = None
        for k in range(per):
            MT = int(os.environ.get("DEC_MT", 1)) if shape == "decode" else random.randrange(1, 4)
            r = build(N, MT, NT, KB, fa, fb, raw)
            raw = r["raw"]
            c = r["cfg"]
            load_b = reload_all or k == 0
            assert max(len(r["a"]), len(r["b"]), len(r["c"])) <= HALF
            in_addr = len(mem)
            if layout == "v3":
                mem.extend(r["a"] + r["sa"] + (r["b"] + r["sb"] if load_b else []))
            else:
                mem.extend(r["a"])
                if load_b:
                    mem.extend(r["b"])
                mem.extend(r["sa"])
                if load_b:
                    mem.extend(r["sb"])
            nb_w = len(r["b"]) if load_b else 0
            nsb_w = len(r["sb"]) if load_b else 0
            cmds.append(pack([(in_addr, 20), (len(r["a"]), 16), (nb_w, 16),
                              (len(r["sa"]), 12), (nsb_w, 12), (out_ptr, 20),
                              (len(r["c"]), 16), (c["mt"], 8), (c["nt"], 8), (c["beats"], 16),
                              (c["bb"], 16), (c["nb"], 16), (c["fa"], 2), (c["fb"], 2),
                              (g % 2 if slots == "alt" else 0, 1), (0, 19)]))
            for cw in r["c"]:
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
        fh.write(f"{len(cmds):x}\n{len(mem):x}\n{len(exp):x}\n{total_beats:x}\n")
    print(f"tile_v2 vectors: {len(cmds)} commands, {len(mem)} input words, "
          f"{len(exp)} answer words, {total_beats} engine beats")


if __name__ == "__main__":
    main()
