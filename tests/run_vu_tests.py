#!/usr/bin/env python3
"""Vector-unit tests: softmax, RMSNorm and SiLU programs run on the
simulated vector unit (rtl/vu_v1.v). Each result must equal the exact
emulator (tools/vu_asm.py) bit for bit; accuracy against PyTorch (float64)
is reported."""
import os
import subprocess
import sys

import numpy as np
import torch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from vu_asm import bits, emulate, from_bits, rmsnorm, silu, softmax   # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "build", "vu")
VU_RTL = os.environ.get("IMBEWU_VU", "rtl/vu_v1.v")


def run(L, W, name, trials, rng, sim):
    ok, worst = True, 0.0
    for t in range(trials):
        x = (rng.standard_normal(W * L) * 3).astype(np.float32)
        vm = {a: [0] * L for a in range(256)}
        for a in range(W):
            vm[a] = [bits(v) for v in x[a * L:(a + 1) * L]]
        xd = x.astype(np.float64)
        if name == "softmax":
            p, ref = softmax(W), torch.softmax(torch.tensor(xd), 0).numpy()
        elif name == "rmsnorm":
            g = rng.standard_normal(W * L).astype(np.float32)
            for a in range(W):
                vm[32 + a] = [bits(v) for v in g[a * L:(a + 1) * L]]
            p, ref = rmsnorm(W, W * L), xd / np.sqrt((xd ** 2).mean() + 1e-6) * g
        else:
            p, ref = silu(W), xd / (1 + np.exp(-xd))
        pre = os.path.join(OUT, f"{name}_{L}_{W}_{t}")
        hw = lambda w: f"{w:0{8 * L}x}"
        with open(pre + "_imem.hex", "w") as fh:
            fh.writelines(f"{w:08x}\n" for w in p.words())
        with open(pre + "_cmem.hex", "w") as fh:
            fh.writelines(f"{c:08x}\n" for c in p.consts)
        with open(pre + "_vmem.hex", "w") as fh:
            for a in range(256):
                fh.write(hw(sum(v << (32 * i) for i, v in enumerate(vm[a]))) + "\n")
        emu, eticks = emulate(p, {a: list(v) for a, v in vm.items()}, L)
        log = subprocess.run(["vvp", "-n", sim, f"+PRE={pre}"], capture_output=True, text=True).stdout  # noqa
        lines = open(pre + "_out.hex").read().split()
        same = True
        for a in range(256):
            word = int(lines[a], 16) if "x" not in lines[a] else -1
            if word != sum(v << (32 * i) for i, v in enumerate(emu[a])):
                same = False
        y = np.array([from_bits(b) for a in range(W) for b in emu[64 + a]], dtype=np.float64)
        worst = max(worst, float(np.max(np.abs(y - ref) / np.maximum(np.abs(ref), 1e-30))))
        ok &= same
    ticks = log.strip().split("in ")[-1] if "finished" in log else "?"
    print(f"{'PASS' if ok else 'FAIL'}  {name:8s} {L} lanes x {W} vectors, {trials} rows: "
          f"hardware = emulator bit for bit: {ok}; worst error vs PyTorch {worst:.2e}; {ticks}")
    return ok


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = np.random.default_rng(5)
    ok = True
    for L, W in ((4, 4), (8, 2), (16, 2)):
        sim = os.path.join(OUT, f"tb_vu_{L}")
        subprocess.run(["iverilog", "-g2012", f"-DLANES={L}", "-o", sim] +
                       [os.path.join(ROOT, f) for f in ("rtl/fp32_add_fx.v", "rtl/fp32_ops.v", VU_RTL, "tests/tb_vu.v")],
                       check=True)
        for name in ("softmax", "rmsnorm", "silu"):
            ok &= run(L, W, name, 4, rng, sim)
    print("vector unit: all PASS" if ok else "vector unit: FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
