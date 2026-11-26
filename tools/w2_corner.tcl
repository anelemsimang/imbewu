# Timing and power of the finished layout at another process corner: the same
# placed and routed design and the same extracted wires (build/layout/LABEL/
# final.odb, final.spef), timed with that corner's cell library.
# Called by tools/w2_corner.sh. Wire resistance and capacitance stay at their
# typical values (one extraction model is available), so only the gates change.
set P      $::env(PLATFORM)
set OUT    $::env(OUT)
set PERIOD $::env(PERIOD)
set TAG    $::env(CORNER)
source tools/w2_pdk.tcl
source tools/w2_reports.tcl

w2_read_tech $P $TAG
read_db $OUT/final.odb
read_sdc $OUT/groute.sdc
set_propagated_clock [all_clocks]
read_spef $OUT/final.spef
w2_reports $OUT $TAG $PERIOD
