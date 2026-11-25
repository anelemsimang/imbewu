#!/usr/bin/env python3
"""Copy a Liberty (.lib) cell library, leaving out the cells a flow must not use.

Usage: lib_dont_use.py IN.lib OUT.lib CELL [CELL ...]
Our Yosys (0.33) has no dont-use option for ABC, so the synthesis step reads a
copy of the library without these cells (the SKY130 list comes from the
platform's config.mk in OpenROAD-flow-scripts).
"""
import re
import sys

src, dst, *drop = sys.argv[1:]
drop = set(drop)
head = re.compile(r'^\s*cell\s*\(\s*"?([A-Za-z0-9_]+)"?\s*\)')
out, depth, skipping, removed = [], 0, False, 0
with open(src) as f:
    for line in f:
        if not skipping:
            m = head.match(line)
            if m and m.group(1) in drop:
                skipping, depth, removed = True, 0, removed + 1
        if skipping:
            depth += line.count("{") - line.count("}")
            if depth <= 0 and "}" in line:
                skipping = False
            continue
        out.append(line)
with open(dst, "w") as f:
    f.writelines(out)
print(f"{removed} cells left out of {dst}")
