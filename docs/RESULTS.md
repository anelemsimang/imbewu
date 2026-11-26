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
sent to the wrong tile; one more grant per tick than memory has channels).
Both were caught (`tests/run_cluster_mutants.sh`): in each case a tile
waits for an answer that never arrives, and the test reports the cluster
stuck.

**Limits.** Memory here is an ideal delay with B independent channels; a
real HBM model (banks, refresh, row hits and misses) comes later in
Phase 3. Tiles do not yet talk to each other directly (no on-chip network),
and tiles are given their work by the test, not by a scheduler.

## 2026-11-24 - Broadcast: one memory read feeds every tile that needs it (goals G2, G3, G5)

**The problem.** In the multi-tile run above, every tile fetched its own
copy of the same tokens (activations): two thirds of all memory reads were
duplicates.

**What was built.**
- Main memory now holds **one copy** of each batch of tokens. Each command
  says where its weights are (new 18-bit field `w_at`; zero keeps the old
  layout, so all earlier tests are unchanged and still pass).
- The cluster keeps a short **list of reads in flight** (the same idea as
  the "miss registers" of a processor cache). When a tile asks for an
  address that is already being read (in the same tick, or up to 8 reads
  earlier, as long as the answer has not yet arrived), it **joins** that
  read instead of using a memory channel; when the answer arrives it goes
  to every tile on the read. A tile may only join a read issued after the
  ones it is already waiting on, so its answers still arrive in order.
- First version merged only same-tick requests. That worked for 4 tiles
  but not for 2: the two tiles settled one word apart (one asking for word
  i while the other asked for word i-1) and never matched. Joining reads in
  flight fixed it.

**Results** (same layer as above; every answer bit exact):

| Tiles | Channels | Ticks, no broadcast | Ticks, broadcast | Speed-up | Memory reads |
|---|---|---|---|---|---|
| 2 | 1 | 7,093 | 4,997 | 1.42x | 6,336 to 4,224 |
| 4 | 1 | 7,009 | 3,853 | 1.82x | 6,336 to 3,168 |
| 2 | 2 | 3,862 | 3,862 | 1.0x | 6,336 to 4,224 |
| 4 | 4 | 2,186 | 2,186 | 1.0x | 6,336 to 3,168 |

**What it shows.**
1. When memory is the limit (one channel), broadcast makes the layer
   **1.4x faster on 2 tiles and 1.8x on 4**, close to the "about 2x"
   estimated beforehand. The tokens are now read exactly once; what is left
   is the weights (2,112 reads, each needed by one tile only) and the
   answers.
2. When memory is not the limit (a channel per tile), the time does not
   change, but memory traffic still halves. Moving data to and from HBM
   costs far more energy than computing on it, so this is a performance
   per watt gain (G5) even where it is not a speed gain.
3. Put differently: 4 tiles with broadcast on **one** channel (3,853
   ticks) do as well as 2 tiles with **two** channels and no broadcast
   (3,862). Broadcast buys the effect of extra memory bandwidth, which is
   the most expensive part of an accelerator.

**Cost.** The list holds 256 reads (enough for 40 ticks of memory delay on
4 channels), each with its address, a time stamp and one bit per tile; a
new request is compared against the last 8 addresses. Small next to a
tile's SRAM; a size estimate comes with the next physical estimate.

**Planted bugs, and a gap they found.** Five bugs were planted in the
arbiter and broadcast (answers to the wrong tile; one grant too many per
tick; joining a read older than one the tile is already waiting on;
joining a read whose answer is arriving that very tick; comparing
addresses without their lowest bit). The layer test caught only the first
two: tiles read their tokens in a tidy sequence that never sets up the
other cases. So the arbiter was split into its own module (`mem_share`)
and given a **stress test** (`tests/tb_mem_share.v`): random requesters
reading from a small shared set of addresses and from a moving window
(like tiles a few words apart), with writes mixed in, on 2 to 8
requesters, 1 to 8 channels and memory delays of 1 to 40 ticks; every
answer is checked for the right requester, order and data. The real
design passes all 48 runs (up to 29% of reads shared); **all five planted
bugs are caught** (`make mutants-cluster`).

Also found and fixed: the planted-bug script from the first multi-tile
run passed its file paths wrongly, so it never tested anything; the
results reported then came from a separate, correct run.

**Limits.** Memory answers in the order asked (a real HBM controller
reorders; it would then also put answers back in order). The design
assumes no tile reads an address another tile writes during the same
layer, which holds because inputs and outputs are kept apart.

## 2026-11-24 - Vector unit into the tile, step 1: FP32 back into MX blocks

**Why.** The vector unit works in FP32 (softmax, RMSNorm, SiLU). The next
matrix multiply needs its inputs as MX blocks: 8-bit (or 4-bit) numbers
sharing one power-of-two scale per block of 32. So results must be rounded
back into blocks, in hardware, exactly as the compiler and the numerics
model do it (otherwise the whole-model accuracy results would not hold).

**What was built.** `rtl/mx_quant.v` takes N FP32 numbers per tick. For
each block of 32 it finds the largest, sets the block scale from it, and
rounds every number into INT8, FP8 or FP4 (nearest value, ties to even,
capped at the format's largest value). It collects the next block while
sending out the current one, so it keeps up with one word per tick.

**Test.** Compared code for code against the compiler's own rounding
(which uses the independent ml_dtypes library): random numbers at every
scale, exact ties, values at and just past each format's largest value,
tiny (subnormal) inputs, zeros and minus zeros, blocks mixing huge and
tiny numbers, and a different format on every block; 4, 8 and 16 lanes;
blocks back to back and with random gaps. **108,000 blocks, all
identical** (`make test-mxq`). Six planted bugs (ties rounded up, FP8 scale
one step off, FP8 capped at 480 instead of 448, block scale not kept above
-127, tiny inputs' exponent off by one, INT8 not reaching -128): **all
caught** (`make mutants-mxq`).

One bug found on the way: for numbers so small they round to zero, the
rounding read a bit beyond the end of the number (unknown value in
simulation). Fixed.

**Size.** For 4 lanes: about 9,600 logic cells plus two 1,024-bit block
buffers (Yosys, generic cells). For a 16x16 engine (16 lanes) that would be
roughly 5% of the engine; worth trimming later (the general-purpose
shifters can be made narrower).

**Next.** Step 2: the transpose (the engine writes one token per word, but
reads its next input as one position of K per word, across tokens) and
the tile's path engine -> vector unit -> converter -> next command.

## 2026-11-24 - Vector unit into the tile, step 2: layers chained on one tile (tile version 4)

**What was built.** `rtl/tile_v4.v` = tile version 3 plus a
post-processing stage between the engine and main memory. Each command
chooses what happens to its answers:
- **store FP32** (as before);
- **round into MX blocks** (INT8, FP8 or FP4) and store them in the exact
  layout the engine reads as input;
- **run a vector-unit program first** (SiLU, softmax, RMSNorm), then round
  and store.

For each token row the stage copies the row into the vector unit, runs
the program, sends the results through the converter from step 1, and a
transpose buffer gathers N tokens and writes them out "one column per
word", which is what the next layer's engine expects. A command can be
marked "wait" (dep), so it fetches its inputs only after the previous
command's results are stored. One tile can therefore run a chain of layers
with no software in between.

**Test.** Three layers chained on one tile: (1) 8 tokens x 64 inputs ->
32 outputs, vector-unit program, rounded to FP8; (2) reads that, -> 64
outputs, rounded to INT8, FP8 or FP4; (3) reads that, -> 8 outputs in
FP32. Every word is checked: both intermediate results in main memory and
the final answers. Expected values come only from independent references
(exact block sums, the vector unit's bit-exact emulator, the compiler's MX
rounding). All three programs x all three middle formats, on 4x4 and 8x8
engines, some with slow memory (one request per 3 ticks): **18 runs, all
bit exact** (`make test-tile-v4`).

**A mistake found on the way, in the test, not the chip.** The first run
had only the final layer wrong, by exactly 64x. The engine treats an INT8
element as code / 64 (as the MX standard says); the compiler's reference
already allowed for that, but the new test generator did not. Fixed in
the generator; the hardware was right.

**Time (4x4, SiLU chain).** 7,819 ticks: the engine was fed on 2,304, and
post-processing took 4,258. The vector unit does one instruction per tick
and SiLU needs about 50 instructions per word of N numbers, so here the
**vector unit, not memory, is now the slow part.** In this test every
layer waits for the one before, so nothing overlaps; in a real model many
batches of tokens are in flight, and the next command's matrix multiply
already runs while this one is post-processed. Still, making the vector
unit faster (more lanes, or doing exp and 1/x in one step) is now on the
list (W4 performance model to size it).

**Planted bugs.** Six bugs planted in the new stage (tokens put in the
wrong lanes by the transpose; the "wait" flag ignored, so a layer reads
before its input is written; the converter fed the input row instead of
the program's results; block scales written for the wrong group of
tokens; the transpose written out before the converter finished; the
converter fed before the vector unit finished): **all six caught**, in
both test chains (`make mutants-tile-v4`).

**Limits.** One vector-unit program per run (all post-processed commands
use it); rows up to 64 words; results go through main memory to the next
layer (keeping them in the tile's own memory is a later saving). Rows of
softmax and RMSNorm must fit in one command (the full width of the layer).

## 2026-11-24 - Vector unit version 2: one-instruction 2^x and 1/x (D-024)

**Why.** Tile version 4 showed the vector unit had become the slowest step
(SiLU post-processing 4,258 ticks against 2,304 for the engine). A new
tool, `tools/vu_budget.py`, compares the vector unit's ticks with the
engine's for real model shapes: with version 1, for Qwen2.5-0.5B at 4k
tokens of context it would need 1.9x the engine's time (16x16 engine), and
for Llama-3-70B at 32k about the same as the engine.

**What was built.** `rtl/vu_v2.v`: version 1 plus, in every lane,
- **EX2** (2^x) and **RCP** (1/x) in one instruction each (a "special
  function unit", as GPUs have). Each is defined exactly as a few integer
  steps with a small table (64 entries for 2^x, 128 for 1/x) in
  `tools/vu_asm.py`; the hardware's tables are generated from that
  definition, so the two cannot drift apart;
- instructions that take a constant directly (ADDC, SUBC, MULC, MAXC,
  MINC), so programs stop spending a tick loading each constant.

| Instructions per vector of N numbers | v1 | v2 |
|---|---|---|
| SiLU | 50 | 7 |
| softmax | 41 | 11 |
| RMSNorm (per vector) | 8 | 8 |

Vector-unit time as a share of engine time (16x16 engine, per token per
layer; 100% = as long as the engine):

| Model, context | v1 | v2 |
|---|---|---|
| Qwen2.5-0.5B, 4k | 190% | 51% |
| Qwen2.5-0.5B, 32k | 415% | 111% |
| Llama-3-8B, 32k | 144% | 39% |
| Llama-3-70B, 32k | 101% | 27% |

So for the larger models the vector unit is now comfortably faster than
the engine; for a small model at very long context it still is not.

**Exactness and accuracy.**
- Hardware = definition bit for bit on 12,288 inputs: every exponent,
  zeros, infinities, tiny numbers, the clamp limits, random bit patterns.
- Programs on the hardware = emulator bit for bit; version 1 programs
  still give identical results on the version 2 hardware.
- Largest relative error: 2^x below 2^-21, 1/x below 2^-22 (FP32 itself
  is 2^-24). On test rows, SiLU and softmax come out slightly *more*
  accurate than version 1's software sequences.
- Tile version 4 now uses version 2: all 15 chained runs bit exact; the
  SiLU chain's post-processing fell from 4,258 to 1,506 ticks, the whole
  chain from 7,819 to 5,067.
- Whole model (Qwen2.5-0.5B, Q x K^T with the 14-bit K split): FP8
  weights **+6.88%** perplexity (version 1: +6.54%); FP4 weights +33.6%
  (version 1: +32.8%). A small difference; the new functions are not less
  accurate on their own, so this is most likely how rounding differences
  add up in this model, but it was not investigated further.

**Planted bugs.** Six bugs in the new hardware (2^x reading the wrong
table entry, rounding negative inputs the wrong way, dropping its
correction term; 1/x exponent off by one, correction with the wrong sign;
constant-operand instructions using a register instead): **all six
caught**: the first five by the 2^x / 1/x test, the sixth by the program
tests (`tests/run_vu2_mutants.sh`).

**Limits.** Each new instruction is still one long tick; a real chip
would spread 2^x and 1/x over a few ticks (pipelining). Size not yet
estimated (each lane gains two small tables and a few multipliers).

## 2026-11-24 - Performance model now counts the vector unit (W4)

`tools/perf_model.py` now includes the vector unit's time (one per engine,
N lanes, instruction counts measured from the real programs), next to
compute, memory and links; prefill at 32k tokens was added. Same assumed
concept chip as before (256 engines of 32x32, 1.5 GHz, 4 TB/s HBM). FP8
weights and activations, tokens per second for the whole system:

| Model | Chips | Step | Vector unit v1 | Vector unit v2 |
|---|---|---|---|---|
| 8B-class | 1 | prefill 4k | 48,821 (compute) | 48,821 (compute) |
| 8B-class | 1 | prefill 32k | **8,750 (vector unit)** | **25,256 (compute)** |
| 8B-class | 1 | decode, batch 64 | 10,280 (memory) | 10,280 (memory) |
| 70B-class | 1 | prefill 32k | **1,750 (vector unit)** | **3,530 (compute)** |
| 70B-class | 4 | prefill 32k | **7,000 (vector unit)** | **14,119 (compute)** |
| 70B-class | 4 | decode, batch 64 | 8,936 (memory) | 8,936 (memory) |

(In brackets: what limits the step.)

**What it shows.**
1. With version 1, reading long prompts would have been limited by the
   vector unit (softmax over 32k scores per token), at a third (8B) to
   half (70B) of the engine's speed. With version 2 the engine sets the
   pace again; the vector unit needs 54-78% of the engine's time there.
2. Generating text (decode) is limited by memory in every case, as the
   community reading predicted; the vector unit does not matter there.
   So the next performance gains for decode come from memory (bandwidth,
   broadcast across tiles, more queries per weight read), not compute.
3. At 32k context the vector unit is again within a factor of 2 of the
   engine; for 128k-token contexts it would be the limit again. Recorded as
   a known limit; softmax's share grows with context length.

Generated tables: `results/perf_model.md`. Roofline model: optimistic.

## 2026-11-24 - Spare tiles: a chip with a faulty tile still works (yield; W6)

**Why.** Chips come out of the factory with occasional defects. Large chips
survive this by switching off the faulty units and selling the rest (e.g.
Nvidia's H100 sells with 132 of its 144 compute units on). Imbewu is built
from identical tiles, so it can do the same.

**What was built.** The cluster has a `tile_off` input (on a real chip, set
from the factory test, e.g. by fuses). A switched-off tile is held in
reset: it never asks for memory, and the cluster does not wait for it. The
test-data generator (standing in for the compiler) shares the work among
the working tiles only.

**Test.** 4 tiles with tile 2 off, and with tiles 0 and 3 off; one memory
channel and four. Every answer bit exact. The test also hands each
switched-off tile a real command list as bait and fails if it ever
touches memory.

**A bug found by measuring, not by the answer check.** With one tile off,
all answers were right, but broadcast stopped sharing reads entirely
(6,336 reads, the no-sharing figure). Cause: the turn-taking still gave
the dead tile a turn, which passed to the next tile, so that tile got
twice the share of memory, raced ahead, and the tiles drifted too far
apart to share. Fixed: turns skip switched-off tiles. Now 4 tiles with one
off behave exactly like a 3-tile cluster (5,013 ticks, 4,231 reads, same
numbers). Lesson: broadcast depends on the tiles getting equal turns.

**Planted bugs.** Added: the cluster waiting for switched-off tiles (never
finishes), and a switched-off tile not held in reset (caught by the bait
check: it tried to use memory 4,990 times). Not covered by a pass/fail
check: unequal turn-taking (answers stay right, only speed suffers).
Full run of the cluster's planted bugs: **7 of 7 caught**
(`make mutants-cluster`).

**Not yet done.** The real compiler (`tools/imbewu_compile.py`) does not
yet read the tile-off list; a yield and cost-per-good-chip estimate (W6)
is next.

## 2026-11-24 - Cost per working chip, with spare tiles (W6, goal G5)

`tools/yield_model.py`: random (Poisson) defects; the shared part of the
chip (memory interfaces, links, control) must be defect free; the tile
part works if at most S of its tiles are faulty (S spares). ASSUMPTIONS:
0.001 defects per mm^2 (reported for TSMC 5 nm, Cerebras article) and
twice that; wafer USD 17,000 (public estimate); R18 per USD; 60% of the
chip in 256 tiles. Silicon only (no packaging, HBM or test).

600 mm^2 chip, 0.001 defects per mm^2:

| Spare tiles | Chip area | Working chips | Silicon cost per working chip |
|---|---|---|---|
| 0 | 600 mm^2 | 55% | USD 344 (R6,195) |
| 2 | 603 mm^2 | 78% | USD 242 (R4,348), -30% |
| 8 | 611 mm^2 | 79% | USD 246, -29% |

With twice the defects: 30% -> 60% working, cost per working chip halves
(USD 627 -> 317). For a 300 mm^2 chip: -16% (or -29% with twice the
defects).

**What it shows.**
1. Two spare tiles (0.5% more area) give almost all the benefit; more
   spares cost area and gain nothing.
2. What then decides the yield is the shared 40% of the chip, which has no
   spare: 79% at most here. So the next yield step is to protect that part
   (e.g. a spare memory channel or link, as large chips do), and to keep it
   small.
3. The bigger and the more defect-prone the chip, the more this matters:
   it is worth the most for a large first chip on a new process.

**Limits.** Real defects cluster and some faults are not "a tile works or
not" (timing, leakage); both lower yield further. The numbers are for
choosing a design, not for pricing.

## 2026-11-24 - Lint check of every current design (W1)

**What was done.** Verilator (free, version 5.020) reads the hardware code
looking for mistakes simulation can miss. All current designs: the engine,
the tile (version 4, with the vector unit and converter), the cluster with
its arbiter, both vector units and the converter. `make lint` (in
`tests/run_lint.sh`) fails on serious findings: latches built by accident,
signals driven from two places, missing or misconnected parts, errors.

**Found and fixed.**
1. **An accidental latch in the arbiter** (`rtl/cluster.v`): two temporary
   values in the read-joining logic were not set on every path, so a
   synthesis tool would build small memories (latches) for them. Harmless
   in simulation, but real hardware it was never meant to have. Fixed by
   setting them first; the lint check flags both latches if the fix is
   removed.
2. **A silent-overflow risk in tile version 4**: the post-processing
   output buffer holds 2,112 words, and nothing checked that a command's
   output fits, or that it keeps the stated limits (rows up to 64 words,
   whole blocks of 32). Such a command would have lost data silently. Now
   simulation stops with an error naming the command; checked with a
   deliberately oversized command. (On a real chip the compiler must keep
   to these limits; recorded for the compiler.)

**Reviewed and kept.** About 230 warnings in total across the four runs, mostly width changes:
narrower numbers widened on purpose, and 44 places where a value is cut to
a narrower width. Each cut in the current designs was checked by hand
against the range of values it can hold (for example the converter's
exponent field, the 1/x correction, the arbiter's tile numbers); none can
lose bits within the design's stated limits. Also "circular logic" notes
on the vector unit's lane-sum tree, which are a known Verilator false
alarm for a tree stored as one array.

After the fixes: all cluster and tile version 4 tests pass again (below).

## 2026-11-24 - Gate-level simulation: the tests rerun on the built gates (W1)

**What was done.** Yosys turned two designs into logic gates, as a chip
flow does, and the same tests were run on those gates (using Yosys's gate
models) instead of on the code we wrote. This catches differences between
what we meant and what the tools built (code that simulates one way and
synthesises another). `make gate` (`tests/run_gate_tests.sh`).

| Design (as gates) | Size | Test on the gates | Result |
|---|---|---|---|
| FP32 -> MX converter, 4 lanes | about 9,600 logic cells + buffers | 36,000 blocks, every format, back to back and with gaps | bit exact |
| Engine (4x4) + tiling controller | 89,325 cells | 5 whole matrix multiplies, all format pairs (FP8, INT8, FP4, mixed) | bit exact, and tick for tick the same timing as the written design |

**What it shows.** No difference between the written design and the gates
the tools built, for the engine and the converter. The test benches can
now run on gates with one switch (`-DGATE`), so the same check can be
repeated on the netlist a full layout flow produces later.

**Limits.** Gates without wire delays (logic only): a timing-accurate run
needs the delays from layout (W2). Only the 4x4 engine (larger sizes take
long to simulate as gates); the tile, cluster and vector unit not yet (the
tile is mostly memory, which a real chip builds from the foundry's memory
blocks).

## 2026-11-24 - Gate level, step 2: the arbiter, the vector unit and the whole tile

**What was done.** The remaining current designs were turned into gates
by Yosys and their own tests run on the gates (`FULL=1 make gate`):

| Design (as gates) | Size (generic gates) | Test on the gates | Result |
|---|---|---|---|
| Memory arbiter + broadcast (4 requesters, 2 channels, 16-entry list of reads in flight) | 23,458 | random stress test, memory delays 1, 6, 40, two seeds | bit exact; reads, shared reads and ticks identical to the written design |
| Vector unit version 2, 4 lanes (memories kept as memory blocks) | 128,041 | 2^x and 1/x on 5,120 inputs incl. every exponent; softmax, RMSNorm, SiLU programs (both versions) | bit exact |
| Whole tile version 4, 4x4 (memories kept as memory blocks) | 207,574 | three layers chained (SiLU -> INT8), every intermediate and final word | bit exact, 5,067 ticks as the written design |

The tile was also run as gates in Verilator with every register starting
at a random value (as on real silicon), three chains, two seeds each: all
bit exact, about 2 seconds per run instead of about 25 minutes.

**A real finding.** The first gate-level run of the tile never finished.
The post-processing stage's write-out counter is set to 0 when that stage
starts, but in the gates its lowest bit came out unknown: the gate logic
for it mixes in the counter's previous value, which had never been set.
The unknown then spread through every count. On real silicon a register
always holds 0 or 1, so the chip would have worked (the random-start runs
show this), but a control counter whose start-up value is undefined is
exactly what reviewers flag. Fixed: the stage's counters are now reset.
No earlier check could see it: the written design's simulator quietly
treats an unknown as "false". This is what gate-level simulation is for.

**Two practical notes.** (1) The arbiter as gates uses a 16-entry list of
reads in flight instead of 256: Yosys ran out of memory on the full list
(as gates, every look-up into it is a large selection circuit; a real chip
would use a small dedicated memory). Same logic, fewer entries; with a
40-tick memory it then pauses new reads sooner. (2) Yosys's optional
memory-sharing optimisation was skipped for the arbiter and the tile: it
ran out of memory on these designs, and it only optimises.

**Vector unit size.** At 4 lanes, version 1 is 63,280 gates and version 2
128,041: one-instruction 2^x and 1/x about **double** the vector unit
(about 16,000 more gates per lane, mostly the wide multipliers of their
correction steps). For comparison, the whole 4x4 engine with its
controller is 89,325. The engine grows with N x N, the vector unit with N,
so at 16 x 16 the vector unit would be roughly a third of the engine's
gates. Next: narrower multipliers for the corrections, or one 2^x / 1/x
unit shared by several lanes over a few ticks (as GPUs do); area on a real
cell library still to be estimated (W2).

## 2026-11-25 - Gate level, larger engines (8x8; 16x16 below), with random start values

**What was done.** The engine with its tiling controller turned into gates
at 8x8 (275,606 gates; 4x4 was 89,325) and run in Verilator, which is fast
enough for gates this size and starts every register at a random value, as
real silicon does. Each test ran with several different random starts.

| Engine | Tests (format pairs) | Random starts each | Result | Ticks vs written design |
|---|---|---|---|---|
| 4x4 | 5 (FP8, INT8, FP4, two mixed) | 5 | all 25 bit exact, written design too | identical |
| 8x8 | 3 (FP8, FP4, FP8 x FP4) | 3 | all 9 bit exact | identical (792, 216, 408) |
| 16x16 | 2 (FP8 x FP4, FP4) | 2 | all 4 bit exact | identical (552, 104) |

Sizes as gates (engine + tiling controller): 4x4 89,325; 8x8 275,606;
**16x16 982,700** (one engine cell 778 gates, one multiplier 2,211, the
shared FP32 adders the rest). The 16x16 conversion first ran out of memory
after 42 minutes when flattened into one circuit; keeping the design's
structure (each repeated cell converted once, the normal practice for
large chips) took 3.5 minutes. `LARGE=1 make gate` reruns all of this.

**What it shows.** The engine behaves the same as gates at every size we
test, 4x4 to 16x16, with any start-up values, so nothing in it depends on
size in a way the smaller tests could miss.

**Found on the way, in the test bench.** With random start values some
runs reported one error although every answer word was right: the test
bench counted the engine's answer writes on every tick, including the tick
before reset took effect, when the write signal can start at 1. The test
bench now counts writes only after reset. The design itself was fine (an
answer write during reset lands in memory that is written again before it
is read).

## 2026-11-25 - First full layout of the 4x4 engine on SkyWater 130 nm (W2)

**What was done.** The 4x4 engine with its tiling controller (`matmul_unit`,
N = 4) went through a complete layout with free tools: OpenROAD
2.0-12381 (litex-hub build) on the open SkyWater 130 nm process (SKY130,
`sky130_fd_sc_hd` cells). Steps: logic to cells (Yosys + ABC), floorplan
(cells cover 45% of the core), power grid, placement, clock tree, timing
repair, global and detailed wiring, extraction of the real resistance and
capacitance of every wire, then timing and power. Asked clock: 8 ns
(125 MHz). Scripts: `tools/w2_layout.sh` (stage 1 `place`, stage 2
`route`), `tools/w2_finish.sh`, `tools/w2_corner.sh`, `tools/w2_paths.tcl`;
outputs in `build/layout/mm4_p8` (not in git; about 2 h 45 min of wiring).

Three chips are timed: **typical** (25 C, 1.80 V), **slow** (a slow batch of
silicon, hot at 100 C, supply low at 1.60 V: the speed one can promise for
every chip) and **fast** (cold at -40 C, 1.95 V: where signals arriving *too
early* can break things). Only the gates change between them; the wires keep
their typical values (one wire model is available), so the slow figure is a
little optimistic.

| | Typical | Slow | Fast |
|---|---|---|---|
| Slowest path inside the engine | 9.29 ns | 20.34 ns | 5.85 ns |
| **Clock it can run at** | **about 106 MHz** | **about 49 MHz** | about 137 MHz (171 inside) |
| Hold check, register to register | +0.185 ns, passes | +0.481 ns, passes | +0.072 ns, passes |
| Hold check, inputs to registers | +0.33 ns | **-0.47 ns, fails** | +0.68 ns |
| Power at 125 MHz, inputs switching 10% / 20% / 50% of ticks | 93 / 120 / 193 mW | 73 / 95 / 152 mW | 108 / 139 / 223 mW |

Area: the gates take **0.66 mm²** (658,620 µm²: 6,278 flip-flops and the
logic, buffers and clock tree); the die is 1.07 x 1.07 mm, **1.155 mm²**,
the rest being room for wiring and the power grid (filled with filler
cells). Logic synthesis alone gave 500,588 µm²; the layout adds 32%, mostly
buffers that timing repair inserts to drive long wires, and the clock tree.
Power splits about 34% flip-flops, 43% logic, 24% clock tree (typical, 20%).
Clock skew (how unevenly the clock reaches the 6,278 flip-flops) 0.20 ns.

**In plain words.** A typical chip from this layout would run the engine at
about 106 million ticks a second, and about 49 million is what every chip
could be promised. It is about 1 mm on a side in a 2001-era process and
uses roughly a tenth of a watt. Power is the least certain number: the tool
has no simulation trace here, so it assumes how often signals switch.

**What limits the speed.** The slowest path at every corner is the same
small piece: step S1a of the shared FP32 adder (`fp32_s1a_unpack`), from the
hand-off register `q0_x` to `q1_B`. It checks whether the 48-bit sum is zero
and flips its sign. Logic synthesis built both as one long chain of 18
three-input OR gates (each waits for the one before), about 6.5 ns of the
9.3 ns. Written as a tree it would be about 4 gates deep. This is the same
kind of problem as the ripple adders found earlier (D-019): ABC rebuilds
chains from wide operations. Fixing it is the next step; the engine's other
paths are not yet measured behind it.

**Other findings.**
- The slowest path overall at the typical corner (9.43 ns) runs straight
  from a setting input (`cfg_beats`) to a memory address output (`a_addr`)
  with no register in between. It depends on the assumed time outside the
  chip (20% of the tick on each side), so it is reported but not counted as
  the engine's speed. A register on the address outputs would remove it.
- The slow-corner hold failure (-0.47 ns) is also at the inputs (`b_data`
  into the engine), where the slow clock tree reaches the flip-flops late.
  It comes from the same assumed outside timing; timing repair here ran at
  the typical corner only. Repair at several corners at once fixes it.
- ABC's `dc2` step turned the Kogge-Stone adders (D-019) back into ripple
  chains: with it, the first layout ran at about 52 MHz. It is now left out
  of `tools/w2_abc.script`; logic-only figures change with it (matmul_unit
  7.46 ns, systolic_v5 7.1 ns, area about 7% larger), and the 8.3 ns of
  2026-11-22 cannot be reproduced with today's tools.

**What is not finished.**
- Wiring ended with **15 rule violations** (5 shorts, 7 metal spacing, 3
  via spacing) out of about 70,000 connections, down from 100,066 on the
  first pass. A layout to manufacture needs zero; usually a little more
  space in the crowded spots clears them.
- The wire measurement (OpenRCX) stops on a wire touching another pin. 9
  connections were set aside and timed as if their wire were perfect
  (`extract_skipped_nets.txt`); none is on the slowest internal path at
  the typical or slow corner (one is on it at the fast corner).
- Detailed wiring takes 2 h 45 min on 4 cores, more than one background job
  may run here, so it was run detached.

## 2026-11-26 - Layout rerun with the zero check built as a tree (W2)

**What was changed.** Step S1a of the shared FP32 adder (`fp32_s1a_unpack`
in `rtl/fp32_add_fx.v`) now builds "is any lower bit of x set" as a
6-level tree and takes both the magnitude of x and the zero check from it.
Before, written as `x[47] ? -x : x` and `x == 0`, synthesis built a chain
of 48 one-after-another ORs (previous section). The new module is proven
to give the same outputs as the old one for every input (Yosys miter + SAT
proof); `make test-fp32` (200,000 cases) and `make test-v5` (4x4, 8x8,
16x16) pass. Same layout flow and settings as before; outputs in
`build/layout/mm4_p8_tree`.

| | Before (chain) | After (tree) |
|---|---|---|
| Slowest internal path, typical | 9.29 ns | 9.34 ns |
| Slowest internal path, slow corner | 20.34 ns (49 MHz) | **18.60 ns (54 MHz)** |
| Slowest internal path, fast corner | 5.85 ns | 5.94 ns |
| Clock, typical (all paths) | 106.1 MHz | 106.4 MHz |
| Hold, register to register (typ / slow / fast) | +0.185 / +0.481 / +0.072 ns | +0.176 / +0.466 / +0.069 ns |
| Hold, inputs to registers, slow corner | -0.47 ns | -0.47 ns |
| Cell area | 658,620 µm² | 660,038 µm² |
| Die | 1.155 mm² | 1.165 mm² |
| Power, typical, 10% / 20% / 50% switching | 93 / 120 / 193 mW | 94 / 122 / 199 mW |
| Wiring time | 2 h 44 min | 3 h 43 min |
| Wiring rule violations left | 15 | 45 (21 shorts) |
| Connections timed without wire measurement | 9 | 6 (none on the slowest paths) |

**In plain words.** The chain is gone, and the speed every chip could be
promised (the slow corner) went up about 9%, from 49 to 54 MHz. A typical
chip did not get faster: the next-slowest path was almost exactly as slow
as the chain and now sets the limit at about 107 MHz inside the engine.
Area and power are unchanged within 1-3%.

**What now limits the speed.** At the typical and slow corners the slowest
path starts at the last adder step's register (`q4_s`, step S4: rounding
and packing the FP32 result) and ends in the engine cell's own registers:
S4's rounding and the hand-back of the new total to the cell happen in one
tick, about 32 gates deep, with no single long chain. The usual fix is to
give the hand-back its own tick, which changes the adder's latency from 5
to 6 ticks and needs the engine's hazard rules and tests checked again.

**Wiring.** This run took an hour longer and ended with more violations
(45 vs 15), from a slightly different placement of nearly the same gates:
the result of a wiring run varies this much between runs. It strengthens
the case for giving crowded areas more room (lower cell density) before
the next run.

## 2026-11-26 - Layout with rounding step S4 split in two (W2)

**What was changed.** The shared FP32 adder gets one more tick (6 -> 7
ticks from request to new total). It was first placed on the hand-back
to the cell, but stage 1 of the layout showed rounding step S4 itself was
slow: the slowest path simply ended at the new register (about 9.4 ns).
So S4 is now two steps, `fp32_s4a_shift` (shift into place, keep guard
and sticky bits) and `fp32_s4b_pack` (round, pack, hand back), with the
register between them. The split S4 is proven equal to the old one for
every input (Yosys miter + SAT). Consequences: output rows leave N + 8 + r
ticks after a job's last beat, and an MX block needs at least
max(min(G, N), 7) beats (standard blocks are 16 or 32). The formal proofs
of the engine (4x4 and 8x8, 2 to 8 cells per adder) and the tiling
controller pass with the new rule, and fail if 6-beat blocks are allowed.
`make test` passes (after installing PyTorch for `test-compile`) and
`make mutants` catches 47 of 47 planted bugs; three mutations were updated
to the new code, and a fourth (tile v3) had stopped applying earlier, in
f4996d9, so the mutations after it had not run.

| | Chain (first) | Tree (2nd) | **S4 split (3rd)** |
|---|---|---|---|
| Slowest internal path, typical | 9.29 ns | 9.34 ns | **9.09 ns** |
| Slowest internal path, slow corner | 20.34 ns | 18.60 ns | 18.74 ns |
| Slowest internal path, fast corner | 5.85 ns | 5.94 ns | 5.64 ns |
| Clock, typical / slow / fast | 106 / 49 / 137 MHz | 106 / 54 / 137 MHz | **109 / 53 / 140 MHz** |
| Hold, register to register, fast corner | +0.072 ns | +0.069 ns | +0.052 ns |
| Hold, inputs to registers, slow corner | -0.47 ns | -0.47 ns | -0.44 ns |
| Cell area | 658,620 µm² | 660,038 µm² | 655,186 µm² |
| Die | 1.155 mm² | 1.165 mm² | 1.161 mm² |
| Power, typical, 20% switching | 120 mW | 122 mW | 124 mW |
| Wiring violations left | 15 | 45 | 33 |
| Wiring time | 2 h 44 min | 3 h 43 min | 5 h 15 min (shared the machine with the tests) |

**In plain words.** The adder is no longer what limits the speed. A
typical chip gains about 3% (106 -> 109 MHz) and the slow-corner figure
stays about 53 MHz. At every corner the slowest path is now the
**multiplier inside each engine cell**: from the numbers coming in
(`a_bus`, `b_bus`) to the product register `p`, about 30 gates in one
tick. That is the next step to pipeline (D-026 target). Two of the 7
connections timed without wire measurement lie on the typical-corner
slowest path, so the 109 MHz figure is slightly optimistic; none is on the
slow- or fast-corner path.

## 2026-11-26 - Two-tick multiply (D-027) and first ASAP7 placement (W2)

**What was changed.** The engine cell's multiply now takes two ticks
(`mx_mul_s1`: decode and multiply the significands; register; `mx_mul_s2`:
shift and add). Every multiplier input checked (2,088,968 cases, 0
errors); `make test-v5` bit exact at 4x4, 8x8, 16x16; all formal proofs
pass (rows now leave N + 9 + r ticks after a job's last beat). The
layout flow now runs on ASAP7 (`PDK=asap7`, D-027).

**First ASAP7 placement** (4x4 `matmul_unit`, typical corner TT 25 C,
0.70 V, 0.75 ns asked, wires estimated from global routing, before
detailed wiring): logic alone 0.68 ns; with placement and estimated wires
1.134 ns, **about 882 MHz**; 10,737 µm² of cells on a 0.023 mm² die
(about 50x smaller than SKY130). The slowest path was not the multiplier:
one request flip-flop per cell steered about 140 bits of the shared
adder's input select through 500 ps of buffers. The select is now an
AND-OR steered by 8 copies of the flag (formal proofs and `make test-v5`
pass); its placement is being rerun.

**Progress score (0-10 scale, D-026; 10 = H100 peak, about 1,000 trillion
8-bit multiplications per second).** 16 cells x 1 multiplication per tick:
- SKY130, last measured clock 109 MHz: 1.7 billion per second, **0.000017**.
  The two-tick multiply does not change this yet: SKY130 has not been laid
  out again, so its new clock is not measured.
- ASAP7, 882 MHz (estimated wires, before the select fix): 14 billion per
  second, **0.00014**. Moved by the process change (7 nm instead of
  130 nm), not by the multiply change. Not yet a finished-layout figure.
The score's big steps come later: 32x32 engines (64x the cells per
engine) and about 500 engines (500x).

## 2026-11-26 - First finished ASAP7 layout of the 4x4 engine (W2)

**What was done.** `matmul_unit` (N = 4) with the two-tick multiply and the
AND-OR adder select, through the whole flow on ASAP7 (`PDK=asap7`, 0.75 ns
asked): placement, clock tree, wiring (1 h 12 min), extraction of the real
wires, timing at three corners. Outputs in `build/layout/mm4_asap7_p075b`.

| | Typical (TT, 25 C, 0.70 V) | Slow (SS, 100 C, 0.63 V) | Fast (FF, 0 C, 0.77 V) |
|---|---|---|---|
| Slowest path inside the engine | 1.013 ns | 1.473 ns | 0.760 ns |
| **Clock it can run at (inside)** | **about 987 MHz** | **about 679 MHz** | about 1,316 MHz |
| Including the memory-address outputs | 928 MHz | 672 MHz | 1,129 MHz |
| Hold, register to register | +0.011 ns | +0.028 ns | -0.0003 ns |
| Power at 1.33 GHz, 10% / 20% / 50% switching | 41 / 53 / 73 mW | 42 mW (20%) | 70 mW (20%) |

Area: 10,655 µm² of gates (0.0107 mm²) on a 0.023 mm² die, about 60x
smaller than on SKY130. Power splits 32% flip-flops, 52% logic, 16% clock
tree. Wiring left 102 rule violations (64 shorts) out of about 86,000
connections; all wires were extracted (none skipped).

**In plain words.** On a 7 nm process the same engine runs about 9 times
faster (987 MHz against 109 MHz) in about 1/60 of the area. The fast-corner
hold figure is a fraction of a picosecond short: a hold buffer or two fixes
it. The slow-corner clock (679 MHz) is the one every chip could be
promised; ASAP7's numbers are predictions, not a factory's.

**What limited the speed.** The shared adder's input: picking the
requesting cell, then adding its block total and product (a 48-bit add that
synthesis built as a ripple chain, after five buffers spreading the request
flag). Fixed since: each cell now sends its finished sum, which it already
computes, so the add runs while the flag spreads (`make test-v5` bit
exact). The placement of that version puts the multiplier's first half
(decode + 9 x 9 multiply, about 0.93 ns) on top next.

**Progress score (D-026 scale).** 16 cells x 987 MHz = 15.8 billion 8-bit
multiplications per second: **0.00016** (SKY130: 0.000017). Moved by the
7 nm process and the adder-select fix.

## 2026-11-26 - Step 4: network, HBM controller and on-chip memory, end to end

**What was built.** The on-chip network (D-028: `noc_router.v`,
`noc_mesh.v`), an HBM pseudo-channel controller (D-029: `hbm_ctrl.v`,
checked against `tests/hbm_dram_model.v`, which tests every DRAM timing
rule) and shared on-chip memory blocks (D-030: `sram_node.v`), wired into
one memory system (`tests/tb_fabric.v`): a 6 x 4 grid, HBM controllers on
the left and right edges (8 channels), 5 memory blocks and 11 tiles inside,
one mesh for requests and one for answers.

| Check | Result |
|---|---|
| Router, formal (any traffic, queue depths 2 and 4) | no overflow, credits conserved, right turns, nothing lost, fair |
| Network, random traffic (4x4, 8x8, 3x5; 3 patterns) | every flit once, in order; about 6 ticks per trip at light load |
| HBM controller vs DRAM model (4 patterns) | 0 timing-rule breaks, 0 data errors |
| Whole memory system (5 patterns, 3,300-16,500 requests) | 0 errors |
| Planted bugs (router 4, controller 4, memory system 2) | all caught |

**Measured** (ticks of a ~1.2 GHz clock; 100% = the channel's peak):

| Traffic | Share of HBM bandwidth used | Answer time |
|---|---|---|
| One stream on one channel | 91% | 45-53 ticks |
| Random reads on one channel | 33% (DRAM rules cap it at 40%) | 115 ticks |
| 11 tiles streaming at once, 8 channels | 61% (27% before bank hashing) | 132 ticks |
| 11 tiles, random reads | 32% | 200 ticks |
| 11 tiles, on-chip memory blocks | 59% of the blocks' peak | 47 ticks |

**In plain words.** Every part of the memory path works and is checked.
HBM delivers close to its peak when one stream reads it in order, about
60% when many tiles share it, and about a third for scattered reads, which
is typical for DRAM. The on-chip memory answers about three times sooner
than HBM. These shares go into the whole-chip performance model (step 5).
The sizing for the full chip (D-030): memory controllers on all four edges
and 64-byte words, and the middle of the network needs checking under full
load.
