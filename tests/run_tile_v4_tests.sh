#!/bin/sh
# tile_v4: three layers chained on one tile (vector-unit program, MX
# rounding, transpose, dependent commands). Every intermediate and final
# word checked. All three programs x all three middle formats, 4x4 and 8x8.
set -e
OUT=${OUT:-build/t4}; T4=${TILE4:-rtl/tile_v4.v}; mkdir -p $OUT
RTL="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v rtl/matmul_unit.v rtl/sram.v rtl/fp32_ops.v rtl/vu_v1.v rtl/mx_quant.v $T4 tests/tb_tile_v4.v"
for N in 4 8; do
  iverilog -g2012 -DGRID_N=$N -o $OUT/tb$N $RTL
  for prog in silu softmax rmsnorm; do
    for f in mxint8 mxfp8 mxfp4; do
      pre=$OUT/n${N}_${prog}_$f
      [ -f ${pre}_meta.hex ] || python3 tools/gen_tile_v4_vectors.py $N $prog $f $pre > /dev/null
      every=1; [ $f = mxfp4 ] && every=3          # one run per program with slow memory
      log=$(vvp -n $OUT/tb$N +PRE=$pre +LAT=20 +EVERY=$every)
      echo "[$N $prog -> $f, 1 request per $every ticks] $(echo "$log" | grep -E '^TILE_V4' | head -1 | sed 's/^TILE_V4 //')"
      echo "$log" | grep -q '^PASS' || { echo "$log" | grep -E 'MISMATCH|TIMEOUT|TILE_V4'; echo "FAIL: N=$N $prog $f"; exit 1; }
    done
  done
  echo "$log" | grep '^TILE_V4' | tail -1
done
echo "tile v4: all PASS"
