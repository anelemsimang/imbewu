#!/bin/sh
# Tile (Phase 2) tests: lists of matrix multiplies through SRAM halves, the
# data mover and a main-memory model with delay and limited bandwidth.
set -e
OUT=${OUT:-build/tilev1}; TILE=${TILE:-rtl/tile_v1.v}; mkdir -p $OUT
run() {   # N SHAPE SEED LAT EVERY
  pre=$OUT/v_$1_$2_$3
  [ -f ${pre}_meta.hex ] || python3 tools/gen_tile_v1_vectors.py $1 6 $pre $3 $2 > /dev/null
  [ -f $OUT/tb_$1 ] || iverilog -g2012 -DGRID_N=$1 -o $OUT/tb_$1 rtl/mx_mul.v rtl/fp32_add_fx.v \
      rtl/pe_v5.v rtl/systolic_v5.v rtl/matmul_unit.v rtl/sram.v $TILE tests/tb_tile_v1.v
  log=$(vvp -n $OUT/tb_$1 +PRE=$pre +LAT=$4 +EVERY=$5)
  echo "$log" | grep -E "^TILE" | sed "s/^/[$2] /"
  echo "$log" | grep -q '^PASS' || { echo "FAIL: $pre"; exit 1; }
}
run 4 mixed 7 20 1
run 4 mixed 8 60 3
run 4 reuse 7 40 1
run 4 reuse 7 40 2
run 8 mixed 11 30 1
run 16 reuse 12 30 1
echo "tile: all PASS"
