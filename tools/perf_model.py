#!/usr/bin/env python3
"""Early performance model for an Imbewu data-centre chip (workstream W4).

Plain language: before anyone builds the chip, this estimates how fast it
would run a large language model, and which part of the chip (compute,
memory, or chip-to-chip links) limits it. Every chip number below is an
ASSUMPTION for a concept chip, clearly labelled, to be replaced as real
design numbers arrive (W2). The model is simple on purpose ("roofline"
style): each step takes as long as the slowest of compute, memory and links,
assuming they overlap perfectly. That makes it optimistic; real chips lose
some time to imperfect overlap and software.

The one part that is NOT an assumption is how the Imbewu engine itself
behaves: the tick counts come from the rules of the simulated design
(rtl/systolic_mx.v) and are checked against the simulation (--validate).

Usage:
  python3 tools/perf_model.py              # print the study, write results/
  python3 tools/perf_model.py --validate   # compare engine model vs RTL simulation
"""
import argparse
import json
import math
import os
import random
import re
import subprocess
import sys
from dataclasses import asdict, dataclass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BLOCK = 32                      # MX block size
BITS = {"fp8": 8, "int8": 8, "fp4": 4, "bf16": 16}
PER_LANE = {"fp8": 1, "int8": 1, "fp4": 2}     # multiplies per cell per tick


# ------------------------------------------------------------------ engine
def engine_ticks(job_beats, N):
    """Ticks for one engine to run a list of back-to-back jobs.

    Rules of the design: a job of b beats occupies max(b, N) beat slots
    (jobs need at least N beats, so shorter ones must be padded with gaps),
    and the last output row leaves 2N ticks after the last beat.
    """
    return sum(max(b, N) for b in job_beats) + 2 * N


@dataclass
class Chip:
    name: str
    engines: int            # number of N x N engines on the chip
    N: int                  # engine size
    clock_ghz: float
    hbm_tbps: float         # memory bandwidth, TB/s
    hbm_gb: float           # memory capacity, GB
    link_gbps: float        # chip-to-chip bandwidth per chip, GB/s (one direction)
    cross_block: bool       # True: engine sums many MX blocks inside (planned v4)
    note: str = ""

    def peak_tflops(self, fmt):
        return 2 * self.engines * self.N ** 2 * PER_LANE[fmt] * self.clock_ghz / 1e3


def gemm_time(chip, M, K, Nout, fmt, count=1):
    """Seconds of compute for `count` independent (M x K) times (K x Nout)
    multiplies on one chip, and the share of engine time doing useful work.

    Each N x N block of the answer is a "tile". Today's engine (v3) runs one
    job per MX block of 32 and the partial answers are added up outside the
    engine. The planned engine (v4) adds blocks up inside, so one long job
    covers many blocks; when there are fewer tiles than engines, the long
    sum is split across engines ("split-K") and the parts added at the end.
    """
    N, E = chip.N, chip.engines
    tiles = count * math.ceil(M / N) * math.ceil(Nout / N)
    if chip.cross_block:
        split = max(1, min(E // tiles, K // (4 * N * PER_LANE[fmt])))
        job_beats = math.ceil(K / split / PER_LANE[fmt])
        jobs = tiles * split
    else:
        job_beats = BLOCK // PER_LANE[fmt]
        jobs = tiles * math.ceil(K / BLOCK)
    per_engine = math.ceil(jobs / E)
    ticks = engine_ticks([job_beats] * per_engine, N)
    useful = count * M * K * Nout / PER_LANE[fmt] / (E * N * N)
    return ticks / (chip.clock_ghz * 1e9), useful / ticks


# ------------------------------------------------------------------ model
@dataclass
class Model:
    name: str
    layers: int
    d: int                  # hidden size
    ffn: int                # MLP inner size
    heads: int
    kv_heads: int
    vocab: int

    @property
    def head_dim(self):
        return self.d // self.heads

    def linears(self):
        """(K, Nout) of every matrix multiply in one layer."""
        kv = self.kv_heads * self.head_dim
        return [(self.d, self.d), (self.d, kv), (self.d, kv), (self.d, self.d),
                (self.d, self.ffn), (self.d, self.ffn), (self.ffn, self.d)]

    def params(self):
        per_layer = sum(k * n for k, n in self.linears())
        return self.layers * per_layer + 2 * self.vocab * self.d


# Shapes from the public configuration files of open models
MODELS = {
    "8B-class": Model("8B-class (Llama-3-8B shape)", 32, 4096, 14336, 32, 8, 128256),
    "70B-class": Model("70B-class (Llama-3-70B shape)", 80, 8192, 28672, 64, 8, 128256),
}

CHIPS = {
    # Concept chip: ASSUMPTIONS for discussion, not a design.
    "imbewu-c1-v3": Chip("Imbewu C1, version 3 engine", engines=256, N=32, clock_ghz=1.5,
                         hbm_tbps=4.0, hbm_gb=96, link_gbps=800, cross_block=False,
                         note="assumed: 256 engines of 32x32, 1.5 GHz, 4 HBM3E stacks"),
    "imbewu-c1-v4": Chip("Imbewu C1, version 4 engine", engines=256, N=32, clock_ghz=1.5,
                         hbm_tbps=4.0, hbm_gb=96, link_gbps=800, cross_block=True,
                         note="as above, version 4 engine: sums MX blocks inside into FP32 (built, simulated)"),
}


def step_time(chip, model, tokens, ctx, w_fmt, a_fmt, tp, batch):
    """One forward step processing `tokens` new tokens per sequence for
    `batch` sequences, each with `ctx` tokens of history, on `tp` chips
    sharing the model (tensor parallel). Returns dict of times in seconds."""
    M = tokens * batch
    fmt = w_fmt if w_fmt == a_fmt else "fp8"   # mixed FP4 x FP8 runs at FP8 speed
    comp = 0.0
    utils = []
    for K, Nout in model.linears():
        t, u = gemm_time(chip, M, K, math.ceil(Nout / tp), fmt)
        comp += t
        utils.append(u)
    # attention products (Q x K and attention x V) in FP8. Query heads that
    # share one key/value head (grouped-query attention) are stacked into one
    # multiply, so a single new token still fills several rows of the engine.
    hd = model.head_dim
    group = model.heads // model.kv_heads
    kvh = math.ceil(model.kv_heads / tp)
    t1, _ = gemm_time(chip, tokens * group, hd, ctx, "fp8", count=kvh * batch)
    t2, _ = gemm_time(chip, tokens * group, ctx, hd, "fp8", count=kvh * batch)
    comp += t1 + t2
    comp *= model.layers

    wbytes = sum(k * n for k, n in model.linears()) * model.layers / tp
    wbytes *= (BITS[w_fmt] + 8 / BLOCK) / 8                   # plus one scale per block
    wbytes += model.vocab * model.d * 1 / tp                   # output layer in FP8
    kv = 2 * model.layers * ctx * model.kv_heads * model.head_dim * batch / tp  # FP8 cache
    mem = (wbytes + kv) / (chip.hbm_tbps * 1e12)

    # tensor parallel: two all-reduces of the activations per layer (BF16)
    link = 0.0
    if tp > 1:
        per_ar = 2 * (tp - 1) / tp * M * model.d * 2
        link = 2 * model.layers * per_ar / (chip.link_gbps * 1e9)
    total = max(comp, mem, link)
    bound = {comp: "compute", mem: "memory", link: "links"}[total]
    return dict(compute_s=comp, memory_s=mem, link_s=link, total_s=total, bound=bound,
                engine_util=sum(utils) / len(utils), weights_gb=wbytes / 1e9, kv_gb=kv / 1e9)


def study():
    rows = []
    for ck, chip in CHIPS.items():
        for mk, tp in (("8B-class", 1), ("70B-class", 1), ("70B-class", 4)):
            model = MODELS[mk]
            for w, a in (("fp8", "fp8"), ("fp4", "fp4"), ("fp4", "fp8")):
                for phase, tokens, batch in (("prefill 4k", 4096, 1),
                                              ("decode b=1", 1, 1),
                                              ("decode b=64", 1, 64)):
                    r = step_time(chip, model, tokens, 4096, w, a, tp, batch)
                    fits = (r["weights_gb"] + r["kv_gb"]) <= chip.hbm_gb
                    toks = tokens * batch / r["total_s"]
                    rows.append(dict(chip=ck, model=mk, chips=tp, weights=w, acts=a,
                                     phase=phase, tokens_per_s=round(toks),
                                     ms_per_step=round(1e3 * r["total_s"], 3),
                                     bound=r["bound"], engine_util=round(r["engine_util"], 3),
                                     fits_memory=fits))
    return rows


def write_report(rows, out_md, out_json):
    lines = ["| Chip | Model | Chips | W/A | Phase | Tokens/s (total) | ms/step | Limited by | Engine use (weight layers) | Fits in memory |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['chip']} | {r['model']} | {r['chips']} | {r['weights']}/{r['acts']} | "
                     f"{r['phase']} | {r['tokens_per_s']:,} | {r['ms_per_step']} | {r['bound']} | "
                     f"{100 * r['engine_util']:.0f}% | {'yes' if r['fits_memory'] else 'NO'} |")
    peaks = ["| Chip | FP8 peak TFLOPS | FP4 peak TFLOPS | HBM TB/s | HBM GB | Links GB/s | Assumptions |",
             "|---|---|---|---|---|---|---|"]
    for ck, c in CHIPS.items():
        peaks.append(f"| {ck} | {c.peak_tflops('fp8'):.0f} | {c.peak_tflops('fp4'):.0f} | "
                     f"{c.hbm_tbps} | {c.hbm_gb} | {c.link_gbps} | {c.note} |")
    os.makedirs(os.path.dirname(out_md), exist_ok=True)
    with open(out_md, "w") as fh:
        fh.write("# Imbewu early performance model - generated by tools/perf_model.py\n\n")
        fh.write("All chip numbers are assumptions for a concept chip. Roofline model: optimistic.\n\n")
        fh.write("\n".join(peaks) + "\n\n" + "\n".join(lines) + "\n")
    with open(out_json, "w") as fh:
        json.dump(dict(chips={k: asdict(c) for k, c in CHIPS.items()},
                       models={k: asdict(m) for k, m in MODELS.items()}, rows=rows), fh, indent=2)


# ------------------------------------------------------------------ validation
def validate():
    """Run job streams through the RTL engine and compare measured ticks with
    engine_ticks(). Uses the multi-format testbench and vector writer."""
    sys.path.insert(0, os.path.dirname(__file__))
    from gen_mx_vectors import make_job, write_vectors
    out = os.path.join(ROOT, "build", "perf_validate")
    os.makedirs(out, exist_ok=True)
    random.seed(7)
    results = []
    for N in (4, 8, 16):
        sim = os.path.join(out, f"tb_mx_{N}")
        subprocess.run(["iverilog", "-g2012", f"-DGRID_N={N}", "-o", sim,
                        os.path.join(ROOT, "rtl/pe_mx.v"), os.path.join(ROOT, "rtl/systolic_mx.v"),
                        os.path.join(ROOT, "tests/tb_systolic_mx.v")], check=True)
        for case in ("fp8 blocks", "fp4 blocks", "mixed lengths"):
            jobs = []
            for n in range(40):
                fmt = {"fp8 blocks": 1, "fp4 blocks": 2}.get(case, n % 3)
                j = make_job(N, fmt, "rand")
                if case != "mixed lengths":
                    j["beats"] = max(N, 32 // PER_LANE["fp4" if fmt == 2 else "fp8"])
                    j["K"] = j["beats"] * (2 if fmt == 2 else 1)
                    j["A"] = [row[:j["K"]] + [0] * (j["K"] - len(row)) for row in j["A"]]
                    j["B"] = (j["B"] + [[0] * N] * j["K"])[:j["K"]]
                jobs.append(j)
            pre = os.path.join(out, f"v_{N}_{case.replace(' ', '_')}")
            write_vectors(N, jobs, pre)
            log = subprocess.run(["vvp", "-n", sim, f"+PRE={pre}"], check=True,
                                 capture_output=True, text=True).stdout
            m = re.search(r"in (\d+) ticks", log)
            measured = int(m.group(1))
            predicted = engine_ticks([j["beats"] for j in jobs], N)
            ok = "PASS" in log
            results.append(dict(N=N, case=case, jobs=len(jobs), predicted=predicted,
                                measured=measured, sim_pass=ok))
            print(f"N={N:2d} {case:13s}: predicted {predicted} ticks, measured {measured}, "
                  f"{'exact' if predicted == measured else 'DIFFERENT'}, answers {'PASS' if ok else 'FAIL'}")
    good = all(r["predicted"] == r["measured"] and r["sim_pass"] for r in results)
    print("engine model vs RTL:", "all exact" if good else "MISMATCH")
    return good


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--validate", action="store_true")
    args = ap.parse_args()
    if args.validate:
        sys.exit(0 if validate() else 1)
    rows = study()
    write_report(rows, os.path.join(ROOT, "results", "perf_model.md"),
                 os.path.join(ROOT, "results", "perf_model.json"))
    print(open(os.path.join(ROOT, "results", "perf_model.md")).read())


if __name__ == "__main__":
    main()
