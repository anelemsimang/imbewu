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
