# Extraction of the real wire resistance and capacitance (OpenRCX), sourced by
# tools/w2_route.tcl and tools/w2_finish.tcl.
# OpenRCX stops on a net whose wiring still shorts to another pin (a routing
# violation the router could not clear). Such a net's wiring is dropped from
# the timing database (not from final.odb, written before) and extraction is
# retried; the dropped nets are timed without wire parasitics and listed in
# $OUT/extract_skipped_nets.txt, so a reader can see what was left out.
proc w2_extract {P OUT} {
  define_process_corner -ext_model_index 0 X
  set block [ord::get_db_block]
  set skipped {}
  while {[catch {extract_parasitics -ext_model_file $P/rcx_patterns.rules} err]} {
    if {![regexp {net (\S+), shorts} $err -> name] || [llength $skipped] >= 50} {
      error "extraction failed: $err"
    }
    set net [$block findNet $name]
    if {$net == "NULL" || [$net getWire] == "NULL"} { error "extraction failed: $err" }
    puts "w2_extract: net $name shorts to another pin; timing it without wire parasitics"
    odb::dbWire_destroy [$net getWire]
    lappend skipped $name
  }
  set f [open $OUT/extract_skipped_nets.txt w]
  puts $f "Nets left out of extraction (wiring shorts to another pin): [llength $skipped]"
  foreach n $skipped { puts $f $n }
  close $f
  write_spef $OUT/final.spef
  read_spef $OUT/final.spef
  return [llength $skipped]
}
