# Extraction of the real wire resistance and capacitance (OpenRCX), sourced by
# tools/w2_route.tcl and tools/w2_finish.tcl.
# OpenRCX stops on a net whose wiring still shorts to another pin (a routing
# violation the router could not clear), and names the net only in the log.
# tools/w2_finish.sh reads that name, adds it to $OUT/extract_skipped_nets.txt
# and runs again; the listed nets' wiring is dropped from the timing database
# here (final.odb on disk keeps it), so they are timed without wire parasitics.
proc w2_extract {P OUT} {
  set block [ord::get_db_block]
  set skipped {}
  set list $OUT/extract_skipped_nets.txt
  if {[file exists $list]} {
    set f [open $list]
    foreach name [split [read $f] "\n"] {
      if {$name eq ""} continue
      set net [$block findNet $name]
      if {$net != "NULL" && [$net getWire] != "NULL"} { odb::dbWire_destroy [$net getWire] }
      lappend skipped $name
    }
    close $f
  }
  define_process_corner -ext_model_index 0 X
  extract_parasitics -ext_model_file $P/rcx_patterns.rules
  write_spef $OUT/final.spef
  read_spef $OUT/final.spef
  return [llength $skipped]
}
