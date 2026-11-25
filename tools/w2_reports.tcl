# Timing, area and power reports for the layout flow (sourced by
# tools/w2_layout.tcl and tools/w2_route.tcl). TAG names the stage:
# "groute" = wires estimated from global routing, "final" = wires extracted
# from the finished detailed routing.
proc w2_reports {OUT TAG PERIOD} {
  report_checks -path_delay max -format full_clock_expanded -digits 3 > $OUT/${TAG}_setup.rpt
  report_checks -path_delay min -digits 3 > $OUT/${TAG}_hold.rpt
  report_clock_skew -digits 3 > $OUT/${TAG}_skew.rpt
  report_tns > $OUT/${TAG}_tns.rpt

  set wns  [sta::worst_slack_cmd max]
  set hold [sta::worst_slack_cmd min]
  set crit [expr $PERIOD - $wns]

  # Cell area by kind (logic, clock tree, tap/filler), and the die size
  set block [ord::get_db_block]
  set dbu [$block getDbUnitsPerMicron]
  set total 0.0; set fill 0.0
  foreach inst [$block getInsts] {
    set m [$inst getMaster]
    set a [expr [$m getWidth] * [$m getHeight] / double($dbu * $dbu)]
    set total [expr $total + $a]
    if {[regexp {__(fill|tapvpwrvgnd|decap)} [$m getName]]} { set fill [expr $fill + $a] }
  }
  set die  [$block getDieArea]
  set core [$block getCoreArea]
  set dx [expr [$die dx] / double($dbu)]; set dy [expr [$die dy] / double($dbu)]
  set cx [expr [$core dx] / double($dbu)]; set cy [expr [$core dy] / double($dbu)]

  set f [open $OUT/${TAG}_summary.txt w]
  puts $f "Stage:              $TAG"
  puts $f "Clock period asked: $PERIOD ns"
  puts $f "Worst setup slack:  [format %.3f $wns] ns"
  puts $f "Worst hold slack:   [format %.3f $hold] ns"
  puts $f "Achievable clock:   [format %.1f [expr 1000.0 / $crit]] MHz (period [format %.3f $crit] ns)"
  puts $f "Cell area (logic, buffers, clock tree): [format %.0f [expr $total - $fill]] um^2"
  puts $f "Cell area incl. tap/filler cells:       [format %.0f $total] um^2"
  puts $f "Core: [format %.1f $cx] x [format %.1f $cy] um; die: [format %.1f $dx] x [format %.1f $dy] um ([format %.3f [expr $dx * $dy / 1e6]] mm^2)"
  close $f

  foreach act {0.1 0.2 0.5} {
    set_power_activity -input -activity $act
    report_power -digits 4 > $OUT/${TAG}_power_act$act.rpt
  }
}
