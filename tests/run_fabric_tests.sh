#!/bin/bash
# The memory system end to end (tests/tb_fabric.v): 11 tiles, request and
# answer meshes, 8 HBM channels with timing-checking DRAM models, 5 on-chip
# memory blocks; five traffic patterns, every answer checked.
# MC= / SR= replace rtl/mc_node.v / rtl/sram_node.v (used by formal/mutants.sh).
OUT=${OUT:-build/fabric}; mkdir -p $OUT
iverilog -g2012 -o $OUT/tb rtl/noc_router.v rtl/noc_mesh.v rtl/hbm_ctrl.v ${MC:-rtl/mc_node.v} \
  ${SR:-rtl/sram_node.v} tests/hbm_dram_model.v tests/tb_fabric.v 2> $OUT/build.log || { cat $OUT/build.log; exit 1; }
fail=0
for pat in 0 1 2 3 4; do
  log=$(vvp -n $OUT/tb +PAT=$pat +NREQ=300 +SEED=$((pat + 1)))
  echo "$log" | grep '^FABRIC'
  echo "$log" | grep -q '^PASS' || { echo "$log" | grep ERROR | head -3; fail=1; }
done
[ $fail = 0 ] && echo PASS || { echo FAIL; exit 1; }
