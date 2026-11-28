#!/usr/bin/env python3
"""Simplified block outline for the engine's detailed routing (D-031).

The block's abstract (tools/w2_abstract.sh) lists every wire inside the block
as an obstruction: about 13,000 shapes per block, 830,000 for the 64 blocks,
too many for detailed routing in 15 GB. The engine routes over the blocks
only on M8/M9, so on M1-M7 the inside of a block is one solid obstruction
here. Shapes that reach into the edge strip (where the pins and the wires to
them are) are kept as they are, so routing next to the block stays exact.

Usage: tools/w2_simple_lef.py IN.lef OUT.lef [EDGE_UM] [LAYERS]
  EDGE_UM: width of the edge strip kept exact (default 2.0 µm)
  LAYERS:  layers merged inside (default M1,M2,M3,M4,M5,M6,M7)
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
edge = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
layers = (sys.argv[4] if len(sys.argv) > 4 else "M1,M2,M3,M4,M5,M6,M7").split(",")

lines = open(src).read().split("\n")
size = next(l for l in lines if l.strip().startswith("SIZE"))
w, h = map(float, re.findall(r"[-\d.]+", size)[:2])
x0, y0, x1, y1 = edge, edge, w - edge, h - edge

start = next(i for i, l in enumerate(lines) if l.strip() == "OBS")
end = next(i for i in range(start, len(lines)) if lines[i].strip() == "END")

out_obs, kept, dropped, layer = [], 0, 0, None
merged = set()
for l in lines[start + 1:end]:
    t = l.split()
    if t and t[0] == "LAYER":
        layer = t[1]
        out_obs.append(l)
        if layer in layers and layer not in merged:
            out_obs.append(f"     RECT  {x0:.3f} {y0:.3f} {x1:.3f} {y1:.3f} ;")
            merged.add(layer)
        continue
    if t and t[0] == "RECT" and layer in layers:
        a, b, c, d = map(float, t[1:5])
        if a >= x0 and b >= y0 and c <= x1 and d <= y1:
            dropped += 1
            continue
    if t and t[0] == "RECT":
        kept += 1
    out_obs.append(l)

open(dst, "w").write("\n".join(lines[:start + 1] + out_obs + lines[end:]))
print(f"simplified outline: {dropped} inside shapes merged, {kept} kept, "
      f"inner block {x0:.1f}-{x1:.1f} x {y0:.1f}-{y1:.1f} um on {','.join(layers)}")
