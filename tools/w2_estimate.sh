#!/bin/sh
# First physical estimate (W2): map a design onto a real standard-cell library
# and report its area (um^2) and its longest logic path (ps), which sets the
# highest clock speed. Uses Yosys + ABC only (no placement or wiring yet).
# Usage: tools/w2_estimate.sh LIB TOP "VERILOG FILES" [PARAMS] [LABEL]
#   LIB: path to a Liberty (.lib) cell library
set -e
LIB=$1; TOP=$2; SRC=$3; PARAMS=$4; LABEL=${5:-$TOP}
OUT=build/w2; mkdir -p $OUT
LOG=$OUT/${LABEL}_$(basename $LIB .lib).log
yosys -p "read_verilog $SRC; ${PARAMS:+chparam $PARAMS $TOP;} synth -top $TOP -flatten -run :fine; techmap -autoproc -map tools/w2_kogge_stone.v -map +/techmap.v; synth -top $TOP -flatten -run fine:; \
  dfflibmap -liberty $LIB; abc -liberty $LIB -script tools/w2_abc.script; opt_clean; \
  tee -o $OUT/${LABEL}_stat.txt stat -liberty $LIB" > $LOG 2>&1
AREA=$(grep "Chip area" $OUT/${LABEL}_stat.txt | tail -1 | awk '{print $NF}')
DELAY=$(grep -o "Delay = *[0-9.]* ps" $LOG | awk '{print $3}' | sort -n | tail -1)
echo "$LABEL on $(basename $LIB .lib): area $AREA um^2, longest logic path $DELAY ps"
