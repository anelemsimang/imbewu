# Roadmap

Goal: a simulation-ready pitch package for the Imbewu data-centre AI
accelerator (see VISION.md).

## Phase 0 - Foundation ✅ done
- [x] Repository, vision, decision log, learning notes
- [x] Free simulation toolchain (Icarus Verilog, Yosys)
- [x] First building block: multiply-accumulate (MAC) unit, 1,000 tests passing

## Phase 1 - Compute core 🔨 in progress
- [x] 4x4 systolic matrix-multiply engine (`rtl/matmul4.v`),
      1,003 matrix multiplications / 16,048 results checked, 0 errors
- [ ] Make the grid size a parameter and verify 8x8 and 16x16
- [ ] Larger matrices: break big matrices into blocks the grid can handle ("tiling")
- [ ] Add a second number format used in modern AI (e.g. FP8 or BF16)
- [ ] Waveform walkthrough for Anele

## Phase 2 - The Imbewu tile
- [ ] Local memory (SRAM) inside the tile to hold weights and activations
- [ ] A small RISC-V control core per tile (from an open-source design)
- [ ] Vector unit for the non-matmul parts of AI (activations, softmax, normalisation)
- [ ] Tile instruction set, documented
- [ ] Run one real neural-network layer end-to-end in simulation

## Phase 3 - Scale-up
- [ ] On-chip network connecting tiles
- [ ] 4-tile, then 16-tile simulation
- [ ] Off-chip memory model (HBM/LPDDR)
- [ ] Chip-to-chip links (how many chips work together in a data centre)

## Phase 4 - Performance model and pitch pack
- [ ] Performance model projecting full-chip results on large language models
- [ ] Honest comparison with existing chips, per watt and per rand
- [ ] Architecture document for engineers and reviewers
- [ ] Pitch deck, cost-to-silicon plan, team plan
- [ ] Optional: a small piece on real silicon via Tiny Tapeout or wafer.space,
      as proof we can deliver

## Current position
Phase 1. Next step: parameterised grid sizes (8x8, 16x16).
