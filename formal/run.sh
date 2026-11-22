#!/bin/sh
# Formal proof of the multi-format engine's control rules (R1-R3 in
# fv_systolic_mx.v). Usage: formal/run.sh N
# Needs: yosys, yosys-smtbmc (come with Yosys) and the Yices solver
#        (pip install yices-solver).
#
# A complete proof by induction has two halves:
#   base case : the rules hold for the first BASE ticks after reset, for every input
#   step      : if they held for any K ticks in a row, they hold on the next one
# Together they mean the rules hold forever.
set -e
N=${1:-2}
K=4                       # induction depth
BASE=$((2 * N + 4))       # base case depth: long enough for a whole job to come out
OUT=build/formal
mkdir -p $OUT
yosys -q -p "read_verilog -formal ${PE:-rtl/pe_mx.v} ${SYS:-rtl/systolic_mx.v} formal/fv_systolic_mx.v; \
  chparam -set N $N fv_systolic_mx; prep -flatten -top fv_systolic_mx; opt_clean -purge; \
  memory_map; opt -fast; async2sync; dffunmap; write_smt2 $OUT/fv_$N.smt2" 2>/dev/null
status() { tail -1 | sed 's/.*Status: //'; }
B=$(yosys-smtbmc -s yices -t $BASE $OUT/fv_$N.smt2 | status)
I=$(yosys-smtbmc -s yices -i -t $K $OUT/fv_$N.smt2 | status)
C=$(yosys-smtbmc -s yices -c -t $((4 * N + 4)) $OUT/fv_$N.smt2 | status)
echo "formal ${N}x${N}: base case $B, induction step $I, back-to-back jobs reachable $C"
[ "$B" = PASSED ] && [ "$I" = PASSED ] && [ "$C" = PASSED ]
