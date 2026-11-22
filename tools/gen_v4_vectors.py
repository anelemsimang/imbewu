#!/usr/bin/env python3
"""Test data and expected answers for the version 4 engine (rtl/systolic_v4.v).

Expected answers are computed independently of the design: element values
from ml_dtypes (via gen_mx_vectors.value_x512), exact block totals with
Python integers, and FP32 rounding with exact fractions (fp32_ref.py).

Usage: python3 tools/gen_v4_vectors.py N OUT_DIR [JOBS]
Scenarios: same (same format both sides), mixed (different formats),
           stress (extreme scales, cancellation, odd block lengths, gaps)
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from fp32_ref import fadd_ref                      # noqa: E402
from gen_mx_vectors import FP8_NAN, pack, value_x512  # noqa: E402

INT8, FP8, FP4, RSV = 0, 1, 2, 3
SAME = [(FP8, FP8), (INT8, INT8), (FP4, FP4)]
MIXED = [(FP4, FP8), (FP8, FP4), (INT8, FP8), (FP8, INT8), (INT8, FP4), (FP4, INT8), (RSV, FP8)]


def val(fmt, code):
    if fmt == RSV:
        return 0
    if fmt == FP4:
        return value_x512(FP4, code & 15)
    return value_x512(fmt, code)


def rand_code(fmt, style):
    if fmt == FP4:
        return random.choice([7, 15]) if style == "max" else random.randrange(16)
    if fmt == INT8:
        return random.choice([0x7F, 0x81]) if style == "max" else random.randrange(256)
    if fmt == FP8:
        if style == "max":
            return random.choice([0x7E, 0xFE])
        while True:
            c = random.randrange(256)
            if c not in FP8_NAN:
                return c
    return random.randrange(256)


def negate(fmt, code):
    if fmt == INT8:
        return (-((code - 256) if code >= 128 else code)) & 0xFF if code != 0x80 else 0x81
    if fmt == FP4:
        return code ^ 0x8
    return code ^ 0x80


def make_job(N, fa, fb, style):
    pair = fa == FP4 and fb == FP4
    blocks = []
    nblk = random.randrange(1, 6)
    for b in range(nblk):
        if style == "odd":
            K = random.randrange(1, 41)
        else:
            K = 32
        A = [[rand_code(fa, style) for _ in range(K)] for _ in range(N)]
        B = [[rand_code(fb, style) for _ in range(N)] for _ in range(K)]
        if style == "tiny":                      # results near the FP32 floor
            sa = [random.randrange(30, 75) for _ in range(N)]
            sb = [random.randrange(30, 75) for _ in range(N)]
        elif style == "extreme":
            sa = [random.choice([0, 1, 127, 253, 254]) for _ in range(N)]
            sb = [random.choice([0, 1, 127, 253, 254]) for _ in range(N)]
        else:
            sa = [random.randrange(110, 145) for _ in range(N)]
            sb = [random.randrange(110, 145) for _ in range(N)]
        blocks.append(dict(K=K, A=A, B=B, sa=sa, sb=sb))
        if style == "cancel" and b == 0:
            # the next block exactly cancels this one (same scales)
            B2 = [[negate(fb, c) for c in row] for row in B]
            blocks.append(dict(K=K, A=A, B=B2, sa=sa, sb=sb))
    # make sure the job has at least N beats
    beats = lambda bl: (bl["K"] + 1) // 2 if pair else bl["K"]
    while sum(beats(bl) for bl in blocks) < N:
        blocks.append(dict(K=32, A=[[rand_code(fa, style) for _ in range(32)] for _ in range(N)],
                           B=[[rand_code(fb, style) for _ in range(N)] for _ in range(32)],
                           sa=[127] * N, sb=[127] * N))
    return dict(fa=fa, fb=fb, pair=pair, blocks=blocks)


def job_beats(job, N):
    """List of (a lanes, b lanes, block_last, sa, sb) for every beat."""
    out = []
    for bl in job["blocks"]:
        K = bl["K"]
        if job["pair"]:
            nb = (K + 1) // 2
            for k in range(nb):
                lo, hi = 2 * k, 2 * k + 1
                a = [bl["A"][i][lo] | ((bl["A"][i][hi] if hi < K else 0) << 4) for i in range(N)]
                b = [bl["B"][lo][j] | ((bl["B"][hi][j] if hi < K else 0) << 4) for j in range(N)]
                out.append((a, b, k == nb - 1, bl["sa"], bl["sb"]))
        else:
            for k in range(K):
                a = [lane(job["fa"], bl["A"][i][k]) for i in range(N)]
                b = [lane(job["fb"], bl["B"][k][j]) for j in range(N)]
                out.append((a, b, k == K - 1, bl["sa"], bl["sb"]))
    return out


def lane(fmt, code):
    """An FP4 side uses the low nibble only: fill the high nibble with junk."""
    return (code & 15) | (random.randrange(16) << 4) if fmt == FP4 else code


def expected(job, N):
    rows = []
    for i in range(N):
        vals = []
        for j in range(N):
            acc = 0
            for bl in job["blocks"]:
                s = sum(val(job["fa"], bl["A"][i][k]) * val(job["fb"], bl["B"][k][j])
                        for k in range(bl["K"]))
                assert -(1 << 47) <= s < (1 << 47)
                e = bl["sa"][i] + bl["sb"][j] - 272 - 6 * (job["fa"] == INT8) - 6 * (job["fb"] == INT8)
                acc = fadd_ref(acc, s, e)
            vals.append(acc)
        rows.append(vals)
    return rows


def write_vectors(N, jobs, pre, gaps=False):
    stim, exp = [], []
    macs = 0
    for job in jobs:
        bts = job_beats(job, N)
        for n, (a, b, blast, sa, sb) in enumerate(bts):
            while gaps and random.random() < 0.25:     # idle beats with junk data
                stim.append(pack([(0, 1), (random.randrange(4), 2), (random.randrange(16), 4)] +
                                 [(random.randrange(256), 8)] * (4 * N)))
            jl = n == len(bts) - 1
            f = [(1, 1), (int(blast), 1), (int(jl), 1), (job["fa"], 2), (job["fb"], 2)]
            f += [(x, 8) for x in reversed(a)] + [(x, 8) for x in reversed(b)]
            f += [(x, 8) for x in reversed(sa)] + [(x, 8) for x in reversed(sb)]
            stim.append(pack(f))
        macs += N * N * sum(bl["K"] for bl in job["blocks"])
        for row in expected(job, N):
            exp.append(pack([(v, 32) for v in reversed(row)]))
    sw, ew = 7 + 32 * N, 32 * N
    hexw = lambda w: (w + 3) // 4
    with open(pre + "_stim.hex", "w") as fh:
        fh.writelines(f"{w:0{hexw(sw)}x}\n" for w in stim)
    with open(pre + "_exp.hex", "w") as fh:
        fh.writelines(f"{w:0{hexw(ew)}x}\n" for w in exp)
    with open(pre + "_meta.hex", "w") as fh:
        fh.write(f"{len(stim):x}\n{len(exp):x}\n{macs:x}\n0\n")


def main():
    N = int(sys.argv[1])
    out = sys.argv[2]
    jobs_per = int(sys.argv[3]) if len(sys.argv) > 3 else 60
    os.makedirs(out, exist_ok=True)
    random.seed(4000 + N)
    for scen in ("same", "mixed", "stress"):
        jobs = []
        for n in range(jobs_per):
            if scen == "same":
                fa, fb = SAME[n % len(SAME)]
                style = "max" if n < 3 else "rand"
            elif scen == "mixed":
                fa, fb = MIXED[n % len(MIXED)]
                style = "max" if n < len(MIXED) else "rand"
            else:
                fa, fb = random.choice(SAME + MIXED)
                style = ["extreme", "cancel", "odd", "tiny"][n % 4]
            jobs.append(make_job(N, fa, fb, style))
        write_vectors(N, jobs, os.path.join(out, f"v4_N{N}_{scen}"), gaps=(scen == "stress"))


if __name__ == "__main__":
    main()
