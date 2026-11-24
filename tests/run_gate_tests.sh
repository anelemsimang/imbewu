#!/bin/sh
# Gate-level simulation: the designs are first turned into logic gates by
# Yosys (as a chip flow would), then the SAME tests are run on those gates
# (Yosys's gate models, simcells.v). Catches differences between what we
# wrote and what the tools built. 4-lane converter and 4x4 engine with its
# tiling controller (the full tile is mostly memory, which a real chip
# builds from the foundry's memory blocks, not gates).
set -e
OUT=build/gl; mkdir -p $OUT
CELLS=$(yosys-config --datdir 2>/dev/null || echo /usr/share/yosys)/simcells.v
# 1. FP32 -> MX converter
yosys -q -p "read_verilog rtl/mx_quant.v; chparam -set N 4 mx_quant; synth -flatten -top mx_quant; opt_clean; write_verilog -noattr $OUT/mx_quant_gl.v"
iverilog -g2012 -DLANES=4 -DGATE -o $OUT/tb_mxq $OUT/mx_quant_gl.v $CELLS tests/tb_mx_quant.v
for seed in 1 2; do
  pre=$OUT/mxq_s$seed
  [ -f ${pre}_exp.hex ] || python3 tools/gen_mx_quant_vectors.py 4 6000 $pre $seed > /dev/null
  for gaps in 0 1; do
    log=$(vvp -n $OUT/tb_mxq +PRE=$pre +BLOCKS=6000 +GAPS=$gaps)
    echo "[gates] $(echo "$log" | grep '^MX_QUANT')"
    echo "$log" | grep -q '^PASS' || { echo "FAIL: gate-level converter"; exit 1; }
  done
done
# 2. engine + tiling controller, 4x4
yosys -q -p "read_verilog rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v rtl/matmul_unit.v; chparam -set N 4 matmul_unit; synth -flatten -top matmul_unit; opt_clean; write_verilog -noattr $OUT/matmul_gl.v" 2>/dev/null
iverilog -g2012 -DGRID_N=4 -DGATE -o $OUT/tb_mm $OUT/matmul_gl.v $CELLS tests/tb_matmul_unit.v
while read N MT NT KB FA FB; do
  [ -z "$N" ] && continue
  pre=$OUT/t_${N}_${MT}x${NT}_k${KB}_${FA}${FB}
  python3 tools/gen_tile_vectors.py $N $MT $NT $KB $FA $FB $pre > /dev/null
  log=$(vvp -n $OUT/tb_mm +PRE=$pre)
  echo "[gates, fmt $FA x $FB] $(echo "$log" | grep -E '^MATMUL' | head -1)"
  echo "$log" | grep -q '^PASS' || { echo "FAIL: gate-level engine $pre"; exit 1; }
done <<LIST
4 3 2 2 1 1
4 4 4 4 0 0
4 2 3 3 2 2
4 3 3 2 1 2
4 2 2 1 0 2
LIST
echo "gate level: all PASS"
