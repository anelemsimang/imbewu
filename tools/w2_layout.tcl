# OpenROAD layout of matmul_unit on SKY130 (called by tools/w2_layout.sh).
# Steps follow OpenROAD-flow-scripts: floorplan, power grid, placement,
# clock tree, timing repair, global and detailed routing, extraction of the
# real wire resistance and capacitance, then timing (OpenSTA) and power.
set P      $::env(PLATFORM)
set OUT    $::env(OUT)
set PERIOD $::env(PERIOD)
set LIB    $P/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

read_lef $P/lef/sky130_fd_sc_hd.tlef
read_lef $P/lef/sky130_fd_sc_hd_merged.lef
read_liberty $LIB
read_verilog $OUT/synth.v
link_design matmul_unit

# Timing constraints: one clock; memories and the C write port outside the
# unit are given 20% of the clock period each side.
create_clock -name clk -period $PERIOD [get_ports clk]
set_clock_uncertainty 0.1 [get_clocks clk]
set ins [delete_from_list [all_inputs] [get_ports clk]]
set_input_delay  [expr 0.2 * $PERIOD] -clock clk $ins
set_output_delay [expr 0.2 * $PERIOD] -clock clk [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 -pin X $ins
set_load 0.02 [all_outputs]
write_sdc $OUT/constraints.sdc

# Floorplan: cells cover 45% of the core; the rest is room for wiring, buffers
# added by timing repair, and the power grid.
initialize_floorplan -utilization 45 -aspect_ratio 1 -core_space 10 -site unithd
source $P/make_tracks.tcl
place_pins -hor_layers met3 -ver_layers met2
tapcell -distance 14 -tapcell_master sky130_fd_sc_hd__tapvpwrvgnd_1

# Power grid
add_global_connection -net VDD -pin_pattern {^VPWR$} -power
add_global_connection -net VDD -pin_pattern {^VPB$}  -power
add_global_connection -net VSS -pin_pattern {^VGND$} -ground
add_global_connection -net VSS -pin_pattern {^VNB$}  -ground
global_connect
source $P/pdn.tcl
pdngen

source $P/setRC.tcl
set_dont_use {sky130_fd_sc_hd__probe_p_8 sky130_fd_sc_hd__probec_p_8 sky130_fd_sc_hd__lpflow_*}

# Placement
global_placement -density 0.65 -pad_left 1 -pad_right 1
estimate_parasitics -placement
repair_design
detailed_placement

# Clock tree
clock_tree_synthesis -root_buf sky130_fd_sc_hd__clkbuf_16 \
  -buf_list {sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_8 sky130_fd_sc_hd__clkbuf_16} \
  -sink_clustering_enable
set_propagated_clock [all_clocks]
estimate_parasitics -placement
repair_clock_nets
repair_timing -setup -hold -hold_margin 0.05
detailed_placement
check_placement -verbose

# Routing
set_global_routing_layer_adjustment met1-met5 0.2
set_routing_layers -signal met1-met5 -clock met3-met5
global_route -congestion_report_file $OUT/congestion.rpt -allow_congestion
estimate_parasitics -global_routing
repair_timing -setup -hold -hold_margin 0.05
global_route -allow_congestion
detailed_route -output_drc $OUT/route_drc.rpt -droute_end_iter 30 -verbose 0
filler_placement {sky130_fd_sc_hd__fill_1 sky130_fd_sc_hd__fill_2 sky130_fd_sc_hd__fill_4 sky130_fd_sc_hd__fill_8}

# Real wires: extract resistance and capacitance from the routed layout
define_process_corner -ext_model_index 0 X
extract_parasitics -ext_model_file $P/rcx_patterns.rules
write_spef $OUT/final.spef
read_spef $OUT/final.spef
write_def $OUT/final.def
write_verilog $OUT/final.v

# Reports
report_checks -path_delay max -format full_clock_expanded -digits 3 > $OUT/timing_setup.rpt
report_checks -path_delay min -digits 3 > $OUT/timing_hold.rpt
report_clock_skew -digits 3 > $OUT/clock_skew.rpt
set f [open $OUT/summary.txt w]
set wns [sta::worst_slack_cmd max]
set hold [sta::worst_slack_cmd min]
set crit [expr $PERIOD - $wns]
puts $f "Clock period asked: $PERIOD ns"
puts $f "Worst setup slack:  [format %.3f $wns] ns"
puts $f "Worst hold slack:   [format %.3f $hold] ns"
puts $f "Achievable clock:   [format %.1f [expr 1000.0 / $crit]] MHz (period [format %.3f $crit] ns)"
close $f
report_design_area >> $OUT/summary.txt
set dbu [[ord::get_db_block] getDbUnitsPerMicron]
set die [[ord::get_db_block] getDieArea]
set f [open $OUT/summary.txt a]
puts $f "Die: [format %.1f [expr ([$die dx] / double($dbu))]] x [format %.1f [expr ([$die dy] / double($dbu))]] um"
puts $f "Routing DRC violations: [detailed_route_num_drvs]"
close $f
foreach act {0.1 0.2 0.5} {
  set_power_activity -input -activity $act
  report_power -digits 4 > $OUT/power_act$act.rpt
}
