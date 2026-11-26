# Stage 2 of the layout flow: detailed routing of the checkpoint written by
# tools/w2_layout.tcl, extraction of the real wire resistance and capacitance,
# then the final timing, area and power reports.
set P      $::env(PLATFORM)
set OUT    $::env(OUT)
set PERIOD $::env(PERIOD)
source tools/w2_pdk.tcl
source tools/w2_reports.tcl
source tools/w2_extract.tcl
set_thread_count [exec nproc]

w2_read_tech $P $W2_TYP
read_db $OUT/groute.odb
read_sdc $OUT/groute.sdc
source $P/setRC.tcl
set_propagated_clock [all_clocks]

set_routing_layers -signal $W2_SIG_LAYERS -clock $W2_CLK_LAYERS
detailed_route -output_drc $OUT/route_drc.rpt -droute_end_iter 30 -verbose 1
filler_placement $W2_FILL
write_db $OUT/final.odb

# Real wires: resistance and capacitance extracted from the routed layout
set nskip [w2_extract $P $OUT]
write_def $OUT/final.def
write_verilog $OUT/final.v

w2_reports $OUT final $PERIOD
set f [open $OUT/final_summary.txt a]
puts $f "Routing rule violations left: [detailed_route_num_drvs]"
puts $f "Nets timed without wire parasitics (shorts): $nskip"
close $f
