#!/bin/sh
# Multi-tile tests: one layer shared out among 1, 2 or 4 tiles, with one
# memory channel for all, or one per tile. Every answer must be bit exact.
# Usage: tests/run_cluster_tests.sh [N G P KBLOCKS]   (default 4 8 2 8)
set -e
OUT=${OUT:-build/cluster}; CL=${CLUSTER:-rtl/cluster.v}; mkdir -p $OUT
N=${1:-4}; G=${2:-8}; P=${3:-2}; KB=${4:-8}
RTL="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v rtl/matmul_unit.v rtl/sram.v rtl/tile_v3.v $CL tests/tb_cluster.v"
for T in 1 2 4; do
  pre=$OUT/l_${N}_${G}x${P}_k${KB}_t$T
  [ -f ${pre}_meta.hex ] || python3 tools/gen_cluster_vectors.py $N $T $G $P $KB $pre > /dev/null
  for B in 1 $T; do
    [ $T = 1 ] && [ $B = 1 ] && [ -n "$done1" ] && continue
    done1=1
    sim=$OUT/tb_${N}_${T}_${B}
    [ -f $sim ] || iverilog -g2012 -DGRID_N=$N -DTILES=$T -DCHANNELS=$B -o $sim $RTL
    log=$(vvp -n $sim +PRE=$pre +LAT=40)
    echo "$log" | grep -E "^CLUSTER" | tail -1
    echo "$log" | grep -q '^PASS' || { echo "$log" | grep -E "CLUSTER|MISMATCH|TIMEOUT"; echo "FAIL: T=$T B=$B"; exit 1; }
  done
done
echo "cluster: all PASS"
