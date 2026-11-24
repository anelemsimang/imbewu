# Roadmap

Goal: a simulation-ready pitch package for the Imbewu data-centre AI
accelerator. Tags G1-G5 refer to the five design goals in VISION.md.

The phases below build the hardware. Alongside them run five workstreams
(section "Workstreams") that answer the known limitations of an AI-led
design effort (see DECISIONS.md, D-013).

## Phase 0 - Foundation ✅ done
- [x] Repository, vision, decision log, learning notes
- [x] Free simulation toolchain (Icarus Verilog, Yosys)
- [x] First building block: multiply-accumulate (MAC) unit, 1,000 tests passing

## Phase 1 - Compute core 🔨 in progress  (G1, G5)
- [x] 4x4 systolic matrix-multiply engine (`rtl/systolic_array.v`),
      1,003 matrix multiplications / 16,048 results checked, 0 errors
- [x] Grid size is a parameter (`rtl/systolic_array.v`); 4x4, 8x8 and 16x16
      verified, 0 errors in 337,008 checked results (see docs/RESULTS.md)
- [x] Streaming engine (`rtl/systolic_stream.v`): jobs back to back, utilisation
      33% -> 99.5% at 4x4, 8x8 and 16x16, 0 errors (see docs/RESULTS.md)
- [x] Long products: the shared dimension K can be any length >= N
- [x] Larger matrices: tiling controller (`rtl/matmul_unit.v`) splits C into
      N x N tiles and runs them back to back; bit exact on 10 multiplies,
      formally proven to obey the engine's rules; overhead 2N+4 ticks per multiply
- [x] Precision flexibility v1 (`rtl/systolic_mx.v`): INT8, FP8 E4M3 and FP4 E2M1
      with OCP MX block scales, format switchable per job, exact results,
      FP4 at 2x speed; 0 errors in 336,000 checked results (see docs/RESULTS.md)
- [x] Version 4 engine (`rtl/systolic_v4.v`): many MX blocks per job summed
      inside each cell into FP32 (rounded once per block), any pairing of
      formats per side; 0 errors, formal proof, real model data bit exact
- [x] Version 5 (`rtl/systolic_v5.v`): shared, two-tick FP32 adders (D-017);
      same answers as version 4, 4x4 grid 54% smaller, proven never to
      double-book an adder (D-018)
- [ ] Precision v2 rest: 4x FP4 packing, FP8 E5M2, NaN handling
- [x] Attention scores with 14-bit K on today's engine: K split into two
      INT8 blocks by the compiler (D-021), whole model +6.5%
- [x] The K split in the compiler (`imbewu_attention_scores`), bit exact on
      the simulated tile with real Qwen Q and K
- [ ] Dedicated MXINT16 hardware if very long contexts need full speed; BF16
      later, for training
- [x] Real model numbers on the chip: Qwen2.5-0.5B activations and weights run
      through the 16x16 engine in simulation; output matches software exactly
      (`tools/real_model_on_chip.py`, `results/`)
- [x] Accuracy check: INT8 / FP8 / FP4 on three public language models
      (INT8 under 1% loss, FP8 under 4%, FP4 alone too lossy on small models;
      see docs/RESULTS.md)
- [x] Mixed-format mode: FP4 weights x FP8 activations in one job (D-015);
      on real data, error 14.2% vs 18.8% for FP4 on both sides
- [ ] First energy-per-operation estimate for each format
- [ ] Waveform walkthrough for Anele

## Phase 2 - The Imbewu tile  (G1, G3, G5)
- [x] Local memory (SRAM) inside the tile, two halves per operand (`rtl/tile_v1.v`)
- [x] Data mover that loads the next block while the current one computes:
      85% engine busy when memory keeps up, bit exact on 6 test runs
- [x] Keep weights resident across commands (`rtl/tile_v2.v`): 2.5x fewer
      memory reads, 1.9-2.2x faster on decode-style work
- [x] Overlap transfer start-up delays (request and answer sides split)
- [x] Prefetch weights further ahead, independently of activations
      (`rtl/tile_v3.v`): decode-style run 40% -> 84% engine busy since tile v1
- [x] A small RISC-V control core per tile: PicoRV32 (open source) runs a C
      driver that builds the command list (`rtl/tile_soc.v`, `fw/`)
- [x] Vector unit for the non-matmul parts of AI (`rtl/vu_v1.v`): softmax,
      RMSNorm, SiLU bit exact vs emulator, within 1e-6 of PyTorch
- [ ] Connect the vector unit to the tile; native exp2 / reciprocal steps
- [ ] Tile instruction set, documented
- [ ] Run one real neural-network layer end-to-end in simulation
- [ ] Power gating: switch off idle parts of the tile

## Phase 3 - Scale-up  (G2, G3)
- [x] 4-tile simulation: tiles sharing main memory through an arbiter;
      scaling measured (docs/RESULTS.md, 2026-11-24)
- [x] Broadcast of shared activations to several tiles: tiles join reads
      already in flight (D-022): 1.8x faster on one channel, reads halved
- [ ] On-chip network connecting tiles
- [ ] 16-tile simulation
- [ ] HBM memory controller and bandwidth model
- [ ] Chip-to-chip link design based on open standards (UALink / Ultra Ethernet)
- [ ] Collective operations in hardware (the data exchanges chips do during
      training, such as all-reduce), so chips don't sit idle

## Workstreams (run alongside the phases)

### W1 - Verification depth (limitation 3: "PASS doesn't prove it works")
Already in place: random tests against independent reference models,
deliberately planted bugs, real model data.
- [x] Formal proof (Yosys + Yices, free) of the multi-format engine's output
      rules: no lost or extra rows, correct order and timing, right scales
      per job; all time, sizes 2x2 to 16x16 (`make formal`)
- [x] Exhaustive test of one multi-format cell on all 262,144 inputs
      (`make test-cell`) and 10 planted bugs all caught (`make mutants`)
- [ ] Formal proof of no overflow within the stated limits, and of the
      grid's sums (equivalence checking)
- [ ] Coverage measurement: report which parts of each design the tests reached
- [ ] Assertions inside the designs, checked during every simulation
- [ ] Lint checks (Verilator) on every design, run by `make test`
- [ ] One command that re-runs every test after every change
- [ ] Gate-level simulation: re-run the tests on the circuit after synthesis
      (catches differences between the design and what the tools built)
- [ ] FPGA prototype running real models at real speed. Moved earlier
      (community input, 2026-11-24): open projects run small accelerators on
      low-cost boards, so a 4x4 tile demo may be affordable before funding;
      a board purchase is the founder's decision

### W2 - Real physical numbers (limitation 4: no secret factory rules)
- [x] First step: engine mapped onto real cell libraries (SKY130, open 45 nm)
      with free tools: area and logic-only clock speed; slow paths found and
      fixed (`tools/w2_estimate.sh`, D-019)
- [ ] Full layout flow (OpenLane / OpenROAD) on SKY130 or GF180: placement,
      wiring, real clock speed and power. Watch for what hobby designs hit
      here (community input, 2026-11-24): wiring congestion around wide
      buses, clock skew across the grid, and power-supply droop when every
      multiplier switches at once
- [ ] Scale those numbers to modern processes using published industry data,
      clearly labelled as estimates
- [ ] List of blocks that must be licensed (HBM interface, high-speed links,
      PCIe) with indicative costs, for the cost plan

### W3 - Software stack (limitation 5: the "CUDA moat")
- [ ] Instruction set for the tile, designed together with its compiler
- [x] Simple compiler path: one PyTorch layer -> tile commands -> simulated
      tile -> PyTorch tensor, bit exact; real Qwen layer run
      (`tools/imbewu_compile.py`, `make test-compile`)
- [ ] Build on open compiler frameworks (MLIR / IREE or TVM), not from scratch
- [x] A real language model (Qwen2.5-0.5B) end to end on Imbewu's exact
      arithmetic (`tools/imbewu_numerics.py`): FP8 +13% perplexity, +6% with
      16-bit attention scores (D-021)
- [ ] Goal for the pitch: the same model end to end on the simulated tile
      itself (needs a much faster simulator, e.g. Verilator)

### W4 - Performance model early (limitation 1: specification)
- [x] First analytical performance model now, not at the end: given a design
      (grid size, memory, bandwidth), how fast does a real language model run
      and where does it wait? Use it to choose designs before building them
- [ ] Check the model against our own simulations as they grow
      (engine part checked: exact match on 9 job streams; memory, links and
      tiling to be checked as those blocks are built)
- [ ] Power model, so performance per watt (G5) can be estimated
- [ ] Optionally cross-check with MIT's open Timeloop / Accelergy tools

### W6 - From the community reading (docs/research/community_reading_2026-11-24.md)
- [ ] Spare tiles and a "disable this tile" switch, so a chip with a
      manufacturing defect can still be sold (yield)
- [ ] Cost per good chip (with yield) in the cost model (G5)
- [ ] Performance model: prefill and decode reported separately
- [ ] Simulate a mixed cluster: one large grid for feed-forward layers,
      smaller grids for attention
- [ ] Power: engine hot spots and a fast power limiter
- [ ] Write a "good enough" list beside G1-G5: what we deliberately keep
      simple

### W5 - People, partners and gatekeepers (limitation 6; founder-led)
- [ ] External technical review of the architecture before the pitch
      (university chip-design group or independent consultant)
- [ ] Technical advisor, then technical co-founder (experienced chip architect)
- [ ] University partnerships for review and graduate talent
- [ ] Shortlist of design-house partners for physical design and foundry access
- [ ] Legal advice on export controls (buying and building advanced AI chips)

## Phase 4 - Performance model and pitch pack  (all goals)
- [ ] Training model: time to train a large language model on N Imbewu chips (G1, G2, G3)
- [ ] Inference model: tokens per second, response time, users served, and
      reasoning models that think longer (G4)
- [ ] Power model: performance per watt and per rand, at chip and data-centre scale (G5)
- [ ] Honest comparison with existing chips on all five goals
- [x] Architecture document, first version (`docs/ARCHITECTURE.md` links to it):
      evidence, limits, roadmap and needs, written for funders and reviewers
- [ ] External human review completed and its findings addressed (W5)
- [x] Clear statement in every pitch document: simulation proves the
      architecture works; it does not prove the chip is ready to manufacture
      (in the architecture document)
- [ ] Pitch deck, cost-to-silicon plan, team plan, design-vs-buy list
- [ ] Optional, founder to decide: a small piece of the Imbewu tile on real silicon
      (Tiny Tapeout or wafer.space), only as proof for funders that we can deliver

## Current position
Phase 1 is essentially done: the version 5 engine is the reference design
(D-018): exact block sums, FP32 totals, mixed formats, shared pipelined
adders, formally proven control, first physical estimate (about 400 MHz
logic-only and 3,580 um^2 per cell at 45 nm, D-019). Open Phase 1 items:
energy per operation, waveform walkthrough, precision extras.

Phase 2 is under way: the tile (version 3) has double-buffered SRAM,
weights kept across commands and fetched well ahead, overlapped memory
transfers, and its own RISC-V control core running a C driver.

The first compiler step (W3) runs a real PyTorch layer on the simulated
tile, bit exact. It showed FP4 weights did not yet save memory traffic in
mixed jobs; fixed (D-020).

FP4 weights are now packed two per byte (D-020): half the memory reads and
1.5x faster on the real layer.

The vector unit (version 1) runs softmax, RMSNorm and SiLU.

A whole language model has run on Imbewu's exact arithmetic. Attention
scores need more than 8 bits for K; the compiler can provide 14 bits on
today's engine by splitting K into two INT8 blocks (D-021): +6.5% for the
whole model with FP8 weights.

The split is in the compiler and bit exact on the simulated tile with real
model data.

The architecture document (pitch package part 1) is written.

The multi-tile simulation runs (Phase 3): up to 4 tiles share main memory
through an arbiter, bit exact. With one memory channel extra tiles give no
speed-up; with a channel per tile, 4 tiles are 3.3x faster.

Broadcast works (D-022): tiles reading the same activations share one
memory read. On one memory channel, 4 tiles are now 1.8x faster than
without it, and memory reads halve in every multi-tile case.

The vector unit is inside the tile (tile version 4, D-023): a layer's
answers can be run through SiLU, softmax or RMSNorm, rounded back into MX
blocks in hardware and laid out for the next layer, so one tile runs a
chain of layers with no software in between; bit exact.

The vector unit is faster (version 2, D-024): 2^x and 1/x in one
instruction each; SiLU 7x and softmax 3.7x fewer instructions; for 8B and
70B models it now needs well under half the engine's time.

Next: keep chained results on chip instead of going through main memory;
then the items from the community reading (docs/research/).
