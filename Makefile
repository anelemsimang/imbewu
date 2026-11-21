# Imbewu - run all free simulation tests with:  make test
# Size of each circuit in logic cells:           make synth
BUILD  := build
SIZES  := 4 8 16
TRIALS := 1000

.PHONY: test test-mac test-systolic synth clean

test: test-mac test-systolic

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

synth:
	@mkdir -p $(BUILD)
	@yosys -q -p "read_verilog rtl/mac.v; synth -top mac; tee -q -o $(BUILD)/mac_stat.txt stat"
	@grep -E "Number of cells" $(BUILD)/mac_stat.txt | tail -1 | sed 's/^/mac: /'
	@for n in $(SIZES); do \
	  yosys -q -p "read_verilog rtl/pe.v rtl/systolic_array.v; chparam -set N $$n systolic_array; synth -top systolic_array; tee -q -o $(BUILD)/systolic_$${n}_stat.txt stat"; \
	  grep -E "Number of cells" $(BUILD)/systolic_$${n}_stat.txt | tail -1 | sed "s/^/systolic $${n}x$${n}: /"; \
	done

clean:
	rm -rf ./build
