# Finish stage 2 from its saved routed layout (final.odb) without routing again:
# extraction, then the final reports. Used when tools/w2_route.tcl stopped after
# writing final.odb. Run by tools/w2_finish.sh.
set P      $::env(PLATFORM)
set OUT    $::env(OUT)
set PERIOD $::env(PERIOD)
source tools/w2_pdk.tcl
source tools/w2_reports.tcl
source tools/w2_extract.tcl
set_thread_count [exec nproc]

w2_read_tech $P $W2_TYP
read_db $OUT/final.odb
read_sdc $OUT/groute.sdc
source $P/setRC.tcl
set_propagated_clock [all_clocks]

set nskip [w2_extract $P $OUT]
write_def $OUT/final.def
write_verilog $OUT/final.v
w2_reports $OUT final $PERIOD
set nviol [llength [regexp -all -inline {violation type} [read [open $OUT/route_drc.rpt]]]]
set f [open $OUT/final_summary.txt a]
puts $f "Routing rule violations left: $nviol"
puts $f "Nets timed without wire parasitics (shorts): $nskip"
close $f
