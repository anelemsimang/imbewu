#!/bin/sh
# tile_v4: three layers chained on one tile (vector-unit program, MX
# rounding, transpose, dependent commands). Every intermediate and final
# word checked. Vector unit version 2: its new programs with all three
# middle formats, and the version 1 programs (must still work), on 4x4;
# then the new programs on 8x8.
set -e
OUT=${OUT:-build/t4}; T4=${TILE4:-rtl/tile_v4.v}; mkdir -p $OUT
RTL="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v rtl/matmul_unit.v rtl/sram.v rtl/fp32_ops.v rtl/vu_v2.v rtl/mx_quant.v $T4 tests/tb_tile_v4.v"
run() {   # N program format version
  pre=$OUT/n$1_$2_$3_v$4
  [ -f ${pre}_meta.hex ] || python3 tools/gen_tile_v4_vectors.py $1 $2 $3 $pre 3 $4 > /dev/null
  every=1; [ $3 = mxfp4 ] && every=3              # slow memory in some runs
  log=$(vvp -n $OUT/tb$1 +PRE=$pre +LAT=20 +EVERY=$every)
  echo "[$1 $2 v$4 -> $3, 1 request per $every ticks] $(echo "$log" | grep -E '^TILE_V4' | sed 's/^TILE_V4 //' | tr '\n' ' ')"
  echo "$log" | grep -q '^PASS' || { echo "$log" | grep -E 'MISMATCH|TIMEOUT'; echo "FAIL: N=$1 $2 $3 v$4"; exit 1; }
}
for N in 4 8; do iverilog -g2012 -I rtl -DGRID_N=$N -o $OUT/tb$N $RTL; done
for prog in silu softmax rmsnorm; do
  for f in mxint8 mxfp8 mxfp4; do run 4 $prog $f 2; done
  run 4 $prog mxfp8 1
  run 8 $prog mxint8 2
done
echo "tile v4: all PASS"
