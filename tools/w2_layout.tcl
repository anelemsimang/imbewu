# OpenROAD layout of matmul_unit on SKY130 (called by tools/w2_layout.sh).
# Steps follow OpenROAD-flow-scripts: floorplan, power grid, placement,
# clock tree, timing repair, global and detailed routing, extraction of the
# real wire resistance and capacitance, then timing (OpenSTA) and power.
set P      $::env(PLATFORM)
set OUT    $::env(OUT)
set PERIOD $::env(PERIOD)
set LIB    $P/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
source tools/w2_reports.tcl
set_thread_count [exec nproc]

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
global_route -allow_congestion -congestion_report_file $OUT/congestion2.rpt
estimate_parasitics -global_routing

# Checkpoint for stage 2 (tools/w2_route.tcl), and first figures with wires
# estimated from global routing
write_db $OUT/groute.odb
write_sdc $OUT/groute.sdc
w2_reports $OUT groute $PERIOD
