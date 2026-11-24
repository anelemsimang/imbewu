#!/usr/bin/env python3
"""How much of a language model's time would the vector unit take? (W4)

Plain language: the engine does the matrix multiplies; the vector unit
does everything else (SiLU, softmax, RMSNorm, the rotary position code,
residual adds). Both are in each tile. This compares, per token and per
layer, the engine's ticks with the vector unit's ticks, for real model
shapes, several context lengths, and several vector-unit designs. If the
vector unit needs more ticks than the engine, it - not the engine - sets
the speed, however well the two overlap.

Engine: an N x N grid does N*N multiply-adds per tick (full use assumed,
which flatters the engine and so is the hard case for the vector unit).
Vector unit: N lanes, one instruction per tick; cost per vector of N
numbers = instructions per vector, counted from the real programs
(tools/vu_asm.py) for today's design ("v1"), and estimated by hand for the
options (each listed with how it was counted).

Usage: python3 tools/vu_budget.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import vu_asm                                       # noqa: E402

MODELS = {   # hidden, intermediate, heads, kv heads, head dim (public configs)
    "Qwen2.5-0.5B": (896, 4864, 14, 2, 64),
    "Llama-3-8B":   (4096, 14336, 32, 8, 128),
    "Llama-3-70B":  (8192, 28672, 64, 8, 128),
}


def measured_costs(ver):
    """Instructions per vector of N numbers in the real programs (marginal
    cost per extra vector, measured from the program generators)."""
    silu = len(vu_asm.silu(9, ver=ver).words()) - len(vu_asm.silu(8, ver=ver).words())
    soft = len(vu_asm.softmax(9, ver=ver).words()) - len(vu_asm.softmax(8, ver=ver).words())
    rms = len(vu_asm.rmsnorm(9, 144, ver=ver).words()) - len(vu_asm.rmsnorm(8, 128, ver=ver).words())
    return dict(silu=silu, softmax=soft, rmsnorm=rms, gate_mul=4, rope=6, residual=3)


def v1_costs():
    return measured_costs(1)


# Options, cost per vector (hand count; see the docstring of each line):
#  "const"  instructions take a constant directly (ADD/MUL/... with cmem):
#           removes every CONST load; results identical bit for bit.
#           exp 32 -> 21, 1/x 11 -> 10: SiLU 50 -> 36, softmax 41 -> 30.
#  "fma"    plus fused multiply-add with a constant (one step per polynomial
#           term): exp -> 15. SiLU -> 30, softmax -> 24. Changes rounding.
#  "v2"     what was built (D-024): 2^x and 1/x in one instruction each,
#           plus constant operands; counted from the real v2 programs.
def option_costs(v1):
    return {
        "v1 (today)": v1,
        "const operands": dict(v1, silu=36, softmax=30),
        "+ fused mul-add": dict(v1, silu=30, softmax=24),
        "v2 (built: 2^x, 1/x, constants)": measured_costs(2),
    }


def per_token_layer(model, ctx, N, cost):
    h, inter, heads, kv, hd = MODELS[model]
    macs = h * (h + 2 * kv * hd + h) + 3 * h * inter + 2 * heads * ctx * hd
    engine = macs / (N * N)
    numbers = dict(silu=inter, gate_mul=inter, rmsnorm=2 * h, softmax=heads * ctx,
                   rope=(heads + kv) * hd, residual=2 * h)
    vu = sum(numbers[k] / N * cost[k] for k in numbers)
    soft = numbers["softmax"] / N * cost["softmax"]
    return engine, vu, soft


def main():
    v1 = v1_costs()
    opts = option_costs(v1)
    print("Vector unit ticks as a share of engine ticks, per token per layer")
    print("(100% = the vector unit alone takes as long as the engine)\n")
    for N in (16, 32):
        print(f"Engine {N}x{N}, vector unit {N} lanes")
        head = "| Model | Context | " + " | ".join(opts) + " |"
        print(head)
        print("|" + "---|" * (2 + len(opts)))
        for model in MODELS:
            for ctx in (512, 4096, 32768):
                cells = []
                for name, cost in opts.items():
                    e, v, s = per_token_layer(model, ctx, N, cost)
                    cells.append(f"{100 * v / e:.0f}%")
                print(f"| {model} | {ctx} | " + " | ".join(cells) + " |")
        print()
    print("Instructions per vector of N numbers, today:", v1)


if __name__ == "__main__":
    main()
