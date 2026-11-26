#!/usr/bin/env python3
"""Merge several Liberty (.lib or .lib.gz) cell libraries into one file,
leaving out the cells a flow must not use.

Usage: lib_merge.py OUT.lib "PATTERN ..." IN.lib[.gz] [IN ...]
  PATTERN: shell-style cell-name patterns to leave out (e.g. "*x1p*_ASAP7* SDF*")

Yosys reads one library for flip-flop mapping and ABC, but ASAP7 ships each
corner as five files (AO, INVBUF, OA, SIMPLE, SEQ). The library header
(units, operating conditions) comes from the first file; table templates
and other library-level groups are taken from every file, each name once;
then every cell of every file, except the patterns.
"""
import fnmatch
import gzip
import re
import sys


def read(path):
    op = gzip.open if path.endswith(".gz") else open
    with op(path, "rt") as f:
        return f.read().splitlines(keepends=True)


def top_items(lines):
    """Split the inside of `library (...) { ... }` into top-level items:
    (kind, name, text) with kind 'cell', 'group' or 'attr'."""
    items, i = [], 0
    while not re.match(r"^\s*library\s*\(", lines[i]):
        i += 1
    depth = lines[i].count("{") - lines[i].count("}")
    i += 1
    cur, cur_depth = None, 0
    for line in lines[i:]:
        if cur is None:
            if depth == 1 and line.strip() == "}":
                break                                   # end of library
            m = re.match(r'^\s*([A-Za-z_]+)\s*\(\s*"?([^")]*)"?\s*\)\s*\{', line)
            if m:
                cur = [m.group(1), m.group(2), [line]]
                cur_depth = line.count("{") - line.count("}")
                if cur_depth <= 0:
                    items.append(("group", f"{cur[0]}:{cur[1]}", "".join(cur[2]))); cur = None
                continue
            items.append(("attr", line.strip(), line))
        else:
            cur[2].append(line)
            cur_depth += line.count("{") - line.count("}")
            if cur_depth <= 0:
                kind = "cell" if cur[0] == "cell" else "group"
                items.append((kind, cur[1] if kind == "cell" else f"{cur[0]}:{cur[1]}", "".join(cur[2])))
                cur = None
    return items


def main():
    out, pats, *srcs = sys.argv[1:]
    pats = pats.split()
    first = read(srcs[0])
    head = next(n for n, l in enumerate(first) if re.match(r"^\s*library\s*\(", l))
    attrs, groups, cells, seen, dropped = [], [], [], set(), 0
    for k, src in enumerate(srcs):
        for kind, name, text in top_items(first if k == 0 else read(src)):
            if kind == "attr":
                if k == 0:
                    attrs.append(text)
            elif kind == "group":
                if name not in seen:
                    seen.add(name); groups.append(text)
            elif any(fnmatch.fnmatchcase(name, p) for p in pats):
                dropped += 1
            elif name not in seen:
                seen.add(name); cells.append(text)
    with open(out, "w") as f:
        f.writelines(first[:head + 1])
        f.writelines(attrs + groups + cells)
        f.write("}\n")
    print(f"{out}: {len(cells)} cells from {len(srcs)} files, {dropped} left out")


if __name__ == "__main__":
    main()
