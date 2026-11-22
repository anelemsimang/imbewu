#!/bin/sh
# Tile version 2 tests: weights kept in the tile across commands.
set -e
OUT=${OUT:-build/tilev2}; TILE=${TILE:-rtl/tile_v2.v}; mkdir -p $OUT
run() {   # N GROUPS PER SEED RELOAD SHAPE LAT EVERY [SLOTS]
  pre=$OUT/v_$1_$2x$3_$4_$5_$6_${9:-alt}
  [ -f ${pre}_meta.hex ] || python3 tools/gen_tile_v2_vectors.py $1 $2 $3 $pre $4 $5 $6 ${9:-alt} > /dev/null
  [ -f $OUT/tb_$1 ] || iverilog -g2012 -DGRID_N=$1 -DTILE_V2 -o $OUT/tb_$1 rtl/mx_mul.v rtl/fp32_add_fx.v \
      rtl/pe_v5.v rtl/systolic_v5.v rtl/matmul_unit.v rtl/sram.v $TILE tests/tb_tile_v1.v
  log=$(vvp -n $OUT/tb_$1 +PRE=$pre +LAT=$7 +EVERY=$8)
  tag="$6, slots ${9:-alt}, weights $( [ $5 = 1 ] && echo 'fetched every command' || echo 'kept' )"
  echo "$log" | grep -E "^TILE" | sed "s/^/[$tag] /"
  echo "$log" | grep -q '^PASS' || { echo "FAIL: $pre"; exit 1; }
}
run 4 3 5 3 1 decode 40 1
run 4 3 5 3 0 decode 40 1
run 4 3 5 3 1 decode 40 2
run 4 3 5 3 0 decode 40 2
run 4 4 4 5 0 mixed 30 1
run 8 3 4 6 0 mixed 30 1
run 16 2 4 7 0 decode 30 1
run 4 5 2 8 0 decode 40 1 one
run 4 4 3 9 0 mixed 20 3 one
echo "tile v2: all PASS"
