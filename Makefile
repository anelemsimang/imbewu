# Imbewu - run all free simulation tests with:  make test
# Gate count (how big the circuit is):           make synth
BUILD := build

.PHONY: test test-mac test-matmul4 synth clean

test: test-mac test-matmul4

test-mac:
	@mkdir -p $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_mac rtl/mac.v tests/tb_mac.v
	vvp -n $(BUILD)/tb_mac

test-matmul4:
	@mkdir -p $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_matmul4 rtl/pe.v rtl/matmul4.v tests/tb_matmul4.v
	vvp -n $(BUILD)/tb_matmul4

synth:
	@mkdir -p $(BUILD)
	yosys -q -p "read_verilog rtl/mac.v; synth -top mac; tee -o $(BUILD)/mac_stat.txt stat"
	yosys -q -p "read_verilog rtl/pe.v rtl/matmul4.v; synth -top matmul4; tee -o $(BUILD)/matmul4_stat.txt stat"
	@grep -E "Number of cells" $(BUILD)/mac_stat.txt | tail -1 | sed 's/^/mac:     /'
	@grep -E "Number of cells" $(BUILD)/matmul4_stat.txt | tail -1 | sed 's/^/matmul4: /'

clean:
	rm -rf $(BUILD)
