#!/bin/sh
# Stress test of the cluster's memory arbiter and broadcast (mem_share),
# with random requesters: several sizes, channel counts and memory delays.
set -e
OUT=${OUT:-build/memshare}; CL=${CLUSTER:-rtl/cluster.v}; mkdir -p $OUT
for cfg in "2 1 1" "4 1 1" "4 2 1" "4 4 1" "8 2 1" "8 8 1" "4 1 0" "8 2 0"; do
  set -- $cfg; T=$1; B=$2; BC=$3
  sim=$OUT/tb_${T}_${B}_${BC}
  [ -f $sim ] || iverilog -g2012 -DTILES=$T -DCHANNELS=$B -DBCAST=$BC -s tb_mem_share -o $sim $CL tests/tb_mem_share.v
  for lat in 1 6 40; do
    for seed in 1 2; do
      log=$(vvp -n $sim +LAT=$lat +SEED=$seed +NREQ=1500)
      echo "$log" | grep -q '^PASS' || { echo "$log" | grep -vE '^(VCD|tests/)'; echo "FAIL: T=$T B=$B BC=$BC lat=$lat seed=$seed"; exit 1; }
    done
    echo "$log" | grep '^MEMSHARE'
  done
done
echo "mem_share: all PASS"
