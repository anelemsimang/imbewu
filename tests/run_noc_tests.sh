#!/bin/bash
# On-chip network tests (rtl/noc_router.v, rtl/noc_mesh.v): random traffic on
# several grid sizes and patterns, every flit checked (tests/tb_noc.v).
# NOC=<file> replaces the router (used by formal/mutants.sh).
OUT=${OUT:-build/noc}; mkdir -p $OUT
R=${NOC:-rtl/noc_router.v}
fail=0
for g in "4 4" "8 8" "3 5"; do
  set -- $g
  iverilog -g2012 -DMX=$1 -DMY=$2 -o $OUT/tb_$1x$2 $R rtl/noc_mesh.v tests/tb_noc.v || exit 1
  for pat in 0 1 2; do
    [ $pat = 1 ] && [ $1 != $2 ] && continue
    for rate in 10 35; do
      log=$(vvp -n $OUT/tb_$1x$2 +PAT=$pat +RATE=$rate +SEED=$((rate + pat)) +CYC=1500)
      echo "$log" | grep '^NOC'
      echo "$log" | grep -q '^PASS' || { echo "$log" | grep ERROR | head -3; fail=1; }
    done
  done
done
[ $fail = 0 ] && echo PASS || { echo FAIL; exit 1; }
