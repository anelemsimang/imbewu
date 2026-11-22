#!/usr/bin/env python3
"""Generate test data and expected answers for the multi-format engine.

The reference is deliberately independent of the chip design: element values
come from the ml_dtypes library (float8_e4m3fn, float4_e2m1fn), which follows
the OCP MX definitions, and sums are computed exactly with Python integers.

Usage: python3 tools/gen_mx_vectors.py N OUT_DIR [JOBS]
Writes, for each scenario (int8, fp8, fp4, mixed, mixed_gaps):
  mx_N<N>_<scen>_stim.hex  one input beat per line
  mx_N<N>_<scen>_exp.hex   one expected output row per line
  mx_N<N>_<scen>_meta.hex  beats, rows, element multiplies, valid beats
"""
import os
import random
import sys

import ml_dtypes
import numpy as np

INT8, FP8, FP4 = 0, 1, 2
FP8_NAN = (0x7F, 0xFF)          # not supported yet, never generated


def value_x512(fmt, code):
    """Exact value of one element, times 2^9 (always a whole number)."""
    if fmt == INT8:
        v = code - 256 if code >= 128 else code
        return v * 512
    if fmt == FP8:
        f = float(np.array([code], np.uint8).view(ml_dtypes.float8_e4m3fn)[0])
    else:
        f = float(np.array([code], np.uint8).view(ml_dtypes.float4_e2m1fn)[0])
    x = f * 512
    assert x == int(x)
    return int(x)


def rand_code(fmt, style):
    if fmt == FP4:
        if style == "max":
            return random.choice([0x7, 0xF])          # +/-6
        if style == "zero":
            return 0
        return random.randrange(16)
    if fmt == INT8:
        if style == "max":
            return random.choice([0x7F, 0x80])
        if style == "zero":
            return 0
        return random.randrange(256)
    # FP8 E4M3
    if style == "max":
        return random.choice([0x7E, 0xFE])            # +/-448
    if style == "zero":
        return random.choice([0x00, 0x80])            # +0 / -0
    if style == "sub":
        return random.choice([0x00, 0x80]) | random.randrange(8)   # subnormals
    while True:
        c = random.randrange(256)
        if c not in FP8_NAN:
            return c


def make_job(N, fmt, style):
    beats = N + random.randrange(2 * N + 1)
    per_lane = 2 if fmt == FP4 else 1
    K = beats * per_lane
    A = [[rand_code(fmt, style) for _ in range(K)] for _ in range(N)]
    B = [[rand_code(fmt, style) for _ in range(N)] for _ in range(K)]
    if style in ("max", "extreme_scale"):
        sa = [random.choice([0, 254]) for _ in range(N)]
        sb = [random.choice([0, 254]) for _ in range(N)]
    else:
        sa = [random.randrange(100, 155) for _ in range(N)]
        sb = [random.randrange(100, 155) for _ in range(N)]
    return dict(fmt=fmt, beats=beats, K=K, A=A, B=B, sa=sa, sb=sb)


def lanes(job, k_beat, N):
    """Byte for each lane of a_col and b_row on one beat."""
    a, b = [], []
    for i in range(N):
        if job["fmt"] == FP4:
            lo, hi = 2 * k_beat, 2 * k_beat + 1
            a.append(job["A"][i][lo] | (job["A"][i][hi] << 4))
            b.append(job["B"][lo][i] | (job["B"][hi][i] << 4))
        else:
            a.append(job["A"][i][k_beat])
            b.append(job["B"][k_beat][i])
    return a, b


def pack(fields):
    """fields: list of (value, width) from most to least significant."""
    word = 0
    for v, w in fields:
        word = (word << w) | (v & ((1 << w) - 1))
    return word


def write_vectors(N, jobs, pre, gaps=False):
    """Write stimulus, expected rows and meta files for a list of jobs."""
    stim_w = 4 + 4 * N * 8
    exp_w = N * 48 + N * 10
    stim, exp = [], []
    valid_beats = macs = 0
    for job in jobs:
        for k in range(job["beats"]):
            while gaps and random.random() < 0.3:
                stim.append(pack([(0, 1), (random.randrange(2), 1),
                                  (random.randrange(4), 2)] +
                                 [(random.randrange(256), 8)] * (4 * N)))
            a, b = lanes(job, k, N)
            last = k == job["beats"] - 1
            sa = job["sa"] if last else [0] * N
            sb = job["sb"] if last else [0] * N
            # lane i at bits [i*8 +: 8]: list most significant (lane N-1) first
            f = [(1, 1), (int(last), 1), (job["fmt"], 2)]
            f += [(x, 8) for x in reversed(a)] + [(x, 8) for x in reversed(b)]
            f += [(x, 8) for x in reversed(sa)] + [(x, 8) for x in reversed(sb)]
            stim.append(pack(f))
            valid_beats += 1
        macs += N * N * job["K"]
        fmt = job["fmt"]
        for i in range(N):
            vals, exps = [], []
            for j in range(N):
                s = sum(value_x512(fmt, job["A"][i][k]) * value_x512(fmt, job["B"][k][j])
                        for k in range(job["K"]))
                assert -(1 << 47) <= s < (1 << 47)
                vals.append(s)
                exps.append(job["sa"][i] + job["sb"][j] - 272)
            f = [(v, 48) for v in reversed(vals)] + [(e, 10) for e in reversed(exps)]
            exp.append(pack(f))

    hexw = lambda w: (w + 3) // 4
    with open(pre + "_stim.hex", "w") as fh:
        fh.writelines(f"{w:0{hexw(stim_w)}x}\n" for w in stim)
    with open(pre + "_exp.hex", "w") as fh:
        fh.writelines(f"{w:0{hexw(exp_w)}x}\n" for w in exp)
    with open(pre + "_meta.hex", "w") as fh:
        fh.write(f"{len(stim):x}\n{len(exp):x}\n{macs:x}\n{valid_beats:x}\n")


def main():
    N = int(sys.argv[1])
    out = sys.argv[2]
    jobs_per = int(sys.argv[3]) if len(sys.argv) > 3 else 200
    os.makedirs(out, exist_ok=True)
    random.seed(1000 + N)

    scenarios = {
        "int8": [INT8], "fp8": [FP8], "fp4": [FP4],
        "mixed": [INT8, FP8, FP4], "mixed_gaps": [INT8, FP8, FP4],
    }
    for scen, fmts in scenarios.items():
        jobs = []
        for n in range(jobs_per):
            fmt = fmts[n % len(fmts)] if scen.startswith("mixed") else fmts[0]
            style = ["max", "zero", "sub", "extreme_scale"][n] if n < 4 else "rand"
            if style == "sub" and fmt != FP8:
                style = "rand"
            jobs.append(make_job(N, fmt, style))
        gaps = scen == "mixed_gaps"

        write_vectors(N, jobs, os.path.join(out, f"mx_N{N}_{scen}"), gaps)


if __name__ == "__main__":
    main()
