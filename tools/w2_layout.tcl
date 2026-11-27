# OpenROAD layout of matmul_unit on SKY130 or ASAP7 (PDK=; called by
# tools/w2_layout.sh; process settings in tools/w2_pdk.tcl).
# Steps follow OpenROAD-flow-scripts: floorplan, power grid, placement,
# clock tree, timing repair, global and detailed routing, extraction of the
# real wire resistance and capacitance, then timing (OpenSTA) and power.
set P      $::env(PLATFORM)
set OUT    $::env(OUT)
set PERIOD $::env(PERIOD)
source tools/w2_pdk.tcl
source tools/w2_reports.tcl
set_thread_count [exec nproc]

w2_read_tech $P $W2_TYP
read_verilog $OUT/synth.v
set TOP [expr {[info exists ::env(TOP)] ? $::env(TOP) : "matmul_unit"}]
link_design $TOP

# Timing constraints: one clock; memories and the C write port outside the
# unit are given 20% of the clock period each side.
create_clock -name clk -period [expr $PERIOD * $W2_TU] [get_ports clk]
set_clock_uncertainty [expr $W2_UNC * $W2_TU] [get_clocks clk]
set ins [delete_from_list [all_inputs] [get_ports clk]]
if {[info exists ::env(PINS)]} {
  # A block of a grid (D-031): every input comes from a flip-flop in an
  # identical neighbour, every output goes to one. Their clock arrives
  # BLK_LAT after the ideal edge, like this block's own (0.18-0.23 ns in
  # the first ASAP7 block layout), within +-0.01 ns; flip-flop delay
  # 0.03-0.06 ns, wire between blocks up to 0.02 ns, setup 0.02 ns.
  # Hold between blocks is checked again when the grid is put together.
  set lat [expr {[info exists ::env(BLK_LAT)] ? $::env(BLK_LAT) : 0.20}]
  set_input_delay  -max [expr {($lat + 0.10) * $W2_TU}] -clock clk $ins
  set_input_delay  -min [expr {($lat + 0.02) * $W2_TU}] -clock clk $ins
  set_output_delay -max [expr {(0.05 - $lat) * $W2_TU}] -clock clk [all_outputs]
  set_output_delay -min [expr {-($lat + 0.01) * $W2_TU}] -clock clk [all_outputs]
} else {
  set_input_delay  [expr 0.2 * $PERIOD * $W2_TU] -clock clk $ins
  set_output_delay [expr 0.2 * $PERIOD * $W2_TU] -clock clk [all_outputs]
}
set_driving_cell -lib_cell [lindex $W2_DRIVER 0] -pin [lindex $W2_DRIVER 1] $ins
set_load $W2_LOAD [all_outputs]
write_sdc $OUT/constraints.sdc

# Floorplan: cells cover 45% of the core; the rest is room for wiring, buffers
# added by timing repair, and the power grid.
# CORE_WH="w h" (µm) sets the core size instead (a block that must fit a
# grid, D-031); PINS names a script placing the pins instead of place_pins.
if {[info exists ::env(CORE_WH)]} {
  lassign $::env(CORE_WH) cw ch
  set cs $W2_CORE_SPACE
  initialize_floorplan -site $W2_SITE -die_area [list 0 0 [expr {$cw + 2 * $cs}] [expr {$ch + 2 * $cs}]] \
    -core_area [list $cs $cs [expr {$cw + $cs}] [expr {$ch + $cs}]]
} else {
  set UTIL [expr {[info exists ::env(UTIL)] ? $::env(UTIL) : 45}]
  initialize_floorplan -utilization $UTIL -aspect_ratio 1 -core_space $W2_CORE_SPACE -site $W2_SITE
}
source $W2_TRACKS
if {[info exists ::env(PINS)]} {
  source $::env(PINS)
} else {
  place_pins -hor_layers [lindex $W2_PIN_LAYERS 0] -ver_layers [lindex $W2_PIN_LAYERS 1]
}
w2_taps

# Power grid
w2_power_nets
global_connect
source $W2_PDN
pdngen

source $P/setRC.tcl
set_dont_use $W2_DONT_USE

# Placement
set DENS [expr {[info exists ::env(DENSITY)] ? $::env(DENSITY) : 0.65}]
global_placement -density $DENS -pad_left 1 -pad_right 1
estimate_parasitics -placement
repair_design
detailed_placement

# Clock tree
clock_tree_synthesis -root_buf $W2_CTS_ROOT -buf_list $W2_CTS_BUFS -sink_clustering_enable
set_propagated_clock [all_clocks]
estimate_parasitics -placement
repair_clock_nets
repair_timing -setup -hold -hold_margin [expr $W2_HOLDM * $W2_TU]
detailed_placement
check_placement -verbose

# Routing
set_global_routing_layer_adjustment $W2_SIG_LAYERS $W2_LAYER_ADJ
set_routing_layers -signal $W2_SIG_LAYERS -clock $W2_CLK_LAYERS
global_route -congestion_report_file $OUT/congestion.rpt -allow_congestion
estimate_parasitics -global_routing
repair_timing -setup -hold -hold_margin [expr $W2_HOLDM * $W2_TU]
global_route -allow_congestion -congestion_report_file $OUT/congestion2.rpt
estimate_parasitics -global_routing

# Checkpoint for stage 2 (tools/w2_route.tcl), and first figures with wires
# estimated from global routing
write_db $OUT/groute.odb
write_sdc $OUT/groute.sdc
w2_reports $OUT groute $PERIOD
