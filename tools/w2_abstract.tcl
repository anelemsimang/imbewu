# Make a finished block (tools/w2_layout.sh, both stages) reusable as one part
# of a larger layout (D-031): its outline, pins and blocked layers as a LEF
# abstract, and its timing as a Liberty model for one process corner (clock
# to each output, setup and hold at each input, on the real extracted wires).
# Env: PLATFORM, OUT (the block's layout folder), PDK, CORNER (default: the
# typical one). Writes OUT/model_<corner>.lib, and OUT/abstract.lef at the
# typical corner. tools/w2_abstract.sh runs it once per corner (a fresh
# process each time: clearing the database between corners crashes).
set P   $::env(PLATFORM)
set OUT $::env(OUT)
source tools/w2_pdk.tcl
set c [expr {[info exists ::env(CORNER)] ? $::env(CORNER) : $W2_TYP}]
set_thread_count 1   ;# write_timing_model crashes with several threads (OpenROAD 2.0-12381)

w2_read_tech $P $c
read_db $OUT/final.odb
read_sdc $OUT/groute.sdc
source $P/setRC.tcl
set_propagated_clock [all_clocks]
read_spef $OUT/final.spef
if {$c eq $W2_TYP} { write_abstract_lef $OUT/abstract.lef }
write_timing_model -library_name v5_blk_$c $OUT/model_$c.lib
puts "corner $c: model written"
