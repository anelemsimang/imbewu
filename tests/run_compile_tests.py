#!/usr/bin/env python3
"""Compiler tests (W3): random PyTorch linear layers of awkward sizes, run
through tools/imbewu_compile.py on the simulated tile (4x4 engine). Each must
be bit exact against the independent reference; the error against PyTorch's
full-precision answer is printed."""
import os
import sys

import torch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from imbewu_compile import imbewu_attention_scores, imbewu_linear   # noqa: E402

CASES = [  # tokens, inputs, outputs, activation format, weight format[, FP4 packed]
    (8, 64, 8, "mxfp8", "mxfp4"),
    (10, 64, 6, "mxfp8", "mxfp4"),     # padding of tokens and outputs
    (12, 100, 20, "mxint8", "mxint8"),  # padding of the inputs (K)
    (8, 64, 12, "mxfp4", "mxfp4"),     # two FP4 numbers per lane
    (16, 512, 15, "mxfp8", "mxfp4"),   # several commands, weights reused
    (14, 600, 16, "mxint8", "mxfp4"),  # 8 commands with packed FP4 weights
    (14, 600, 16, "mxint8", "mxfp4", False),  # same, FP4 one per byte: 16 commands
    (8, 96, 8, "mxfp4", "mxfp8"),      # FP4 activations packed two per byte
]
torch.manual_seed(1)
ok = True
for case in CASES:
    M, K, O, a, w = case[:5]
    pk = case[5] if len(case) > 5 else True
    lin = torch.nn.Linear(K, O, bias=False)
    x = torch.randn(M, K)
    y, r = imbewu_linear(lin, x, a, w, N=4, packed=pk, work=f"build/compile/test_{M}_{K}_{O}_{a}_{w}_{pk}")
    good = r["bit_exact_vs_reference"] and r["tile_pass"] and tuple(y.shape) == (M, O)
    ok &= good
    print(f"{'PASS' if good else 'FAIL'}  {M}x{K} @ {K}x{O}, {a} x {w}{'' if pk else ' (unpacked)'}: {r['commands']} commands, "
          f"bit exact {r['bit_exact_vs_reference']}, error vs PyTorch FP32 "
          f"{r['relative_error_vs_pytorch_fp32_pct']}%")
# attention scores with K split into two INT8 blocks (D-021)
q = torch.randn(8, 64)
k = torch.randn(12, 64)
k[:, 5] *= 40                                   # one large channel, as in real models
y, r = imbewu_attention_scores(q, k, N=4, work="build/compile/test_scores_split")
good = r["bit_exact_vs_reference"] and r["bit_exact_vs_fast_model"] and r["tile_pass"]
ok &= good
print(f"{'PASS' if good else 'FAIL'}  attention scores 8x64 @ 64x12, K split into two INT8 blocks: "
      f"bit exact vs reference {r['bit_exact_vs_reference']}, vs fast model {r['bit_exact_vs_fast_model']}")
print("compiler: all PASS" if ok else "compiler: FAIL")
sys.exit(0 if ok else 1)
