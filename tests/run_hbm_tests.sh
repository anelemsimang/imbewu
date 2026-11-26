#!/bin/bash
# HBM pseudo-channel controller (rtl/hbm_ctrl.v) against a DRAM model that
# checks every timing rule (tests/tb_hbm.v), four traffic patterns, two seeds.
# HBM=<file> replaces the controller (used by formal/mutants.sh).
OUT=${OUT:-build/hbm}; mkdir -p $OUT
iverilog -g2012 -o $OUT/tb ${HBM:-rtl/hbm_ctrl.v} tests/hbm_dram_model.v tests/tb_hbm.v || exit 1
fail=0
for pat in 0 1 2 3; do
  for seed in 1 2; do
    log=$(vvp -n $OUT/tb +PAT=$pat +SEED=$seed +NREQ=4000)
    [ $seed = 1 ] && echo "$log" | grep '^HBM'
    echo "$log" | grep -q '^PASS' || { echo "$log" | grep ERROR | head -3; fail=1; }
  done
done
[ $fail = 0 ] && echo PASS || { echo FAIL; exit 1; }
