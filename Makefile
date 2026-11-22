# Imbewu - run all free simulation tests with:  make test
# Size of each circuit in logic cells:           make synth
BUILD  := build
SIZES  := 4 8 16
TRIALS := 1000

.PHONY: test test-mac test-systolic test-stream test-mx test-cell formal mutants synth clean

test: test-mac test-systolic test-stream test-mx test-cell

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

# Formal proof of the engine's output rules (needs the Yices solver,
# installed by: pip install -r tools/requirements.txt)
FORMAL_SIZES := 2 4 8
formal:
	@for n in $(FORMAL_SIZES); do formal/run.sh $$n || exit 1; done

# Plant bugs on purpose and check the tests catch every one
mutants: test-cell
	formal/mutants.sh

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
