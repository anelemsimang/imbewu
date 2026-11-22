# Roadmap

Goal: a simulation-ready pitch package for the Imbewu data-centre AI
accelerator. Tags G1-G5 refer to the five design goals in VISION.md.

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

## Phase 4 - Performance model and pitch pack  (all goals)
- [ ] Training model: time to train a large language model on N Imbewu chips (G1, G2, G3)
- [ ] Inference model: tokens per second, response time, users served, and
      reasoning models that think longer (G4)
- [ ] Power model: performance per watt and per rand, at chip and data-centre scale (G5)
- [ ] Honest comparison with existing chips on all five goals
- [ ] Architecture document for engineers and reviewers
- [ ] Pitch deck, cost-to-silicon plan, team plan, design-vs-buy list
- [ ] Optional, founder to decide: a small piece of the Imbewu tile on real silicon
      (Tiny Tapeout or wafer.space), only as proof for funders that we can deliver

## Current position
Phase 1. Next step: accuracy check of INT8 / FP8 / FP4 on real AI model data.
