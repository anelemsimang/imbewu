#!/usr/bin/env python3
"""Writes rtl/vu_v2_tables.vh: the lookup tables of the vector unit's 2^x and
1/x instructions, from their definitions in tools/vu_asm.py (so the hardware
and the emulator use the very same numbers)."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from vu_asm import EX2_L1, EX2_L2, EX2_T, RCP_C      # noqa: E402

out = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "rtl", "vu_v2_tables.vh")
with open(out, "w") as fh:
    fh.write("// vu_v2_tables.vh - written by tools/gen_vu_v2_tables.py; do not edit.\n")
    fh.write(f"localparam [31:0] EX2_L1 = 32'd{EX2_L1};\nlocalparam [31:0] EX2_L2 = 32'd{EX2_L2};\n")
    fh.write("function [23:0] ex2_t; input [5:0] i; begin\n    case (i)\n")
    for i, v in enumerate(EX2_T):
        fh.write(f"    6'd{i}: ex2_t = 24'd{v};\n")
    fh.write("    endcase\nend endfunction\n")
    fh.write("function [95:0] rcp_c; input [6:0] i; begin   // {c0, c1, c2}, 32 bits each\n    case (i)\n")
    for i, (c0, c1, c2) in enumerate(RCP_C):
        fh.write(f"    7'd{i}: rcp_c = {{32'd{c0}, 32'd{c1}, 32'd{c2}}};\n")
    fh.write("    endcase\nend endfunction\n")
print("wrote", out)
