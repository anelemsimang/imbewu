# Worst setup slack by path kind (register to register, inputs to registers,
# registers to outputs, inputs straight to outputs) on the finished layout, at
# the corner whose library is LIB. Called by hand: PLATFORM= OUT= LIB= openroad -exit tools/w2_paths.tcl
set P $::env(PLATFORM); set OUT $::env(OUT); set LIB $::env(LIB)
read_lef $P/lef/sky130_fd_sc_hd.tlef
read_lef $P/lef/sky130_fd_sc_hd_merged.lef
read_liberty $LIB
read_db $OUT/final.odb
read_sdc $OUT/groute.sdc
set_propagated_clock [all_clocks]
read_spef $OUT/final.spef
set regs [all_registers]
set ins  [delete_from_list [all_inputs] [get_ports clk]]
proc ws {kind args} {
  set p [lindex [eval find_timing_paths -path_delay $kind -group_count 1 -sort_by_slack $args] 0]
  if {$p eq ""} { return "none" }
  return [format %.3f [get_property $p slack]]
}
foreach k {max min} {
  puts "PATHS $k reg->reg [ws $k -from $regs -to $regs]"
  puts "PATHS $k in->reg  [ws $k -from $ins -to $regs]"
  puts "PATHS $k reg->out [ws $k -from $regs -to [all_outputs]]"
  puts "PATHS $k in->out  [ws $k -from $ins -to [all_outputs]]"
}
set t [file rootname [file tail $LIB]]
report_checks -path_delay max -from $regs -to $regs -digits 3 > $OUT/paths_reg2reg_max_$t.rpt
report_checks -path_delay min -digits 3 > $OUT/paths_min_$t.rpt
