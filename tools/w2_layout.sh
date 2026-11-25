#!/bin/sh
# Layout flow (W2 step 3): matmul_unit (tiling controller + version 5 engine)
# placed and wired on SKY130 with OpenROAD, then timing and power measured on
# the real wires. Free tools only.
# Usage: [STAGE=place|route|all] tools/w2_layout.sh [N] [CLOCK_PERIOD_NS] [LABEL]
#   place: synthesis, floorplan, placement, clock tree, global routing; saves
#          build/layout/LABEL/groute.odb and reports with estimated wires
#   route: detailed routing of that checkpoint, extraction, final reports
# Needs: yosys, /opt/eda/bin/openroad (environment setup script) and the SKY130
# platform files from OpenROAD-flow-scripts in build/pdk/sky130hd (fetched here
# if missing; not stored in the repository).
set -e
STAGE=${STAGE:-all}
N=${1:-4}; PERIOD=${2:-10}; LABEL=${3:-mm${N}_p${PERIOD}}
OPENROAD=${OPENROAD:-/opt/eda/bin/openroad}
P=build/pdk/sky130hd
OUT=build/layout/$LABEL; mkdir -p $OUT

# 1. SKY130 platform files (OpenROAD-flow-scripts, pinned commit)
ORFS=https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts
ORFS_REV=${ORFS_REV:-master}
for f in config.mk setRC.tcl pdn.tcl lef/sky130_fd_sc_hd.tlef lef/sky130_fd_sc_hd_merged.lef \
         lib/sky130_fd_sc_hd__tt_025C_1v80.lib; do
  [ -s $P/$f ] || { mkdir -p $(dirname $P/$f); curl -sSfL $ORFS/$ORFS_REV/flow/platforms/sky130hd/$f -o $P/$f; }
done
[ -s $P/rcx_patterns.rules ] && grep -q Extraction $P/rcx_patterns.rules || \
  curl -sSfL $ORFS/$ORFS_REV/flow/platforms/sky130hs/rcx_patterns.rules -o $P/rcx_patterns.rules
LIB=$P/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
SLIB=$P/lib/synth_tt.lib
if [ ! -s $SLIB ]; then
  DONT=$(sed -n '/^export DONT_USE_CELLS/,/^$/p' $P/config.mk | tr -d '\\' | grep -o 'sky130_fd_sc_hd__[a-z0-9_]*')
  python3 tools/lib_dont_use.py $LIB $SLIB $DONT
fi

if [ $STAGE != route ]; then
# 2. Synthesis: the same recipe as tools/w2_estimate.sh (parallel adders, same
#    ABC script), plus the clean-ups a layout tool needs (constants as tie
#    cells, no bare wire assignments).
RTL="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v rtl/matmul_unit.v"
yosys -p "read_verilog $RTL; chparam -set N $N matmul_unit; \
  synth -top matmul_unit -flatten -run :fine; techmap -autoproc -map tools/w2_kogge_stone.v -map +/techmap.v; \
  synth -top matmul_unit -flatten -run fine:; \
  dfflibmap -liberty $SLIB; abc -liberty $SLIB -script tools/w2_abc.script; \
  setundef -zero; splitnets; opt_clean -purge; \
  hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO; \
  insbuf -buf sky130_fd_sc_hd__buf_2 A X; opt_clean; read_liberty -lib $LIB; check -assert; \
  tee -o $OUT/synth_stat.txt stat -liberty $LIB; \
  write_verilog -noattr -noexpr -nohex -nodec $OUT/synth.v" > $OUT/synth.log 2>&1
grep "Chip area" $OUT/synth_stat.txt | tail -1


# 3. Floorplan to global routing (checkpoint + first figures)
PERIOD=$PERIOD PLATFORM=$P OUT=$OUT $OPENROAD -exit -no_init tools/w2_layout.tcl > $OUT/place.log 2>&1 \
  || { tail -30 $OUT/place.log; exit 1; }
cat $OUT/groute_summary.txt
fi

# 4. Detailed routing, real wire extraction, final figures
if [ $STAGE != place ]; then
PERIOD=$PERIOD PLATFORM=$P OUT=$OUT $OPENROAD -exit -no_init tools/w2_route.tcl > $OUT/route.log 2>&1 \
  || { tail -30 $OUT/route.log; exit 1; }
cat $OUT/final_summary.txt
fi
