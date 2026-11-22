#!/bin/sh
# Tiling controller tests: several engine sizes, matrix shapes and formats.
# Each line: N MT NT KBLOCKS FA FB  (formats 0 INT8, 1 FP8, 2 FP4)
set -e
OUT=${OUT:-build/tile}; MM=${MM:-rtl/matmul_unit.v}; mkdir -p $OUT
while read N MT NT KB FA FB; do
  [ -z "$N" ] && continue
  pre=$OUT/t_${N}_${MT}x${NT}_k${KB}_${FA}${FB}
  python3 tools/gen_tile_vectors.py $N $MT $NT $KB $FA $FB $pre > /dev/null
  [ -f $OUT/tb_$N ] || iverilog -g2012 -DGRID_N=$N -o $OUT/tb_$N rtl/mx_mul.v rtl/fp32_add_fx.v \
      rtl/pe_v5.v rtl/systolic_v5.v $MM tests/tb_matmul_unit.v
  log=$(vvp -n $OUT/tb_$N +PRE=$pre)
  echo "$log" | grep -E "^MATMUL" | sed "s/^/[fmt $FA x $FB] /"
  echo "$log" | grep -q '^PASS' || { echo "FAIL: $pre"; exit 1; }
done <<LIST
4 3 2 2 1 1
4 4 4 4 0 0
4 2 3 3 2 2
4 3 3 2 1 2
4 2 2 1 0 2
8 3 2 4 1 1
8 2 2 3 2 2
8 2 3 2 1 2
16 2 2 4 1 2
16 2 1 2 2 2
LIST
echo "tiling controller: all PASS"
