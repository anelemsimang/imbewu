#!/bin/sh
# Formal proof of the engine's output rules (see formal/fv_*.v).
# Usage: formal/run.sh N [v3|v4|v5|mm|noc] [G]   (noc: N = queue depth)   (default v3; G = cells per shared adder, v5)
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
V=${2:-v3}
G=${3:-2}
PARAMS="chparam -set N $N"
if [ "$V" = noc ]; then
  TOP=fv_noc_router
  SRC="${SYS:-rtl/noc_router.v}"
  PARAMS="chparam -set D $N"
  K=6; BASE=12
elif [ "$V" = mm ]; then
  TOP=fv_matmul_unit
  SRC="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v ${SYS:-rtl/matmul_unit.v}"
  PARAMS="chparam -set N $N -set G $G"
  K=8; BASE=8
elif [ "$V" = v5 ]; then
  TOP=fv_systolic_v5
  SRC="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v ${SYS:-rtl/systolic_v5.v}"
  PARAMS="chparam -set N $N -set G $G"
  K=${K5:-$((2 * N + G + 7))}   # deeper induction: the shared-adder rule spans a block
  BASE=$((2 * N + 10))
elif [ "$V" = v4 ]; then
  TOP=fv_systolic_v4
  SRC="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v4.v ${SYS:-rtl/systolic_v4.v}"
else
  TOP=fv_systolic_mx
  SRC="${PE:-rtl/pe_mx.v} ${SYS:-rtl/systolic_mx.v}"
fi
OUT=build/formal
mkdir -p $OUT
M=$OUT/${V}_${N}_$G${SYS:+_m$$}.smt2   # planted-bug runs get their own file
yosys -q -p "read_verilog -formal $SRC formal/$TOP.v; \
  $PARAMS $TOP; prep -flatten -top $TOP; opt_clean -purge; \
  memory_map; opt -fast; async2sync; dffunmap; write_smt2 $M" 2>/dev/null
status() { tail -1 | sed 's/.*Status: //'; }
B=$(yosys-smtbmc -s yices -t $BASE $M | status)
I=$(yosys-smtbmc -s yices -i -t $K $M | status)
CD=$((4 * N + 8)); [ "$V" = v5 ] && CD=$((4 * N + 10)); [ "$V" = mm ] && CD=$((4 * N + 40))
C=$(yosys-smtbmc -s yices -c -t $CD $M | status)
[ "$V" = v5 ] && V="v5 (G=$G)"
[ "$V" = mm ] && V="tiling controller (G=$G)"
[ "$V" = noc ] && V="network router (queue depth $N)"
case "$V" in
  network*) echo "formal $V: base case $B, induction step $I, two outputs busy at once reachable $C" ;;
  *) echo "formal $V ${N}x${N}: base case $B, induction step $I, back-to-back jobs reachable $C" ;;
esac
[ "$B" = PASSED ] && [ "$I" = PASSED ] && [ "$C" = PASSED ]
