# Results log

Measured results from simulation and synthesis, newest at the bottom.
Every number here can be reproduced with `make test` and `make synth`.

## 2026-11-21 - Systolic engine scales from 4x4 to 16x16 (G1)

Design: `rtl/systolic_array.v`, INT8 inputs, INT32 results. One design file,
grid size set by the parameter N.

| Grid | Cells | Multiply-adds per job | Cycles per job | Results checked | Errors | Logic cells (Yosys generic) |
|------|-------|----------------------|----------------|-----------------|--------|-----------------------------|
| 4x4   | 16  | 64    | 12 | 16,048  | 0 | 19,160  |
| 8x8   | 64  | 512   | 24 | 64,192  | 0 | 74,651  |
| 16x16 | 256 | 4,096 | 48 | 256,768 | 0 | 300,332 |

Each size ran 1,003 matrix multiplications: identity, all-maximum (+127),
all-minimum (-128), and 1,000 random cases, each checked against a
reference calculation.

**Test strength check:** a deliberately broken version (wrong timing of the B
inputs) failed 2,968 of 3,392 checks at 8x8 and 12,719 of 13,568 at 16x16.
The tests catch real bugs.

**Findings**

1. **Scaling is clean.** Doubling the grid side gives 4x the cells, 8x the
   work per job, and only 2x the time per job. Size grows in proportion to
   the number of cells (about 1,170 logic cells each), so there are no hidden
   costs as the grid grows.
2. **Utilisation is about 33%.** In each job the cells spend roughly two-thirds
   of the time waiting while data fills and drains the grid
   (4,096 multiply-adds / (256 cells x 48 cycles) = 33%). Fix: stream the next
   job in while the current one drains, which should approach 100%. This is
   the next roadmap item. It matters for G1 (speed) and G5 (wasted power).

## 2026-11-21 - Streaming engine (version 2): utilisation 33% -> 99.5% (G1, G5)

Design: `rtl/systolic_stream.v` + `rtl/pe_stream.v`. Jobs flow through back
to back. Each number carries a "valid" and a "last" tag, so a cell knows when
a job ends and starts the next one on the very next tick. Finished answers
leave one row per tick while new work is still flowing in. As a bonus, the
shared matrix dimension K can be any length of at least N, so long matrix
products need no extra hardware.

Each size ran 300 back-to-back jobs (K varying from N to 3N, including the
identity, all +127 and all -128 cases), first with no gaps and then with
random gaps (30% of ticks idle).

| Grid | Results checked (both runs) | Errors | Utilisation, no gaps | Logic cells (Yosys generic) | Size vs v1 |
|------|-----------------------------|--------|----------------------|-----------------------------|------------|
| 4x4   | 9,600   | 0 | 99.5% | 20,346  | +6.2% |
| 8x8   | 38,400  | 0 | 99.5% | 80,872  | +8.3% |
| 16x16 | 153,600 | 0 | 99.5% | 322,493 | +7.4% |

Utilisation counts every tick from the first input to the last output,
including filling and emptying the grid at the very start and end.

**Test strength check:** a deliberately broken version (results read out one
tick too early) failed 400 of 3,200 checks in each run at 8x8. The tests
catch real bugs.

**What it means:** at 16x16, version 1 completed about 85 multiply-adds per
tick; version 2 completes about 255, **3x the work from a circuit only 7%
larger**. More work from the same silicon and the same idle power is
exactly what G1 and G5 ask for.

**Process note:** the first run of the new test reported thousands of errors.
The cause was in the test itself (the checker and the data generator shared
loop counters), not in the chip design. Fixed before any result was recorded.

## 2026-11-22 - Multi-format engine (version 3): INT8, FP8, FP4 with MX scales (G1)

Design: `rtl/systolic_mx.v` + `rtl/pe_mx.v`. Each job picks its number format
(INT8, FP8 E4M3 or FP4 E2M1, per the OCP Microscaling v1.0 element
definitions), and the format travels with the data, so jobs of different
formats run back to back. FP4 packs two numbers per lane. Each row of A and
each column of B carries a shared MX block scale (E8M0). Every product is
added exactly in a 48-bit fixed-point total, so results have **no rounding
error at all**; output = 48-bit value x 2^exponent.

Expected answers come from an independent Python model
(`tools/gen_mx_vectors.py`), which decodes numbers with the `ml_dtypes`
library rather than with my hardware logic, and sums with exact integers.

Each size ran 5 scenarios of 200 jobs (K from N to 3N beats): all-INT8,
all-FP8, all-FP4, mixed formats back to back, and mixed with 30% random
gaps. Special cases included: maximum values (+/-448 FP8, +/-6 FP4,
-128 INT8), +0/-0, FP8 subnormals, and extreme scales (2^-127 and 2^127).

| Grid | Results checked | Errors | INT8 / FP8 multiplies per cell per tick | FP4 multiplies per cell per tick |
|------|-----------------|--------|-------------------------------------------|----------------------------------|
| 4x4   | 16,000  | 0 | 0.99 | 1.99 |
| 8x8   | 64,000  | 0 | 0.99 | 1.99 |
| 16x16 | 256,000 | 0 | 0.99 | 1.98 |

**Test strength check:** three planted bugs, each caught: wrong FP8
subnormal handling (694 errors), wrong FP4 subnormal handling (790 errors),
scale exponent off by one (800 errors, every row).

**Size (Yosys generic cells):**

| | One cell | 4x4 grid | 8x8 grid |
|---|---|---|---|
| Version 2 (INT8 only) | 1,216 | 20,346 | 80,872 |
| Version 3 (INT8/FP8/FP4) | 2,646 | 46,517 | 183,605 |

**Honest assessment.** The multi-format cell is 2.2x the size of the
INT8-only cell. FP4's double speed wins that back, so per unit of silicon
FP4 matches INT8 and FP8 is about half. The main costs are the 48-bit exact
total (vs 32-bit) and a shifter in every cell. This is the expected first
version; the big efficiency gain of FP8/FP4 shows up against 16-bit and
32-bit formats (BF16/FP32), which data-centre chips also need and which are
far larger. Planned improvements:
1. Line up exponents once per block instead of in every cell (shared shifter).
2. Pack four FP4 numbers per lane (4x speed) using 16-bit lanes.
3. Add BF16 so the comparison that matters for data centres can be measured.

**Not supported yet:** the FP8 "not a number" code (S.1111.111) and the
E8M0 NaN scale (0xFF); FP8 E5M2 (used for training gradients); combining
several MX blocks into one FP32 total. All are on the roadmap.

## 2026-11-22 - Accuracy check: three public language models in MX formats

**Question.** When a real language model's maths is done in the formats the
Imbewu engine supports, how much accuracy is lost?

**Method.** `tools/accuracy_eval.py`. Every matrix multiply inside the
transformer layers had both its weights and its incoming activations rounded
to the MX format (blocks of 32, shared power-of-two scale), with products
summed in high precision, as the engine does. Accuracy measured as
perplexity on the WikiText-2 test set (lower is better), windows of 1,024
tokens. The rounding code was first checked against the ml_dtypes library on
200,000 numbers plus exact ties: 0 mismatches.

**Results (perplexity, and change vs full precision FP32):**

| Format | Qwen2.5-0.5B | SmolLM2-360M | Qwen2.5-1.5B |
|---|---|---|---|
| FP32 (reference) | 13.79 | 12.42 | 10.26 |
| MXINT8 | 13.87 (+0.6%) | 12.48 (+0.5%) | 10.29 (+0.3%) |
| MXFP8 E4M3 | 14.29 (+3.6%) | 12.90 (+3.8%) | 10.45 (+1.8%) |
| MXFP4 E2M1 | 33.09 (+140%) | 29.53 (+138%) | 15.48 (+51%) |
| MXFP4 weights + MXFP8 activations | 17.73 (+29%) | 18.06 (+45%) | 11.73 (+14%) |
| Tokens scored | 81,840 | 81,840 | 40,920 |

**Same data on the chip itself** (`tools/real_model_on_chip.py`): real
Qwen2.5-0.5B activations and weights through the simulated 16x16 engine; the
chip's answer equals the software maths exactly in every format. Error of
one matrix multiply vs FP32: layer 0 INT8 0.94%, FP8 3.85%, FP4 18.8%;
layer 12 INT8 0.81%, FP8 3.66%, FP4 11.3%.

**What this means, plainly.**
1. MXINT8 and MXFP8 are safe for inference: under 4% loss, and less on the
   bigger model. These are Imbewu's main inference formats.
2. Plain MXFP4 for everything is not acceptable on these small models.
3. FP4 hurts less as models get bigger (140% loss at 0.5B, 51% at 1.5B),
   which matches published work: data-centre models are far bigger still.
4. Keeping activations in FP8 and only weights in FP4 recovers most of the
   loss. **The current engine cannot do this**: both inputs of a job must use
   the same format. A mixed FP4 x FP8 mode is now a hardware requirement
   (decision D-015).

**Limits of this test (stated honestly).** Small models only (up to 1.5B
parameters). The token embedding, final output layer, normalisation and the
two attention products stayed in full precision. Plain rounding only, no
FP4 accuracy techniques (smaller blocks, rotations, or training the model to
expect FP4), which industry uses and which would narrow the FP4 gap. The
1.5B model was scored on half as many tokens to save time. Raw numbers:
`results/accuracy_*.json`.

## 2026-11-22 - Verification depth (W1): exhaustive cell test and formal proof

**1. Every possible input of one cell.** One multiply has only
4 formats x 256 x 256 = 262,144 possible inputs, so all of them were tested
(`make test-cell`, expected values from ml_dtypes). Result: 261,124 checked,
0 errors. 1,020 cases skipped: those that use the FP8 "not a number" code,
which is not supported yet. This is a complete check of the cell's decoding,
multiplying and shifting, not a sample.

**2. Formal proof of the engine's output rules** (`make formal`, Yosys with
the free Yices solver). The solver considers every possible input sequence:
any data, any format, any gaps, any scales, jobs back to back. Proven:

| Rule | Meaning |
|---|---|
| R1 | Every job gives exactly N output rows, in order, each at a fixed time after the job's last beat |
| R2 | No output row ever appears that does not belong to a job |
| R3 | Every row carries its own job's scales, never the neighbouring job's |

Proven by induction (holds for all time, not only for a test's length) at
grid sizes 2x2, 4x4, 8x8 and 16x16. Run times on this machine: under 1 s,
2 s, 13 s and 2 min 47 s. The proof needed 12 helper rules describing the
engine's internal state; it also confirms that the busiest case (jobs back
to back) is actually reachable, so the proof is not empty.

**3. Testing the tests** (`make mutants`): 10 bugs planted one at a time,
5 in the cell and 5 in the engine's control. All 10 caught. Examples: the
FP4 high nibble ignored, the scale pointer stuck, the last row of each job
dropped, the first row using the previous job's scales.

**What is still not formally proven:** that the long sums inside the grid
are right for every input. Those are checked by the exhaustive cell test
plus 336,000 random simulation answers, not by proof. Solvers struggle with
multipliers; the usual industry method is equivalence checking against a
reference, planned later. Not done yet: coverage measurement, Verilator lint.

## 2026-11-22 - Early performance model (W4)

**What it is.** `tools/perf_model.py` (`make perf`) estimates how fast an
Imbewu data-centre chip would run large language models, and which part of
the chip limits it: compute, memory (HBM) or chip-to-chip links.

**Checked against the simulated chip first.** The model's rule for how many
ticks the engine needs was compared with the RTL simulation on 9 job
streams (sizes 4, 8, 16; FP8, FP4, mixed lengths): **predicted = measured,
exactly, in all 9**.

**Concept chip "C1": assumptions, not a design.** 256 engines of 32x32
cells, 1.5 GHz, 4 HBM3E memory stacks (4 TB/s, 96 GB), 800 GB/s of links.
That is 786 TFLOPS FP8 peak and 1,573 TFLOPS FP4 peak. Two versions:
v3 = today's engine; v4 = planned engine that sums many MX blocks inside.
Workloads: the public shapes of 8B-class and 70B-class open models (Llama 3
configurations), 4,096 tokens of context. Full table: `results/perf_model.md`.

| Workload (one C1 chip unless stated) | FP8 | FP4, today's engine | FP4, planned engine |
|---|---|---|---|
| 8B: read a 4k prompt (tokens/s) | 48,800 | 48,800 | 86,100 |
| 8B: answer one user (tokens/s) | 501 | 889 | 889 |
| 8B: answer 64 users (tokens/s, total) | 10,300 | 12,000 | 12,000 |
| 70B: answer one user, 1 chip | 55 | 105 | 105 |
| 70B: answer one user, 4 chips | 221 | 420 | 420 |
| 70B: read a 4k prompt, 4 chips | 21,300 | 21,300 | 39,700 |

**What the model tells us.**
1. **Answering is limited by memory, not compute (goal G3 matters most).**
   When one user is served, the engines sit idle about 97% of the time,
   waiting for the model's weights to arrive from HBM. Speed per user is
   roughly memory bandwidth divided by model size. Faster memory, smaller
   weights (FP4) and serving many users at once are what help.
2. **Today's engine cannot use FP4's double speed.** An MX block of 32 FP4
   numbers takes only 16 beats, but a 32x32 engine needs jobs of at least 32
   beats, so half the time is padding (50% engine use). The planned engine
   that sums many blocks inside fixes this: 1.76x faster prompt reading.
   This makes precision v2 (cross-block sums) the top hardware priority
   for grids larger than 16x16 (decision D-016).
3. **FP4 weights nearly double answering speed** (501 to 889 tokens/s)
   because there is half as much to read from memory. The accuracy check
   showed FP4 weights need FP8 activations, so the mixed FP4 x FP8 mode
   (D-015) is what turns this into a real gain.
4. **Four chips answer four times faster** for the 70B model: each reads a
   quarter of the weights. With 800 GB/s links, the links never limit (G2),
   but that needs checking with a real link model.
5. A 70B model in FP8 serving 64 users does not fit in one chip's 96 GB.

**Limits (stated honestly).** Assumed chip numbers. Perfect overlap of
compute, memory and links (optimistic). No power model yet, so no
performance per watt (G5) until the energy-per-operation estimate and W2.
Adding up partial sums outside the engine (today's engine) is not costed.
No comparison with other companies' chips is made here; spec-sheet
comparisons would not be like for like.

## 2026-11-22 - Version 4 engine: block totals inside the cell, mixed formats

**What changed** (decisions D-015 and D-016). Files: `rtl/mx_mul.v`,
`rtl/fp32_add_fx.v`, `rtl/pe_v4.v`, `rtl/systolic_v4.v`.
1. **Mixed formats.** Each side of a job has its own format, so FP8
   activations can be multiplied by FP4 weights (and any other pairing of
   INT8, FP8 and FP4).
2. **Many MX blocks per job.** A job is now a whole row times a whole column
   (any length). Inside each block of 32 the cell adds exactly, as before;
   at the end of each block it applies the block's two scales and adds the
   result into a normal FP32 total, rounding once. The chip's output is now
   ordinary FP32 numbers, with nothing left to add up outside.
3. Jobs are long, so the 16-beat FP4 block no longer wastes half the engine
   on large grids (the problem found by the performance model).

**Checks** (all against independent Python references; `make test`):

| Check | Cases | Errors |
|---|---|---|
| Mixed-format multiplier, every possible input (16 format pairs) | 1,044,484 (+4,092 FP8 NaN skipped) | 0 |
| FP32 block-total adder vs exact-fraction reference (incl. 48,148 overflows, 16,618 tiny results, 657 exact ties, 12,530 near-cancellations) | 200,000 | 0 |
| Whole engine, 4x4 / 8x8 / 16x16: same formats, mixed formats, stress (extreme scales, exact cancellation, odd block lengths, gaps, tiny results) | 28,800 FP32 results | 0 |
| Formal proof of output rules R1-R2 (all time), v4 at 2x2, 4x4, 8x8 | - | proven |
| Planted bugs (8 new for v4, e.g. ties rounded wrongly, sticky bits ignored, INT8 factor missing, total not cleared between jobs) | 18 total | all caught |
| Timing rule used by the performance model, vs v4 simulation | 4 runs | exact |

**Real model data, one job per output** (`tools/real_model_on_chip_v4.py`):
Qwen2.5-0.5B, layer 0, a 16x896 by 896x16 multiply as a single job of
28 MX blocks on the 16x16 engine. The chip's FP32 answer equals the
reference bit for bit in all four configurations:

| Activations x weights | Beats | Error vs full precision |
|---|---|---|
| INT8 x INT8 | 896 | 0.94% |
| FP8 x FP8 | 896 | 3.85% |
| FP4 x FP4 | 448 | 18.84% |
| **FP8 x FP4 (new mixed mode)** | 896 | **14.22%** |

The mixed mode keeps FP4's memory saving for weights and cuts the error by
a quarter compared with FP4 on both sides.

**The cost (stated honestly).** One v4 cell is 11,260 generic logic cells,
4.3x the v3 cell (2,646). The multiplier is 2,077; the FP32 adder is 8,423,
three quarters of the cell. Also, the multiply, the 48-bit add and the FP32
add all happen in one tick, which would limit the clock speed. Both are
expected for a first version that is correct before it is small. Fix
planned (D-017): cells in a row reach the end of a block one tick apart,
so one FP32 adder can serve many cells in turn, and the adder can be split
over several ticks (pipelined). Estimated cell size with one shared adder
per 16 cells: about 3,000, close to v3.

## 2026-11-22 - Version 5 engine: shared, two-tick FP32 adders (D-017)

**What changed.** Same maths and answers as version 4, built smaller and
split into shorter steps. Files: `rtl/pe_v5.v`, `rtl/systolic_v5.v`; the
FP32 adder (`rtl/fp32_add_fx.v`) is now two halves that can run in
separate ticks.
1. **The cell has no FP32 adder of its own.** Cells in a row reach the end
   of a block one tick apart, so a group of up to G cells (G = 16) take
   turns on one shared adder.
2. **Shorter steps.** The multiply has its own tick; the shared adder takes
   two ticks (line up and add, then round). Output rows leave 2 ticks later
   than in version 4.
3. **New rule:** every MX block must have at least min(G, N) beats. A
   standard block of 32 numbers is 32 beats, or 16 when both sides are FP4,
   so standard blocks always qualify.

**Checks:**

| Check | Result |
|---|---|
| Whole engine vs the version 4 reference, 4x4 / 8x8 / 16x16, adders shared by 4 and by 16, same / mixed / stress | 0 errors (every answer bit-identical) |
| Real model data (Qwen2.5-0.5B, 28 blocks per job, 4 format pairings) | bit exact, same errors as version 4 |
| Formal proof R1-R2 (rows complete, in order, on time) and **R4: a shared adder is never double-booked** | proven for all time: 4x4 with groups of 2 and 4, 8x8 with groups of 4 and 8 |
| Is the block rule really needed? Proof re-run with blocks one beat shorter | solver finds a double-booking at once: the rule is exactly right |
| Planted bugs (5 new for version 5) | 23 of 23 caught in total |
| Timing | 2 ticks more than version 4, as designed (measured) |

**Size (Yosys generic cells):**

| | Per cell | 4x4 grid |
|---|---|---|
| Version 3 (one block per job, partial sums added outside, not counted) | 2,646 | 46,517 |
| Version 4 (own FP32 adder per cell) | 11,260 | 179,962 |
| **Version 5, adder shared by 4 cells** | 5,179 average | **82,860** |
| Version 5, adder shared by 16 cells (estimate from parts) | about 3,600 | - |

Parts: cell without adder 2,900; shared adder 5,420 + 2,927 (two halves).
At the planned 32x32 engine with groups of 16, version 5 is about 1.4x the
size of version 3 while doing everything version 3 could not: whole-row
jobs, FP32 results, mixed formats, full FP4 speed.

**Still open:** clock speed is not measured yet (needs the physical flow,
W2); the 48-bit block total and the adder halves are the longest paths.

## 2026-11-22 - Tiling controller: whole matrix multiplies

**What it is.** `rtl/matmul_unit.v`: a controller plus the version 5
engine. Given matrices A (M x K) and B (K x Nc) in on-chip memory, it
splits the answer C into N x N tiles, feeds the engine one job per tile
back to back (no gaps), and writes C to memory. The memories are modelled
as simple on-chip SRAM: one read per tick, answer one tick later. The
compiler lays data out so that each read gives the engine a full set of
lanes (layout documented in the file). Sizes must be multiples of N
(software pads with zeros).

**Checks:**

| Check | Result |
|---|---|
| 10 whole multiplies: engines 4x4, 8x8, 16x16; C from 2x1 to 4x4 tiles; K from 32 to 256; INT8, FP8, FP4, FP8 x FP4, INT8 x FP4 (`make test-tile`) | every C value bit exact vs the independent reference |
| Formal proof, for every allowed configuration and for all time: jobs always have at least N beats (C1), blocks at least min(16, N) beats (C2), every job ends a block and has no gaps (C3), exactly MT x NT jobs per start (C4) | proven at 4x4, 8x8, 16x16 |
| Planted bugs (4 new: wrong scale address, wrong C address, wrong job end, skipped tiles) | 27 of 27 caught in total |

The proof found that, in principle, a start signal arriving at the wrong
moment could restart the controller in the middle of a job; the controller
now ignores a start while it is running.

**Speed.** Start to finish takes exactly (beats fed to the engine) + 2N + 4
ticks in all 10 runs: the overhead is paid once per whole multiply, not per
tile. Engine busy time: 91-99% for the runs on the 4x4 engine; it grows
towards 100% as matrices grow (64% only for a tiny 2-tile run on 16x16).

**What it does not do yet:** fetch data from HBM while computing (the data
mover, Phase 2), handle sizes that are not multiples of N in hardware, or
run several engines in parallel.

## 2026-11-22 - First physical estimate (W2): area and clock speed on real cell libraries

**Method.** `tools/w2_estimate.sh`: the design is turned into the real
logic gates of two open cell libraries with Yosys and ABC (free tools),
using fast parallel (Kogge-Stone) adders as real flows do
(`tools/w2_kogge_stone.v`), and the longest logic path between registers is
measured from the library's gate delays.
- **SKY130**: an open 130 nm manufacturing process; real chips are made in it.
- **45 nm**: the open Nangate teaching library, for a more modern reference point.
Libraries come from the open OpenROAD flow scripts; they are downloaded
to `build/pdk/` and not stored in the repository.

**What timing told us, and what changed.** The first measurement showed the
shared FP32 adder was far slower than the cells (19.6 ns on SKY130), for
three reasons: a ripple adder in synthesis, three small parts written as
long chains (leading-one search, sticky bits, lost bits), and too much
work in each adder step. Fixes, all with bit-identical results (200,000
adder cases, every engine and tiling test, every proof re-run):
1. parallel adders; leading-one found with fixed OR trees; masks for the
   sticky and lost bits;
2. the exponent maths rewritten around a single subtraction;
3. the shared adder split into a hand-off register and five one-tick steps
   (S1a, S1b, S2, S3, S4). Shared adders have many ticks between uses, so
   the extra steps cost no throughput; they add 4 ticks of delay to each
   job's results (rows now leave N+7+r ticks after the last beat) and the
   block rule becomes "at least max(min(G, N), 6) beats", re-proven
   formally and shown to be exact (one beat less breaks it).

**Longest logic path of each part (ps):**

| Part | SKY130 | 45 nm |
|---|---|---|
| Cell (multiply tick, block-total tick) | 7,491 | 1,654 |
| Adder S1a (unpack, choose window) | 6,965 | 1,661 |
| Adder S1b (line up) | 3,590 | 851 |
| Adder S2 (add / subtract) | 4,966 | 936 |
| Adder S3 (leading one, shift amount) | 7,724 | 1,587 |
| Adder S4 (round, pack) | 5,870 | 1,434 |
| *Version 3 cell, for comparison* | *11,545* | *2,175* |
| Slowest single part | 7.7 ns | 1.66 ns |
| Whole 4x4 engine, adders shared by 4, measured flat (check) | 8,306: about 120 MHz | 2,314 to 2,768 (two runs): about 360-430 MHz |
| Same engine measured module by module | - | 1,672 |

These are logic-only figures. Wires (after placement and routing) and the
registers' own timing will lower the real clock, so treat them as upper
bounds. That is the next W2 step.

**Area (um^2):**

| | SKY130 | 45 nm |
|---|---|---|
| Cell (no adder) | 14,246 | 2,879 |
| One shared adder: logic + about 630 pipeline registers | about 54,200 | about 11,200 |
| **Cell including its 1/16 share of an adder** | **about 17,600** | **about 3,580** |
| 32x32 engine (1,024 cells) | about 18 mm^2 | about 3.7 mm^2 |
| Check: whole 4x4 engine (16 cells, 4 adders), measured | 432,174 (parts estimate: 444,700, within 3%) | 93,526 (parts estimate: 90,900, within 3%) |

**What this means for the pitch.**
1. The engine works in real gates of a real process; nothing in it needs
   unusual technology.
2. At 45 nm, one 32x32 engine at about 400 MHz would give about 0.8 TFLOPS
   of FP8 (1.6 in FP4) in about 3.7 mm^2.
3. The concept chip's 256 engines would need about 940 mm^2 at 45 nm for
   the engines alone, more than the largest chip a factory can print (about
   850 mm^2), before adding memory, HBM interfaces and links. A data-centre
   chip therefore needs a modern 3-5 nm process, as every competitor uses.
   Those processes are licensed from the foundry under NDA, so the next
   numbers must come with a foundry or design-house partner (W5). The
   concept chip's assumed 1.5 GHz is not yet supported by any measurement.

Area measured on the whole engine matches the sum of the parts. Speed does
not quite: measured as one flat design, the whole engine's longest path is
longer than any single part (8.3 ns on SKY130; 2.3 to 2.8 ns at 45 nm, the
mapping tool being heuristic), while measured module by module it is
1.7 ns at 45 nm. One cause was found and fixed (the hand-off from the cells
to the shared adder now selects first and adds after); the rest could not
be pinned down with these tools. A proper timing tool after placement
(OpenROAD/OpenSTA) is needed. **Headline, stated cautiously: about 120 MHz
on SKY130 and about 400 MHz at 45 nm, logic only.**

**Not done yet:** placement and routing (OpenROAD), power, SRAM area.

**Planted bugs after the adder rewrite:** 28 of 28 caught (the full set,
re-run on the six-step adder).

## 2026-11-22 - Phase 2 begins: the tile hides main-memory waiting (goals G3, G4)

**What it is.** `rtl/tile_v1.v` (with `rtl/sram.v`): the engine and tiling
controller, plus the tile's own memory (SRAM, in two halves for A, B,
their scales and C), a data mover with one main-memory port, and a
scheduler working through a list of matrix multiplies ("commands"). While
the engine computes command k from one half, the data mover fetches
command k+1 into the other half and sends command k-1's answers back to
main memory. Main memory is modelled with a fixed delay (20 to 60 ticks per
request) and limited bandwidth (one word every 1, 2, 3 or 4 ticks).

**Checks** (`make test-tile-v1`): 6 runs of 6 commands each, engines 4x4,
8x8 and 16x16, mixed shapes and formats: every answer word in main memory
bit exact against the independent reference (6,000+ words). 3 planted
scheduler bugs (wrong half, loading too early, overwriting unsent answers)
all caught.

**Does it hide the waiting?** 4x4 engine, 6 commands of 3x3 tiles,
K = 96, FP8 x FP4, memory delay 40 ticks:

| Main-memory bandwidth | Ticks | Engine busy | Limited by |
|---|---|---|---|
| 1 word per tick | 6,078 | 85% | compute: only the first fetch and the last write-back are not hidden (ideal about 5,960) |
| 1 word per 2 ticks | 10,902 | 47% | memory |
| 1 word per 4 ticks | 18,884 | 27% | memory |

With small matrices (little reuse of each fetched number) the engine waits
for memory even at full bandwidth (39-46%), as the performance model
predicts: how much work each fetched number feeds ("arithmetic
intensity") decides which side limits.

**What this means.** The double-buffered tile works: when memory can keep
up, the engine is fed continuously, and the total time is the compute time
plus one fetch and one write-back. This is the mechanism a data-centre chip
uses to approach its peak speed (G4), and it confirms that memory
bandwidth (G3) is what limits small-batch work.

**Limits of version 1.** One command at a time on the main-memory port,
with a full memory delay at the start of each transfer; the data mover
reads one C word per 4 memory words; commands must fit in one SRAM half
(1,024 words); no reuse of A or B between commands (each command fetches
both). Next: keep weights resident across commands and stream activations,
overlap transfer start-up delays, and a small control processor (RISC-V)
to write the command list.

## 2026-11-22 - Tile version 2: weights stay in the tile

**What changed.** `rtl/tile_v2.v`: B (a model layer's weights) and its
scales live in two "weight slots" that are not swapped every command.
Each command names its slot; a command that brings new weights loads them
there, and the following commands reuse them and fetch only new
activations (A). This is how language models run: the same layer weights
serve many batches of tokens. A slot is overwritten only when every
earlier command using it has been computed.

**Checks** (`make test-tile-v2`): 9 runs (engines 4x4, 8x8, 16x16; decode-
style and mixed shapes; full and reduced memory bandwidth; slots
alternating, and all groups sharing one slot): every answer bit exact.
Planted bugs: engine reads the wrong slot, weights written into the
activation half, weights overwritten while still needed: all 3 caught.
The last one was missed at first, because tests that alternate slots
never exercise that safety rule; a test where every group uses the same
slot was added, and it is now caught (96 wrong answers).

**The gain.** 4x4 engine, 3 groups of 5 commands, each command 1 tile of
activation rows x 3 tiles of weights, K = 96, FP8 x FP4, memory delay 40:

| Main-memory bandwidth | Weights fetched every command (version 1 behaviour) | Weights kept (version 2) |
|---|---|---|
| 1 word per tick | 5,940 reads, 10,720 ticks, engine busy 40% | 2,376 reads, 5,736 ticks, **engine busy 75%** |
| 1 word per 2 ticks | 16,789 ticks, 25% | 7,567 ticks, **57%** |

Keeping the weights cuts main-memory reads by 2.5x and makes the same
work 1.9x to 2.2x faster.

**Still to improve:** each transfer still waits the full memory delay
before its first word (about 40 ticks here, paid twice per command); the
first command of each group must fetch all its weights before computing.
Next: overlap transfers, then the RISC-V control core.

**Update: overlapped transfers.** The data mover now has a request side
and an answer side: it sends one command's read requests and moves on at
once, while a small queue tells the answer side which command, half and
weight slot the arriving words belong to. So one transfer's memory delay
overlaps the next. Same 9 runs, all still bit exact; one more planted bug
(answers filed under the wrong command) added and caught (4 of 4).

| Run (4x4 unless stated) | Before | After |
|---|---|---|
| Decode, weights kept, full bandwidth | 75% busy, 5,736 ticks | 77%, 5,572 ticks |
| Decode, weights kept, half bandwidth | 57%, 7,567 ticks | 60%, 7,101 ticks |
| Mixed shapes, weights kept | 68% | 72% |
| Mixed shapes, 8x8 engine | 58% | 64% |

What still costs time: new weights can only be fetched one command
ahead (they share the scheduler's look-ahead with the activations), so
the first command of each group waits for its weights. Next step:
prefetch weights further ahead, independently of activations.

## 2026-11-22 - Tile version 3: weights fetched well ahead

**What changed.** `rtl/tile_v3.v`: a command's weights are fetched by
their own transfer, which starts as soon as the weight slot is free
(worked out from the command list: no uncomputed earlier command uses
that slot), however far ahead that is. Activations are still fetched one
command ahead. The data mover's order of choice: weights the engine is
waiting for now; the next activations; weights needed soon; results going
back; weights for later. (Main-memory layout per command: A, A scales,
then B, B scales.)

**Checks** (`make test-tile-v3`): the same 9 runs as version 2, all bit
exact. 4 planted bugs (slot refilled while in use, engine starting before
its weights arrive, weights read from the wrong place, weights marked as
arrived for the wrong command) all caught. The last one makes the tile
wait forever; the test's time limit was cut from 20 million to 500,000
ticks so that a stuck tile is reported within about two minutes.

**Engine busy, versions 2 and 3** (same work, same memory model):

| Run | v2 | v3 |
|---|---|---|
| Decode, 4x4, full bandwidth | 77% | **84%** |
| Decode, 4x4, half bandwidth | 60% | 62% |
| Mixed shapes, 4x4 | 72% | 77% |
| Mixed shapes, 8x8 | 64% | 67% |
| Decode, 16x16 | 63% | 70% |
| Decode, one shared slot | 54% | 58% |
| Mixed, one shared slot, 1/3 bandwidth | 40% | 40% |

Along the way, the first version of the choice order made the
single-slot cases slower than version 2 (35% and 53%). Putting the
weights the engine is already waiting for first fixed that.

**From version 1 to 3, the decode-style run** (4x4, 15 commands, full
bandwidth) went from 40% to 84% engine busy and from 10,720 to 5,084
ticks: 2.1x faster for the same work, with 2.5x fewer memory reads.

## 2026-11-22 - The tile gets its own control processor (RISC-V)

**What it is.** `rtl/tile_soc.v`: tile version 3 plus PicoRV32, an open
RISC-V processor (ISC licence, unmodified, `rtl/third_party/`), with
16 KB of RAM and a few control registers. Its driver program
(`fw/tile_driver.c`, built with the free clang/LLVM compiler) takes a
short description of the work - number of weight groups, batches per
group, matrix sizes and formats - and works out every command itself:
where each input sits in main memory, its size, where the answer goes,
which weight slot. It writes the commands into the tile, starts it and
waits for it to finish. The memory layout it assumes is a written
"driver contract" shared with the software that prepares main memory.

**Checks** (`make test-soc`): 6 runs (engines 4x4, 8x8, 16x16; FP8 x FP4,
FP8 x FP8, INT8 x INT8, FP4 x FP4, INT8 x FP4; weights reloaded every
command; all groups sharing one slot). In every run the commands the
program wrote are identical to the test generator's, and every answer is
bit exact. 2 planted bugs in the control registers (command words joined
in the wrong order; status bits swapped so the program stops early) both
caught.

**Cost of the driver.** The first version packed each command one bit at
a time and spent 87,000 ticks preparing 15 commands (the tile's work took
5,084). Packing whole fields at once cut that to about 1,200 ticks (80
per command); the whole run now takes 6,277 ticks.

**Size.** PicoRV32 at 45 nm: about 26,400 um^2 (7 engine cells' worth,
under 1% of a 32x32 engine), longest logic path 1.8 ns, similar to the
engine's. A control core per tile is affordable.

**Next:** start the tile while the driver is still writing commands (hide
the setup time), the vector unit, and the first step of the software stack
(W3): turning a PyTorch layer into these commands automatically.

## 2026-11-23 - Software stack, first step (W3): PyTorch layers compiled onto the tile

**What it is.** `tools/imbewu_compile.py`: a first compiler and runtime.
`imbewu_linear(layer, x, a_fmt, w_fmt)` takes a PyTorch linear layer and a
batch of inputs and: rounds both to MX formats; pads the sizes (tokens and
outputs to multiples of N, inputs to multiples of 32); cuts the layer into
tile commands that fit the SRAM halves, fetching each group of weights
once and reusing it for every batch of tokens; lays out main memory
(layout v3); runs the simulated tile (tile_v3, version 5 engine); and
returns a PyTorch tensor.

**Checks.** `make test-compile`: 6 random layers with awkward sizes
(padding of tokens, outputs and inputs; 1, 4 and 16 commands; INT8, FP8,
FP4 and mixed formats): all bit exact against the independent reference.

**A real model layer.** Qwen2.5-0.5B, layer 0, `mlp.gate_proj` (first 128
of its 4,864 outputs), 32 tokens of real WikiText-2 text, K = 896, on the
16x16 engine: 16 commands (8 weight groups x 2 token batches).

| Activations x weights | Bit exact vs reference | Error vs PyTorch FP32 | Tile |
|---|---|---|---|
| FP8 x FP4 | yes | 12.3% | 25,053 ticks, engine fed 57% |
| FP8 x FP8 | yes | 5.1% | 25,053 ticks, engine fed 57% |

(Errors differ from the earlier single-slice check, 3.9% and 14.2%,
because these are different tokens and output channels.)

**What this run revealed (stated honestly).** Both runs read exactly the
same amount from main memory (22,176 words). In a mixed FP8 x FP4 job the
hardware takes one FP4 number per 8-bit lane, so FP4 weights are stored
and moved at the same size as FP8. The memory saving that makes FP4
weights worthwhile for decode (the performance model's "501 -> 889 tokens
per second") is therefore **not yet realised by the hardware**. It needs
two FP4 weights per lane in mixed jobs, with the activation side feeding
two elements per beat. Recorded as decision D-020.

Engine use is 57% here because each weight group serves only 2 batches of
tokens, so most of the time goes on fetching weights (memory bound, as
expected for decode-like work).

## 2026-11-23 - FP4 weights packed two per lane (D-020): the memory saving is now real

**What changed.** In a mixed job (exactly one side FP4), that side is
stored two FP4 numbers per byte in memory. The tiling controller reads
each such word once and uses it on two beats in a row; a one-bit tag
travelling with the data tells each cell which half to use. The engine
still does one multiply per cell per tick, but the FP4 side's memory
traffic is halved. Files: `rtl/mx_mul.v` (half select), `rtl/pe_v5.v`,
`rtl/systolic_v5.v` (the tag), `rtl/matmul_unit.v` (packed addressing),
`rtl/tile_v3.v` (command bit 18), `tools/imbewu_compile.py` (packing).

**Checks.** Multiplier on every possible input, now including the half
select: 2,088,968 cases, 0 errors. Compiler tests (8 layers, including
FP4 activations packed and an unpacked comparison): all bit exact. Every
earlier engine, tiling, tile and RISC-V test and the formal proofs re-run:
all pass. 2 new planted bugs (halves swapped; packed words not reused)
caught, after making the compiler report undefined answers as failures
rather than crash.

**The real Qwen layer again** (FP8 activations x FP4 weights, 16x16 engine):

| | One FP4 per byte | Two per byte (D-020) |
|---|---|---|
| Main-memory reads | 22,176 words | **11,200 words** |
| Commands | 16 | 8 (more weights fit per SRAM half) |
| Time | 25,053 ticks | **16,726 ticks (1.5x faster)** |
| Engine busy | 57% | **85%** |
| Answers | bit exact, 12.3% from FP32 | bit exact, identical |

So FP4 weights now deliver what the performance model assumed: half the
weight traffic for the same arithmetic.

## 2026-11-23 - Vector unit, version 1: softmax, RMSNorm and SiLU (goal G4)

**What it is.** The parts of a transformer that are not matrix multiplies:
softmax (attention), RMSNorm (between layers) and SiLU (the activation).
- `rtl/fp32_ops.v`: IEEE 754 FP32 add and multiply, built on the already
  verified "exact sum, rounded once" adder, so rounding is the proven one.
- `rtl/vu_v1.v`: L FP32 lanes (one per engine column), 8 vector
  registers, 15 one-tick instructions: load/store, add, subtract,
  multiply, max, min, lane sum and lane max (fixed pairwise order), FP32
  constants, floor, 2^n, and first guesses for 1/x and 1/sqrt(x).
- `tools/vu_asm.py`: assembler, an exact emulator of every instruction,
  and the programs. exp(x) = 2^(whole part) x (7-term series for
  2^fraction); 1/x and 1/sqrt(x) = first guess + 3 Newton steps.

**Checks.**
- FP32 add and multiply vs NumPy (IEEE 754): 100,000 cases aimed at
  ties, cancellation, subnormals, overflow, signed zeros and infinities:
  0 errors (`make test-fp32ops`, 50,000 cases).
- Programs on the hardware (`make test-vu`): softmax, RMSNorm and SiLU at
  4, 8 and 16 lanes, 4 random rows each: **hardware = emulator bit for
  bit in all 9**; worst error against PyTorch (float64): softmax 9.4e-7,
  RMSNorm 1.8e-7, SiLU 5.3e-7, i.e. at the limit of FP32 itself.
- 4 planted bugs (floor of negatives, 2^n off by two, MAX returning the
  smaller number, lane sum missing half the lanes): all caught.

**Speed (ticks for one row).** 16 lanes x 2 vectors (a row of 32
numbers): softmax 96, RMSNorm 45, SiLU 101. Each vector of SiLU costs
about 50 instructions (the exp series and the Newton steps), so on long
rows the vector unit, not the engine, could become the bottleneck for
SiLU and softmax. Planned improvements: a native exp2 and reciprocal
step, and several instructions per tick.

**Not done yet:** connecting it to the tile (reading the engine's result
rows directly), and its size (measurement running).

## 2026-11-23 - A whole language model on Imbewu's arithmetic

**What was done.** Gate-level simulation is far too slow for a whole
model, so `tools/imbewu_numerics.py` does the chip's exact arithmetic with
PyTorch: MX rounding, exact sums inside each block of 32 and one FP32
rounding per block for every matrix multiply; and the vector unit's own
instruction sequences for softmax, RMSNorm and SiLU. Its self-check ties it
to the bit-exact references: 60 of 60 vector rows identical to the vector
unit's emulator (which the hardware matches bit for bit), and 0 of 192
matrix results different from exact single rounding.

Qwen2.5-0.5B then ran end to end on this arithmetic: every linear layer,
both attention products, softmax, every RMSNorm, SiLU and the output layer.
Perplexity on WikiText-2 (8 windows of 512 tokens, 4,088 tokens scored;
lower is better):

| Configuration | Perplexity | Change vs FP32 |
|---|---|---|
| FP32 (reference) | 18.01 | - |
| Imbewu, FP8 x FP8, everything on chip arithmetic | 20.38 | +13.1% |
| Imbewu, FP8 activations x FP4 weights, everything | 26.29 | +46.0% |

**Where the loss comes from** (FP8 weights; one part changed at a time):

| What is on chip arithmetic | Perplexity | Change |
|---|---|---|
| Linear layers, softmax, RMSNorm, SiLU (attention products and output layer in FP32) | 18.73 | +4.0% |
| ... + output layer in FP8 | 19.00 | +5.5% |
| ... + attention, probabilities x V in FP8 (Q x K^T in FP32) | 19.14 | +6.2% |
| ... + attention, Q x K^T in FP8 (probabilities x V in FP32) | 20.27 | +12.6% |
| Everything (both attention products in FP8) | 20.38 | +13.1% |
| Everything, attention products in MX INT8 instead | 20.20 | +12.1% |
| **Everything, Q x K^T in BF16 (approximate model), rest FP8** | **19.17** | **+6.4%** |

So: (1) the vector unit's softmax, RMSNorm and SiLU cost nothing
measurable (the +4.0% row matches the earlier linear-layers-only accuracy
check); (2) almost all the extra loss is **Q x K^T** (the step that scores
how much each word attends to each other word) in 8-bit MX blocks; INT8
does not help, so it is the shared block scale, not the 8-bit format: a few
very large channels in Q and K (a known effect of the rotary position code)
set the scale and smaller ones are rounded away; (3) computing Q x K^T in
BF16 recovers almost all of it (+6.4% vs +6.2% for full FP32).

With FP4 weights and Q x K^T in BF16: 24.08 (+33.7%, down from +46.0%).
The rest of that loss is FP4 weights on a small model, as the earlier
accuracy check found; larger models lose much less.

**Decision D-021:** add a BF16 mode to the engine for Q x K^T. (The BF16
row above uses a software approximation: BF16 inputs, FP32 sums; the
engine's exact BF16 arithmetic is still to be designed.)

**Limits.** One model (0.5B), 4,088 tokens (the FP32 reference was computed
once and reused); the matrix model rounds via float64, which can in rare
cases round twice (0 of 192 cases in the check).

**Update: which format for attention scores?** Cheaper options than BF16
were tried for Q x K^T (FP8 weights, everything else as above):

| Q x K^T format | Perplexity | Change |
|---|---|---|
| MX FP8, blocks of 32 | 20.38 | +13.1% |
| MX FP8, blocks of 8 | 20.64 | +14.6% |
| MX INT8, blocks of 32 | 20.20 | +12.1% |
| MX INT8, blocks of 8 | 19.82 | +10.1% |
| BF16 (approximate model) | 19.17 | +6.4% |
| **MX INT16 (16-bit whole numbers, blocks of 32)** | **19.14** | **+6.25%** |
| FP32 | 19.14 | +6.2% |

Smaller blocks do not fix it, so the cause is not mainly one large value
setting its block's scale; the scores need more precision in every number
than 8 bits give. **MXINT16 matches FP32** and keeps the engine's way of
working: one shared power-of-two scale per block of 32 and exact whole-
number sums inside the block. BF16, where every number has its own
exponent, would need much wider exact adders. Decision D-021 is updated
accordingly.

**Update: attention scores without new hardware.** Which side of
Q x K^T needs the precision? Q in 16 bits x K in 8 bits: +12.3% (no help);
Q in 8 bits x K in 16 bits: **+6.28%** (as good as 16 bits on both sides).
So only K needs more than 8 bits, and the compiler can give it that on
today's engine: each block of K, in 14-bit MX whole numbers (MXINT14), is
split into a high and a low MXINT8 block (split at 2^7, the low block's
scale 2^7 smaller), and Q's block is repeated for both. The engine's exact
block sums then give Q x K^T with 14-bit K, at half speed for this one step.

- Exactness (`split16()` in `tools/imbewu_numerics.py`): high + low equal
  the MXINT14 values exactly in 50 of 50 trials; final FP32 results equal a
  direct MXINT8 x MXINT14 product in 9,899 of 9,900 cases (the other one
  differs because two FP32 roundings per block replace one).
- 16- and 15-bit splits were tried first and are **not** exact: an MXINT8
  block cannot hold -128 next to odd numbers without losing a bit, so each
  part must stay within 7 bits plus sign. 14 bits is the most that splits
  exactly (still 6 bits more than BF16's precision).

| Q x K^T done as | FP8 weights | FP4 weights |
|---|---|---|
| MX FP8 (8-bit) | +13.1% | +46.0% |
| BF16 (approximate model) | +6.4% | +33.7% |
| MXINT16 (would need new hardware) | +6.25% | - |
| **K split into two INT8 blocks (today's engine)** | **+6.54%** | **+32.8%** |

**Cost: half speed for Q x K^T only.** From the performance model's model
shapes: Q x K^T is 0.2-1% of the multiplies at 512 tokens of context,
2-8% at 4k, 12-29% at 32k. At half speed that adds about 0-1%, 2-8% and
12-29% to the total time respectively, against 1.4-1.9x at 32k for the
quarter-speed MXINT16 design. Dedicated 16-bit hardware stays an option if
very long contexts become the main use.

**Update: the K split runs on the simulated tile.** The compiler now has
`imbewu_attention_scores(q, k)` (in `tools/imbewu_compile.py`), which turns
the split into one ordinary tile job. Checks: a random test with one large
channel (`make test-compile`) and real Q and K captured inside Qwen2.5-0.5B's
attention (`tools/real_scores_on_tile.py`; 32 tokens, head 0, layers 0 and
12, 16x16 engine): bit exact against the compiler's reference and against
the fast numerics model in every case.

What matters to the model is the attention weights after softmax, not the
raw scores. Total change in the weights per token, against FP32 (0 = none,
2 = completely different):

| Layer | Plain INT8 scores | Plain FP8 scores | K split (14-bit K) |
|---|---|---|---|
| 0 | 0.751 | 0.358 | **0.146** |
| 12 | 0.022 | 0.121 | **0.021** |

(The plain relative error of the score matrix can mislead here: in layer 0
it is 2.0% for FP8 and 2.4% for the split, yet the split moves the weights
less than half as much. It weighs big scores most, while softmax depends on
the differences between scores.)

## 2026-11-24 - Phase 3 begins: several tiles sharing one main memory (goals G2, G3)

**What was built.** `rtl/cluster.v` holds T tiles (tile version 3, each
with its own engine, SRAM and weight slots) and a **memory arbiter**: main
memory accepts up to B requests per tick (B "channels"); every tick the
arbiter lets up to B of the tiles that are asking go ahead, taking turns
(round robin, so no tile can be starved), labels each request with the
tile's number, and the answers come back to the tile that asked.

**Test.** One model layer, FP8 x FP8: 8 tokens x 32 output channels,
K = 256, on 4x4 engines. The 8 groups of output channels are shared out
among the tiles (group g to tile g mod T); each tile fetches its weights
once and reuses them for both batches of tokens. Main memory answers after
40 ticks. Every answer word is checked bit for bit against the independent
reference, and the test also checks every engine was fed exactly the
right number of beats (`tests/run_cluster_tests.sh`, `make test-cluster`).

| Tiles | Memory channels | Ticks for the layer | Speed-up | Engines busy |
|---|---|---|---|---|
| 1 | 1 | 7,214 | 1.0x | 56% |
| 2 | 1 | 7,093 | 1.02x | 28% |
| 4 | 1 | 7,009 | 1.03x | 14% |
| 2 | 2 | 3,862 | 1.87x | 53% |
| 4 | 4 | 2,186 | 3.30x | 46% |

All answers bit exact in all five runs.

**What it shows.**
1. **More tiles do nothing if memory can't feed them.** With one shared
   channel, four tiles are 3% faster than one: the layer is limited by
   memory, so extra engines just wait. This is the G2/G3 link in one table:
   chip-to-chip and tile-to-tile scaling only pays if memory bandwidth grows
   with it.
2. **With bandwidth to match, scaling is close to linear**: 1.87x on two
   tiles, 3.3x on four. The gap from 4x is the start and end of the layer
   (filling and draining the pipelines) and that this layer is small.
3. **Activations are read many times.** Every run reads 6,336 words from
   memory, of which 4,224 are the tokens (activations), fetched once per
   group of output channels. When several tiles work on the same tokens at
   the same time, one read could feed them all (a **broadcast**). For four
   tiles that would cut this layer's memory reads by about half (6,336 to
   about 3,170) and so speed up the memory-limited case by about 2x.

**Planted bugs.** The arbiter was deliberately broken in two ways (answer
sent to the wrong tile; one more grant per tick than memory has channels):
see the result below.

**Limits.** Memory here is an ideal delay with B independent channels; a
real HBM model (banks, refresh, row hits and misses) comes later in
Phase 3. Tiles do not yet talk to each other directly (no on-chip network),
and tiles are given their work by the test, not by a scheduler.
