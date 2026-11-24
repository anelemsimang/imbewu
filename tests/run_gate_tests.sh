#!/bin/sh
# Gate-level simulation: the designs are first turned into logic gates by
# Yosys (as a chip flow would), then the SAME tests are run on those gates
# (Yosys's gate models, simcells.v). Catches differences between what we
# wrote and what the tools built. 4-lane converter and 4x4 engine with its
# tiling controller; FULL=1 adds the arbiter, the vector unit and the whole
# tile, with their memories kept as memory blocks (as a chip uses the
# foundry's), which takes about an hour.
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
[ "$FULL" = 1 ] || { echo "gate level: all PASS (FULL=1 adds the arbiter, the vector unit and the tile)"; exit 0; }
# 3. memory arbiter + broadcast (4 requesters, 2 channels, 16-entry list of
#    reads in flight; Yosys's memory-sharing step is skipped: it only
#    optimises, and runs out of memory on this design)
yosys -q -p "read_verilog rtl/cluster.v; hierarchy -top mem_share -chparam N 4 -chparam T 4 -chparam B 2 -chparam EAW 12 -chparam BC 1 -chparam DW 4; proc; flatten; opt_expr; opt_clean; memory_dff; memory_collect; memory_map; opt; techmap; opt; abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX; opt_clean; write_verilog -noattr $OUT/mem_share_gl.v"
iverilog -g2012 -DTILES=4 -DCHANNELS=2 -DBCAST=1 -DGATE -s tb_mem_share -o $OUT/tb_ms $OUT/mem_share_gl.v $CELLS tests/tb_mem_share.v
for lat in 1 6 40; do for seed in 1 2; do
  log=$(vvp -n $OUT/tb_ms +LAT=$lat +SEED=$seed +NREQ=1500)
  echo "[gates] $(echo "$log" | grep '^MEMSHARE')"
  echo "$log" | grep -q '^PASS' || { echo "FAIL: gate-level arbiter"; exit 1; }
done; done
# 4. vector unit version 2, 4 lanes (its memories kept as memory blocks)
SIMLIB=$(dirname $CELLS)/simlib.v
yosys -q -p "read_verilog -Irtl rtl/fp32_add_fx.v rtl/fp32_ops.v rtl/vu_v2.v; hierarchy -top vu_v2 -chparam L 4; proc; flatten; opt; memory -nomap; opt; techmap; opt; abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX; opt_clean; write_verilog -noattr $OUT/vu_v2_gl.v"
iverilog -g2012 -DLANES=4 -DVU_V2 -DGATE -o $OUT/tb_vu2 $OUT/vu_v2_gl.v $SIMLIB $CELLS tests/tb_vu.v
log=$(IMBEWU_LANES=4 IMBEWU_SIM=$OUT/tb_vu2 python3 tests/run_vu2_special.py 10) || { echo "$log"; echo "FAIL: gate-level vector unit"; exit 1; }
echo "[gates] $log"
# 5. the whole tile (version 4), 4x4, memories kept as memory blocks
yosys -q -p "read_verilog -Irtl rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v rtl/matmul_unit.v rtl/sram.v rtl/fp32_ops.v rtl/vu_v2.v rtl/mx_quant.v rtl/tile_v4.v; hierarchy -top tile_v4 -chparam N 4; proc; flatten; opt_expr; opt_clean; memory_dff; memory_collect; opt; techmap; opt; abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX; opt_clean; write_verilog -noattr $OUT/tile_v4_gl.v" 2>/dev/null
iverilog -g2012 -DGRID_N=4 -DGATE -o $OUT/tb_t4 $OUT/tile_v4_gl.v $SIMLIB $CELLS tests/tb_tile_v4.v
for x in "silu mxint8 2 1" "softmax mxfp8 2 1" "rmsnorm mxfp4 1 3"; do
  set -- $x; pre=$OUT/t4_$1_$2_v$3
  python3 tools/gen_tile_v4_vectors.py 4 $1 $2 $pre 3 $3 > /dev/null
  log=$(vvp -n $OUT/tb_t4 +PRE=$pre +LAT=20 +EVERY=$4)
  echo "[gates, $1 v$3 -> $2] $(echo "$log" | grep '^TILE_V4' | head -1)"
  echo "$log" | grep -q '^PASS' || { echo "FAIL: gate-level tile $pre"; exit 1; }
done
echo "gate level (full): all PASS"
