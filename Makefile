# Imbewu - run all free simulation tests with:  make test
# Size of each circuit in logic cells:           make synth
BUILD  := build
SIZES  := 4 8 16
TRIALS := 1000

.PHONY: test test-mac test-systolic test-stream test-mx test-cell test-mul test-fp32 test-v4 test-v5 test-tile test-tile-v1 formal mutants perf synth clean

test: test-mac test-systolic test-stream test-mx test-cell test-mul test-fp32 test-v4 test-v5 test-tile test-tile-v1

test-mac:
	@mkdir -p $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_mac rtl/mac.v tests/tb_mac.v
	vvp -n $(BUILD)/tb_mac

# Builds and tests the systolic engine at every grid size in SIZES
test-systolic:
	@mkdir -p $(BUILD)
	@for n in $(SIZES); do \
	  iverilog -g2012 -DGRID_N=$$n -DTRIALS=$(TRIALS) -o $(BUILD)/tb_systolic_$$n \
	    rtl/pe.v rtl/systolic_array.v tests/tb_systolic_array.v || exit 1; \
	  vvp -n $(BUILD)/tb_systolic_$$n || exit 1; \
	done

# Version 2: the streaming engine, at every grid size in SIZES
test-stream:
	@mkdir -p $(BUILD)
	@for n in $(SIZES); do \
	  iverilog -g2012 -DGRID_N=$$n -DJOBS=300 -o $(BUILD)/tb_stream_$$n \
	    rtl/pe_stream.v rtl/systolic_stream.v tests/tb_systolic_stream.v || exit 1; \
	  vvp -n $(BUILD)/tb_stream_$$n || exit 1; \
	done

# Version 3: multi-format engine (INT8 / FP8 / FP4 with MX scales).
# Expected answers come from an independent Python model (tools/), which
# needs: pip install -r tools/requirements.txt
MX_SCENARIOS := int8 fp8 fp4 mixed mixed_gaps
test-mx:
	@mkdir -p $(BUILD)/vectors
	@for n in $(SIZES); do \
	  python3 tools/gen_mx_vectors.py $$n $(BUILD)/vectors || exit 1; \
	  iverilog -g2012 -DGRID_N=$$n -o $(BUILD)/tb_mx_$$n \
	    rtl/pe_mx.v rtl/systolic_mx.v tests/tb_systolic_mx.v || exit 1; \
	  for s in $(MX_SCENARIOS); do \
	    vvp -n $(BUILD)/tb_mx_$$n +PRE=$(BUILD)/vectors/mx_N$${n}_$$s || exit 1; \
	  done; \
	done

# One multi-format cell on every possible input (262,144 cases)
test-cell:
	@mkdir -p $(BUILD)
	python3 tools/gen_cell_exhaustive.py $(BUILD)/cell_exh.hex
	iverilog -g2012 -o $(BUILD)/tb_cell_exh rtl/pe_mx.v tests/tb_pe_mx_exhaustive.v
	vvp -n $(BUILD)/tb_cell_exh +EXP=$(BUILD)/cell_exh.hex

# Version 4: mixed-format multiplier on every possible input (1,048,576 cases)
test-mul:
	@mkdir -p $(BUILD)
	python3 tools/gen_mul_exhaustive.py $(BUILD)/mul_exh.hex
	iverilog -g2012 -o $(BUILD)/tb_mul_exh rtl/mx_mul.v tests/tb_mx_mul_exhaustive.v
	vvp -n $(BUILD)/tb_mul_exh +EXP=$(BUILD)/mul_exh.hex

# Version 4: FP32 block-total adder against an exact-fraction reference
test-fp32:
	@mkdir -p $(BUILD)
	python3 tools/fp32_ref.py $(BUILD)/fp32 200000
	iverilog -g2012 -o $(BUILD)/tb_fp32 rtl/fp32_add_fx.v tests/tb_fp32_add.v
	vvp -n $(BUILD)/tb_fp32 +PRE=$(BUILD)/fp32 +COUNT=200000

# Version 4 engine at every size (fewer jobs at 16x16, which is slow to simulate)
V4_SCENARIOS := same mixed stress
test-v4:
	@mkdir -p $(BUILD)/v4
	@for n in $(SIZES); do \
	  jobs=60; [ $$n -ge 16 ] && jobs=15; \
	  python3 tools/gen_v4_vectors.py $$n $(BUILD)/v4 $$jobs || exit 1; \
	  iverilog -g2012 -DGRID_N=$$n -o $(BUILD)/v4/tb_v4_$$n \
	    rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v4.v rtl/systolic_v4.v tests/tb_systolic_v4.v || exit 1; \
	  for s in $(V4_SCENARIOS); do \
	    vvp -n $(BUILD)/v4/tb_v4_$$n +PRE=$(BUILD)/v4/v4_N$${n}_$$s > $(BUILD)/v4/log_$${n}_$$s.txt; \
	    grep -E "errors|ticks" $(BUILD)/v4/log_$${n}_$$s.txt; \
	    grep -q '^PASS' $(BUILD)/v4/log_$${n}_$$s.txt || exit 1; \
	  done; \
	done

# Version 5 engine (shared, two-tick FP32 adders): same answers as version 4.
# Blocks must have at least min(G, N) beats, so vectors are made with 16.
test-v5:
	@mkdir -p $(BUILD)/v5
	@for n in $(SIZES); do \
	  jobs=60; [ $$n -ge 16 ] && jobs=15; \
	  python3 tools/gen_v4_vectors.py $$n $(BUILD)/v5 $$jobs 16 || exit 1; \
	  iverilog -g2012 -DGRID_N=$$n -DV5 -DGROUP=16 -o $(BUILD)/v5/tb_v5_$$n \
	    rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v tests/tb_systolic_v4.v || exit 1; \
	  for s in $(V4_SCENARIOS); do \
	    vvp -n $(BUILD)/v5/tb_v5_$$n +PRE=$(BUILD)/v5/v4_N$${n}_$$s > $(BUILD)/v5/log_$${n}_$$s.txt; \
	    grep -E "errors|ticks" $(BUILD)/v5/log_$${n}_$$s.txt; \
	    grep -q '^PASS' $(BUILD)/v5/log_$${n}_$$s.txt || exit 1; \
	  done; \
	done

# Tiling controller + version 5 engine: whole matrix multiplies (10 shapes/formats)
test-tile:
	tests/run_tile_tests.sh

# Phase 2 tile: SRAM halves, data mover, main-memory model (delay, bandwidth)
test-tile-v1:
	tests/run_tile_v1_tests.sh

# Formal proof of the engine's output rules (needs the Yices solver,
# installed by: pip install -r tools/requirements.txt)
FORMAL_SIZES := 2 4 8
formal:
	@for n in $(FORMAL_SIZES); do formal/run.sh $$n v3 || exit 1; formal/run.sh $$n v4 || exit 1; done
	@formal/run.sh 4 v5 2 && formal/run.sh 4 v5 4 && formal/run.sh 8 v5 4 && formal/run.sh 8 v5 8
	@formal/run.sh 4 mm 4 && formal/run.sh 8 mm 8 && formal/run.sh 16 mm 16

# Plant bugs on purpose and check the tests catch every one
mutants:
	formal/mutants.sh

# Early performance model: check it against the simulated engine, then run it
perf:
	python3 tools/perf_model.py --validate
	python3 tools/perf_model.py > /dev/null
	@echo "written: results/perf_model.md"

synth:
	@mkdir -p $(BUILD)
	@yosys -q -p "read_verilog rtl/mac.v; synth -top mac; tee -q -o $(BUILD)/mac_stat.txt stat"
	@grep -E "Number of cells" $(BUILD)/mac_stat.txt | tail -1 | sed 's/^/mac: /'
	@for n in $(SIZES); do \
	  yosys -q -p "read_verilog rtl/pe.v rtl/systolic_array.v; chparam -set N $$n systolic_array; synth -top systolic_array; tee -q -o $(BUILD)/systolic_$${n}_stat.txt stat"; \
	  grep -E "Number of cells" $(BUILD)/systolic_$${n}_stat.txt | tail -1 | sed "s/^/systolic $${n}x$${n}: /"; \
	  yosys -q -p "read_verilog rtl/pe_stream.v rtl/systolic_stream.v; chparam -set N $$n systolic_stream; synth -top systolic_stream; tee -q -o $(BUILD)/stream_$${n}_stat.txt stat"; \
	  grep -E "Number of cells" $(BUILD)/stream_$${n}_stat.txt | tail -1 | sed "s/^/stream $${n}x$${n}: /"; \
	done

clean:
	rm -rf ./build
