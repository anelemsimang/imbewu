#!/bin/bash
# Layout of the whole 32x32 engine (D-031, W2 step 3): systolic_v5 with
# DRAIN = 1 built from 64 copies of the finished block v5_blk (laid out by
# tools/w2_layout.sh with TOP=v5_blk, made reusable by tools/w2_abstract.sh),
# plus the engine's own small logic (input delay lines, read-out timing),
# placed and wired with OpenROAD on ASAP7.
# Usage: [STAGE=place|route|all] tools/w2_engine.sh BLOCK_LABEL [N] [PERIOD] [LABEL]
#   BLOCK_LABEL: the block's layout folder in build/layout (e.g. blk16_asap7_p075)
set -e
STAGE=${STAGE:-all}
export PDK=asap7
BLK=$1; N=${2:-32}; PERIOD=${3:-0.75}; LABEL=${4:-eng${N}_asap7_p${PERIOD/./}}
OPENROAD=${OPENROAD:-/opt/eda/bin/openroad}
P=build/pdk/$PDK
OUT=build/layout/$LABEL; mkdir -p $OUT
export MACROS=build/layout/$BLK
# The blocks fill M1-M7 with their own wiring; without M8/M9 the engine's
# clock wires crowd through the 2-3 um gaps and reach the blocks 2.5-5.7 ns
# late instead of about 0.8 ns
export W2_SIG_LAYERS=M2-M9 W2_CLK_LAYERS=M4-M9
for f in abstract.lef model_TT.lib model_SS.lib model_FF.lib; do
  [ -s $MACROS/$f ] || { echo "missing $MACROS/$f: run tools/w2_abstract.sh $BLK"; exit 1; }
done
# Simplified block outlines (inside of M1-M7 one solid shape, edges exact):
# with the full outlines detailed routing needs more than 15 GB.
# SIMPLE_LEF=0 uses the full ones.
if [ "${SIMPLE_LEF:-1}" = 1 ]; then
  python3 tools/w2_simple_lef.py $MACROS/abstract.lef $MACROS/abstract_simple.lef
  export MACRO_LEF=abstract_simple.lef
fi
LIB=$P/lib/merged_TT.lib; SLIB=$P/lib/synth_TT.lib
TIE="-hicell TIEHIx1_ASAP7_75t_R H -locell TIELOx1_ASAP7_75t_R L"; BUF="BUFx2_ASAP7_75t_R A Y"

if [ $STAGE != route ]; then
# 1. Synthesis of the engine with the blocks kept as parts (black boxes)
RTL="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v"
yosys -p "read_verilog $RTL; chparam -set N $N -set G 16 -set DRAIN 1 systolic_v5; \
  hierarchy -top systolic_v5; rename -top systolic_v5; blackbox \$paramod*v5_blk*; \
  synth -top systolic_v5 -flatten -run :fine; techmap -autoproc -map tools/w2_kogge_stone.v -map +/techmap.v; \
  synth -top systolic_v5 -flatten -run fine:; \
  dfflibmap -liberty $SLIB; abc -liberty $SLIB -script tools/w2_abc.script; \
  setundef -zero; splitnets; opt_clean -purge; hilomap -singleton $TIE; \
  insbuf -buf $BUF; opt_clean; \
  tee -o $OUT/synth_stat.txt stat -liberty $LIB; \
  write_verilog -noattr -noexpr -nohex -nodec $OUT/synth_raw.v" > $OUT/synth.log 2>&1 \
  || { tail -20 $OUT/synth.log; exit 1; }
# the block's module name as the layout knows it
sed 's/\\$paramod\\v5_blk\\GE=[^ ]*/v5_blk/' $OUT/synth_raw.v > $OUT/synth.v
grep -c "^  v5_blk " $OUT/synth.v | sed 's/^/blocks: /'
grep "Chip area" $OUT/synth_stat.txt | tail -1

# 2. Floorplan with the blocks in a grid, placement, clock tree, global routing
N=$N PERIOD=$PERIOD PLATFORM=$P OUT=$OUT $OPENROAD -exit -no_init tools/w2_engine.tcl > $OUT/place.log 2>&1 \
  || { tail -30 $OUT/place.log; exit 1; }
cat $OUT/groute_summary.txt
fi

# 3. Detailed routing, extraction, final figures (the block flow's stage 2)
if [ $STAGE != place ]; then
PERIOD=$PERIOD PLATFORM=$P OUT=$OUT $OPENROAD -exit -no_init tools/w2_route.tcl > $OUT/route.log 2>&1 \
  || { tail -30 $OUT/route.log; exit 1; }
cat $OUT/final_summary.txt
fi
