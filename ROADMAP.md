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
- [ ] Larger matrices: a controller that breaks big matrices into blocks the
      grid can handle ("tiling") and schedules them
- [x] Precision flexibility v1 (`rtl/systolic_mx.v`): INT8, FP8 E4M3 and FP4 E2M1
      with OCP MX block scales, format switchable per job, exact results,
      FP4 at 2x speed; 0 errors in 336,000 checked results (see docs/RESULTS.md)
- [ ] Precision v2: shared exponent alignment per block (smaller cells),
      4x FP4 packing, FP8 E5M2, NaN handling
- [ ] BF16 for training, and FP32 totals across many MX blocks
- [x] Real model numbers on the chip: Qwen2.5-0.5B activations and weights run
      through the 16x16 engine in simulation; output matches software exactly
      (`tools/real_model_on_chip.py`, `results/`)
- [ ] Accuracy check: run each format on real AI model data and measure the loss
- [ ] First energy-per-operation estimate for each format
- [ ] Waveform walkthrough for Anele

## Phase 2 - The Imbewu tile  (G1, G3, G5)
- [ ] Local memory (SRAM) inside the tile to hold weights and activations
- [ ] Data mover that loads the next block while the current one computes,
      so the engines never wait for memory
- [ ] A small RISC-V control core per tile (from an open-source design)
- [ ] Vector unit for the non-matmul parts of AI (activations, softmax, normalisation)
- [ ] Tile instruction set, documented
- [ ] Run one real neural-network layer end-to-end in simulation
- [ ] Power gating: switch off idle parts of the tile

## Phase 3 - Scale-up  (G2, G3)
- [ ] On-chip network connecting tiles
- [ ] 4-tile, then 16-tile simulation
- [ ] HBM memory controller and bandwidth model
- [ ] Chip-to-chip link design based on open standards (UALink / Ultra Ethernet)
- [ ] Collective operations in hardware (the data exchanges chips do during
      training, such as all-reduce), so chips don't sit idle

## Workstreams (run alongside the phases)

### W1 - Verification depth (limitation 3: "PASS doesn't prove it works")
Already in place: random tests against independent reference models,
deliberately planted bugs, real model data.
- [ ] Formal verification with SymbiYosys (free): mathematically prove key
      properties of each block (no lost or duplicated results, correct
      read-out order, no overflow within the stated limits)
- [ ] Coverage measurement: report which parts of each design the tests reached
- [ ] Assertions inside the designs, checked during every simulation
- [ ] Lint checks (Verilator) on every design, run by `make test`
- [ ] One command that re-runs every test after every change
- [ ] Later, with funding: FPGA prototype running real models at real speed

### W2 - Real physical numbers (limitation 4: no secret factory rules)
- [ ] Run the Imbewu tile through the open-source layout flow (OpenLane /
      OpenROAD) on open factory rules (GF180 or SkyWater 130 nm): real area,
      clock speed and power, replacing generic logic-cell counts
- [ ] Scale those numbers to modern processes using published industry data,
      clearly labelled as estimates
- [ ] List of blocks that must be licensed (HBM interface, high-speed links,
      PCIe) with indicative costs, for the cost plan

### W3 - Software stack (limitation 5: the "CUDA moat")
- [ ] Instruction set for the tile, designed together with its compiler
- [ ] Simple compiler path: one PyTorch layer -> Imbewu instructions ->
      simulated tile, checked against PyTorch's own answer
- [ ] Build on open compiler frameworks (MLIR / IREE or TVM), not from scratch
- [ ] Goal for the pitch: a real (small) language model running end to end
      on the simulated Imbewu design

### W4 - Performance model early (limitation 1: specification)
- [ ] First analytical performance model now, not at the end: given a design
      (grid size, memory, bandwidth), how fast does a real language model run
      and where does it wait? Use it to choose designs before building them
- [ ] Check the model against our own simulations as they grow
- [ ] Optionally cross-check with MIT's open Timeloop / Accelergy tools

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
- [ ] Architecture document for engineers and reviewers
- [ ] External human review completed and its findings addressed (W5)
- [ ] Clear statement in every pitch document: simulation proves the
      architecture works; it does not prove the chip is ready to manufacture
- [ ] Pitch deck, cost-to-silicon plan, team plan, design-vs-buy list
- [ ] Optional, founder to decide: a small piece of the Imbewu tile on real silicon
      (Tiny Tapeout or wafer.space), only as proof for funders that we can deliver

## Current position
Phase 1. In progress: accuracy check of INT8 / FP8 / FP4 on three public
language models. Next: write up results, then start W1 (formal verification)
and W4 (early performance model) alongside tiling.
