#!/bin/bash
# Layout flow (W2 step 3): matmul_unit (tiling controller + version 5 engine)
# placed and wired with OpenROAD on SKY130 (default) or ASAP7 (PDK=asap7), then
# timing and power measured on the real wires. Free tools only.
# Usage: [PDK=sky130hd|asap7] [STAGE=place|route|all] [UTIL=45] [DENSITY=0.65]
#        tools/w2_layout.sh [N] [CLOCK_PERIOD_NS] [LABEL]
#   UTIL: share of the core the cells cover at floorplan (%); DENSITY: target
#   placement density. Process settings: tools/w2_pdk.tcl.
#   place: synthesis, floorplan, placement, clock tree, global routing; saves
#          build/layout/LABEL/groute.odb and reports with estimated wires
#   route: detailed routing of that checkpoint, extraction, final reports
# Needs: yosys, /opt/eda/bin/openroad (environment setup script) and the
# platform files from OpenROAD-flow-scripts in build/pdk/$PDK (fetched here
# if missing; not stored in the repository).
set -e
STAGE=${STAGE:-all}
export PDK=${PDK:-sky130hd}
N=${1:-4}; PERIOD=${2:-10}; LABEL=${3:-mm${N}_p${PERIOD}}
OPENROAD=${OPENROAD:-/opt/eda/bin/openroad}
P=build/pdk/$PDK
OUT=build/layout/$LABEL; mkdir -p $OUT

# 1. Platform files (OpenROAD-flow-scripts)
ORFS=https://raw.githubusercontent.com/The-OpenROAD-Project/OpenROAD-flow-scripts
fetch() {   # platform, files...
  local plat=$1; shift
  for f in "$@"; do
    [ -s $P/$f ] || { mkdir -p $(dirname $P/$f); curl -sSfL $ORFS/$ORFS_REV/flow/platforms/$plat/$f -o $P/$f; }
  done
}
if [ $PDK = asap7 ]; then
  # pinned commit (2026-11-26); checksums of every file in tools/w2_asap7.sha256
  ORFS_REV=${ORFS_REV:-8ba54e723175036fbe1a3541c7a1141cfc4f83b9}
  L=lib/NLDM/asap7sc7p5t
  F="lef/asap7_tech_1x_201209.lef lef/asap7sc7p5t_28_R_1x_220121a.lef setRC.tcl rcx_patterns.rules
     openRoad/make_tracks.tcl openRoad/pdn/grid_strategy-M1-M2-M5-M6.tcl"
  for c in TT SS FF; do
    S=211120; [ $c = FF ] && S=250407   # the FF SIMPLE library was reissued in 2025
    F="$F ${L}_AO_RVT_${c}_nldm_211120.lib.gz ${L}_INVBUF_RVT_${c}_nldm_220122.lib.gz
       ${L}_OA_RVT_${c}_nldm_211120.lib.gz ${L}_SIMPLE_RVT_${c}_nldm_$S.lib.gz ${L}_SEQ_RVT_${c}_nldm_220123.lib"
  done
  fetch asap7 $F
  (R=$PWD; cd $P && sha256sum -c --quiet $R/tools/w2_asap7.sha256) || { echo "ASAP7 checksum mismatch"; exit 1; }
  LIB=$P/lib/merged_TT.lib; SLIB=$P/lib/synth_TT.lib
  [ -s $LIB ] || python3 tools/lib_merge.py $LIB "" $P/${L}_{AO,INVBUF,OA,SIMPLE}_RVT_TT_nldm_2*.lib.gz $P/${L}_SEQ_RVT_TT_nldm_220123.lib
  [ -s $SLIB ] || python3 tools/lib_merge.py $SLIB "*x1p*_ASAP7* *xp*_ASAP7* SDF* ICG* DFFASRHQN* DHL* DLL*" $LIB
  TIE="-hicell TIEHIx1_ASAP7_75t_R H -locell TIELOx1_ASAP7_75t_R L"; BUF="BUFx2_ASAP7_75t_R A Y"
else
  ORFS_REV=${ORFS_REV:-master}
  fetch sky130hd config.mk setRC.tcl pdn.tcl make_tracks.tcl lef/sky130_fd_sc_hd.tlef \
        lef/sky130_fd_sc_hd_merged.lef lib/sky130_fd_sc_hd__tt_025C_1v80.lib
  [ -s $P/rcx_patterns.rules ] && grep -q Extraction $P/rcx_patterns.rules || \
    curl -sSfL $ORFS/$ORFS_REV/flow/platforms/sky130hs/rcx_patterns.rules -o $P/rcx_patterns.rules
  LIB=$P/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
  SLIB=$P/lib/synth_tt.lib
  if [ ! -s $SLIB ]; then
    DONT=$(sed -n '/^export DONT_USE_CELLS/,/^$/p' $P/config.mk | tr -d '\\' | grep -o 'sky130_fd_sc_hd__[a-z0-9_]*')
    python3 tools/lib_dont_use.py $LIB $SLIB $DONT
  fi
  TIE="-hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO"; BUF="sky130_fd_sc_hd__buf_2 A X"
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
  hilomap -singleton $TIE; \
  insbuf -buf $BUF; opt_clean; read_liberty -lib $LIB; check -assert; \
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
