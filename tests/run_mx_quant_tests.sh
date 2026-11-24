#!/bin/sh
# FP32 -> MX block converter (rtl/mx_quant.v) against the compiler's rounding:
# 4, 8 and 16 lanes, blocks back to back and with random gaps.
set -e
OUT=${OUT:-build/mxq}; SRC=${MXQ:-rtl/mx_quant.v}; mkdir -p $OUT
for N in 4 8 16; do
  for seed in 1 2 3; do
    pre=$OUT/n${N}_s$seed
    [ -f ${pre}_exp.hex ] || python3 tools/gen_mx_quant_vectors.py $N 6000 $pre $seed > /dev/null
  done
  iverilog -g2012 -DLANES=$N -o $OUT/tb$N $SRC tests/tb_mx_quant.v
  for seed in 1 2 3; do
    for gaps in 0 1; do
      log=$(vvp -n $OUT/tb$N +PRE=$OUT/n${N}_s$seed +BLOCKS=6000 +GAPS=$gaps)
      echo "$log" | grep -q '^PASS' || { echo "$log" | grep -vE '^tests/'; echo "FAIL: N=$N seed=$seed gaps=$gaps"; exit 1; }
    done
  done
  echo "$log" | grep '^MX_QUANT'
done
echo "mx_quant: all PASS"
