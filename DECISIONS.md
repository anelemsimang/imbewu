# Decision log

Every major decision, with the reason. Newest at the bottom.

### D-001 - Open-source foundations, starting from the ET-SoC-1 family of ideas
The strongest open-source AI chip is the Esperanto ET-SoC-1 (1,024 RISC-V
cores, ~40 W), released under Apache 2.0 by Ainekko's AI Foundry. We study it
and other open designs (Vortex, XiangShan) as public references.

### D-002 - Stage 4 (data-centre AI chip) is the primary focus
Founder's decision. South Africa's ambition to build its own AI models makes
a data-centre design the strongest case for government backing. We design and
prove it in simulation first; manufacturing comes with funding and engineers.

### D-003 - Clean design: public and legitimate sources only
No leaked or confidential designs or documents, even for study. A design
shaped by someone else's trade secrets is legally contaminated, which would
fail investor and government due diligence and invite lawsuits. We use papers,
patents, conference talks, teardown analyses and open-source designs under
their licences. This record of clean origin is itself an asset in the pitch.

### D-004 - Free, open-source tools for all simulation and testing
Icarus Verilog for simulation, Yosys for converting designs into gates, and
later OpenROAD/OpenLane with open process kits (SkyWater 130 nm, GF180) for
layout. Cost: R0.

### D-005 - Continuity through this repository
Claude's memory between chats is limited. This repository is the permanent
record. Each work session starts by reading ROADMAP.md and DECISIONS.md and
ends by updating them.

### D-006 - Systolic array for the compute core
The matrix-multiply engine is a systolic array: a grid of simple cells that
pass numbers to their neighbours. It's a well-published, proven approach
(Kung & Leiserson 1978; Google's TPU papers), uses little power because data
is reused instead of fetched repeatedly from memory, and scales by making the
grid larger. First version: 4x4, INT8 inputs, INT32 results.

### D-007 - Sole focus on the data-centre chip (Stage 4)
Founder's decision. Stages 1-3 (edge chips, inference cards, model-support
products) are removed from the plan. All work goes to the data-centre AI
accelerator and its simulation-based pitch package. Replaces the "ladder"
in earlier versions of VISION.md.

### D-008 - Five design goals
Founder's definition of what the data-centre chip must achieve: massive
parallel computation with flexible precision (G1), high-speed chip-to-chip
communication (G2), ultra-fast memory bandwidth (G3), low-latency,
high-throughput inference (G4) and performance per watt (G5). Each roadmap
item is tagged with the goals it serves.

### D-009 - Open standards for precision and chip-to-chip links
Low-precision formats follow the open OCP Microscaling (MX) specification
(MXFP8, MXFP4 and others) rather than a private format. Chip-to-chip links
build on open industry standards (UALink, Ultra Ethernet) rather than
copying NVLink. Both keep the design clean (D-003) and compatible with
the wider industry.

### D-010 - Streaming engine with tagged data
Version 2 of the matrix engine tags each number with "valid" and "last"
instead of using a central controller to start and stop jobs. Jobs run back
to back, utilisation rises from ~33% to 99.5%, and the shared dimension K
can vary per job. Cost: ~7% more logic. Version 1 (`rtl/systolic_array.v`)
stays in the repository as the simple reference design.

### D-011 - Multi-format engine with exact fixed-point accumulation
Version 3 supports INT8, FP8 E4M3 and FP4 E2M1 (OCP MX v1.0) in one cell,
selected per job by a tag that travels with the data. Products are summed
exactly in a 48-bit fixed-point total (smallest step 2^-18) instead of a
rounding floating-point adder: simpler, exactly verifiable, no rounding error
within a block. MX block scales are applied on the way out as an exponent.
Cost: the cell is 2.2x the INT8-only cell; reduction plans are in
docs/RESULTS.md. FP4 packs two numbers per lane for 2x speed.

### D-012 - Independent Python reference model for verification
Expected answers for the multi-format engine come from tools/gen_mx_vectors.py,
which decodes numbers with the public ml_dtypes library, not with logic copied
from the design, so a shared mistake in design and test is unlikely.

### D-013 - Workstreams answering the limits of an AI-led design team
An external review (another AI tool, shared by the founder) listed six
limits of a founder-plus-AI team: specification, complexity, verification,
physical design, software stack and industry gatekeepers. All six are real;
none blocks the simulation-based pitch, and our plan already requires human
engineers before money is spent on manufacturing. In response the roadmap
adds five workstreams: W1 verification depth (formal proofs, coverage,
lint), W2 real physical numbers (open layout flow), W3 software stack
(PyTorch to Imbewu), W4 an early performance model, W5 people and partners
(external review, advisor, design house, export-control advice). The
software stack was the largest gap in the earlier plan.

### D-014 - Honest scope statement in all pitch material
Every pitch document states plainly that simulation proves the architecture
works, not that the chip is ready to manufacture, and names what is needed
to get there (engineers, licensed blocks, a design house, funding).

### D-015 - INT8/FP8 are the main inference formats; add a mixed FP4 x FP8 mode
The accuracy check (docs/RESULTS.md, 2026-11-22) showed MXINT8 and MXFP8
lose under 4% on three public models, while plain MXFP4 for both weights and
activations loses 51-140%. FP4 weights with FP8 activations loses 14-45%.
So: INT8 and FP8 are the default inference formats; FP4 is offered for
weights, paired with FP8 activations. The engine will gain a mode where the
two inputs of a job use different formats. FP4 accuracy techniques (smaller
blocks, rotations) will be evaluated in software before adding hardware.

### D-016 - Cross-block sums inside the engine are the next hardware priority
The performance model (docs/RESULTS.md, 2026-11-22) shows today's engine
cannot use FP4's double speed on grids larger than 16x16, because one MX
block of FP4 (16 beats) is shorter than the minimum job length (N beats).
Summing many blocks inside the engine (precision v2) removes the limit:
1.76x faster prompt processing in FP4 on the concept chip. It also removes
the need to add partial sums outside the engine. Done before tiling.

### D-017 - Share and pipeline the FP32 adders in the version 4 engine
Version 4 is correct (docs/RESULTS.md, 2026-11-22) but each cell is 4.3x
larger than version 3, three quarters of it the FP32 adder, and the whole
multiply-and-add happens in one tick. Since cells in a row finish a block
one tick apart, one adder can serve many cells in turn (one per 16 cells
for FP4, per 32 for FP8), and it can be split over several ticks. This is
the next hardware step, judged by the same tests and proofs.

### D-018 - Version 5 is the reference engine; blocks of at least 16 beats
Version 5 (shared two-tick FP32 adders, groups of 16 cells) gives the same
bit-exact answers as version 4 at less than half the size, and is formally
proven never to double-book an adder provided every MX block has at least
min(16, N) beats. Standard MX blocks always meet this; software pads a
short final block with zeros. Versions 3 and 4 stay in the repository as
the record of how the design got here.

### D-019 - Physical estimates first on open libraries, then with a partner
Area and clock speed are measured on open cell libraries (SKY130 and an
open 45 nm library) with free tools. They show the design is buildable and
where its slow paths are, but a data-centre chip needs a 3-5 nm process
whose libraries are licensed under NDA. Real numbers for the pitch's target
chip will come from a foundry or design-house partner (W5); until then all
advanced-node figures are labelled as assumptions.

### D-020 - Pack FP4 weights two per lane in mixed jobs
The first compiled model layer (docs/RESULTS.md, 2026-11-23) showed that
FP8 x FP4 jobs move FP4 weights one per 8-bit lane, the same memory
traffic as FP8, so the decode speed-up FP4 weights promise is not yet
real. The engine and data layout will carry two FP4 weights per lane in
mixed jobs (the activation side then supplies two FP8 numbers per beat),
before any FP4 speed claim is made in pitch material.

### D-021 - Attention scores (Q x K^T) get a 16-bit path (MXINT16)
Running a whole model on Imbewu's arithmetic (docs/RESULTS.md, 2026-11-23)
showed that 8-bit MX blocks are fine for the linear layers, the output
layer and probabilities x V, but not for Q x K^T: it alone took the loss
from about +6% to +13% (INT8 no better, so the cause is the shared block
scale). With Q x K^T in BF16 the loss returns to +6.4%; with MXINT16
(16-bit whole numbers sharing one power-of-two scale per block of 32) to
+6.25%, the same as FP32; smaller 8-bit blocks do not help (+10% to +15%).
MXINT16 is chosen over BF16: same accuracy, and it keeps the engine's exact
block sums (BF16 gives every number its own exponent, needing much wider
adders). Pitch material quotes this configuration and states the
requirement.

Update (same day): only K needs the extra precision (Q 8-bit x K 16-bit:
+6.28%). So the requirement is met on today's engine, with no new
hardware: the compiler splits each block of K (14-bit MX whole numbers)
into a high and a low MXINT8 block and repeats Q's block; the engine's
exact block sums do the rest. Whole model: +6.54% (FP8 weights). Cost:
half speed for Q x K^T only (a few per cent of total time up to 4k tokens
of context). Dedicated MXINT16 hardware is kept as an option for very long
contexts.

### D-022 - Tiles share activation reads (broadcast by joining reads in flight)
The multi-tile simulation (docs/RESULTS.md, 2026-11-24) showed that when
memory is the limit, extra tiles add nothing, and that two thirds of the
reads were the same activations fetched by each tile. The cluster now
merges identical reads: a tile asking for an address already being read
(this tick or a few reads earlier, answer not yet returned) joins that
read. Chosen over a separate broadcast bus driven by a scheduler because it
needs no change to the tiles' programs and works even when tiles drift a
few words apart. Commands get a weight-address field (w_at) so many
commands can share one copy of their activations. Measured: 1.4x (2 tiles)
and 1.8x (4 tiles) faster on one memory channel; memory reads halved in
every multi-tile case.

### D-023 - Post-processing stage in the tile (vector unit + MX rounding + transpose)
The vector unit (version 1) worked on its own. To run layers back to back
without software in between, the tile gets a post-processing stage
between the engine and main memory: per command, store FP32 answers,
round them into MX blocks, or run a vector-unit program and then round;
results are written in the engine's own input layout, and a "wait" flag
lets the next command read them. Rounding in hardware follows exactly the
compiler's rule (so the whole-model accuracy results still hold). For now
results pass through main memory, the simplest correct design; keeping
them on chip is a later optimisation. Measured: bit exact on 18 chained
runs; the vector unit becomes the slowest step for SiLU, so its speed is
the next performance question.

### D-024 - One-instruction 2^x and 1/x in the vector unit
Measured (`tools/vu_budget.py`): with software exp and 1/x the vector unit
would take longer than the engine for small models and long contexts.
Version 2 adds 2^x and 1/x as single instructions (defined exactly in
`tools/vu_asm.py`, tables generated from the definition) and constant
operands. SiLU 50 -> 7 and softmax 41 -> 11 instructions per vector.
Accuracy below 2^-21 relative; whole-model perplexity +6.88% vs +6.54%
before (FP8 weights). Chosen over fused multiply-add alone (smaller gain)
and over more lanes (more area, same instruction count). The same 1:N
ratio of vector lanes to engine multiply-adds as TPUv2 at N = 16.

### D-025 - Layout flow: OpenROAD from litex-hub, no `dc2` in logic synthesis
The layout tools come from the litex-hub conda channel, with Anaconda's
main channel added for the older libraries OpenROAD 2.0-12381 needs (the
channel's own build cannot be solved without it; Anaconda's terms apply
to that channel). Chosen over building OpenROAD from source (hours per
fresh session) and over the "openroad" PyPI package (no author, no build
record). In logic synthesis ABC's `dc2` step is dropped: it rebuilt the
Kogge-Stone adders of D-019 as ripple chains and halved the clock (about
52 MHz instead of 106 MHz on the first layout). Slow and fast corner
libraries come from litex-hub's open_pdks.sky130a package, checked against
its published SHA-256.
