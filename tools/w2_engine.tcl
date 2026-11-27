# OpenROAD layout of the whole engine built from finished blocks (D-031),
# called by tools/w2_engine.sh. Steps as tools/w2_layout.tcl, except that the
# 64 blocks are placed by hand in a grid (N rows x N/16 columns) before the
# engine's own cells are placed around them:
#   left margin:  the a lanes' delay lines (row i waits i ticks)
#   top margin:   the b lanes' delay lines (column j waits j ticks), clock
#   bottom:       results out (row N-1's hand-down registers), read-out timing
# Between blocks: narrow channels for the short wires from one block's pins
# to its neighbour's (the pins line up, tools/w2_blk_pins.tcl).
set P      $::env(PLATFORM)
set OUT    $::env(OUT)
set PERIOD $::env(PERIOD)
set N      $::env(N)
source tools/w2_pdk.tcl
source tools/w2_reports.tcl
set_thread_count [exec nproc]

w2_read_tech $P $W2_TYP
read_verilog $OUT/synth.v
link_design systolic_v5

create_clock -name clk -period [expr $PERIOD * $W2_TU] [get_ports clk]
set_clock_uncertainty [expr $W2_UNC * $W2_TU] [get_clocks clk]
set ins [delete_from_list [all_inputs] [get_ports clk]]
set_input_delay  [expr 0.2 * $PERIOD * $W2_TU] -clock clk $ins
set_output_delay [expr 0.2 * $PERIOD * $W2_TU] -clock clk [all_outputs]
set_driving_cell -lib_cell [lindex $W2_DRIVER 0] -pin [lindex $W2_DRIVER 1] $ins
set_load $W2_LOAD [all_outputs]
write_sdc $OUT/constraints.sdc

# Grid. Block origins are on the M7 track grid (x, 0.064 µm) and the M4 grid
# (y, 0.048 µm), so neighbouring blocks' pins meet exactly.
set blk  [[ord::get_db] findMaster v5_blk]
set BW   [ord::dbu_to_microns [$blk getWidth]]
set BH   [ord::dbu_to_microns [$blk getHeight]]
set NC   [expr {$N / 16}]
set XL   34.56                 ;# left margin
set XR   10.368                ;# right margin
set YT   32.4                  ;# top margin
set YB   10.8                  ;# bottom margin
set PX   [expr {ceil(($BW + 3.0) / 0.064) * 0.064}]   ;# column pitch
set PY   [expr {ceil(($BH + 2.3) / 0.048) * 0.048}]   ;# row pitch
set W    [expr {$XL + $NC * $PX + $XR}]
set H    [expr {$YB + $N * $PY + $YT}]
set H    [expr {ceil($H / 0.048) * 0.048}]
initialize_floorplan -site $W2_SITE -die_area [list 0 0 $W $H] -core_area [list 0 0 $W $H]
source $W2_TRACKS
puts [format "Engine grid: %d x %d blocks of %.3f x %.3f um, pitch %.3f x %.3f; die %.1f x %.1f um (%.3f mm^2)" \
        $N $NC $BW $BH $PX $PY $W $H [expr {$W * $H / 1e6}]]

set nb 0
foreach inst [[ord::get_db_block] getInsts] {
  if {[[$inst getMaster] getName] ne "v5_blk"} continue
  if {![regexp {row\\?\[(\d+)\\?\]\.grp\\?\[(\d+)\\?\]} [$inst getName] -> i g]} {
    error "block instance name not understood: [$inst getName]"
  }
  set x [expr {$XL + $g * $PX}]
  set y [expr {$H - $YT - $i * $PY - $BH}]
  $inst setOrigin [ord::microns_to_dbu $x] [ord::microns_to_dbu $y]
  $inst setOrient R0
  $inst setPlacementStatus FIRM
  incr nb
}
puts "Blocks placed: $nb"
cut_rows -halo_width_x 0.5 -halo_width_y 0.5

# Engine pins: a side on the left, b side and clock on top, results below
proc names {pat} { set l {}; foreach p [get_ports $pat] { lappend l [get_full_name $p] }; return $l }
set_io_pin_constraint -pin_names [concat [names a_col*] [names in_a_scale*] [names in_valid] \
  [names in_blk_last] [names in_job_last] [names in_fa*] [names in_ph]] -region left:*
set_io_pin_constraint -pin_names [concat [names b_row*] [names in_b_scale*] [names in_fb*] \
  [names clk] [names rst]] -region top:*
set_io_pin_constraint -pin_names [concat [names out_*]] -region bottom:*
place_pins -hor_layers [lindex $W2_PIN_LAYERS 0] -ver_layers [lindex $W2_PIN_LAYERS 1]
w2_taps

# Power grid for the engine's own cells (the blocks carry their own grid;
# joining the two is not done yet, see docs/RESULTS.md)
w2_power_nets
global_connect
define_pdn_grid -name top -voltage_domains {CORE}
add_pdn_stripe -grid top -layer M1 -width 0.018 -pitch 0.54 -offset 0 -followpins
add_pdn_stripe -grid top -layer M2 -width 0.018 -pitch 0.54 -offset 0 -followpins
add_pdn_connect -grid top -layers {M1 M2}
pdngen

source $P/setRC.tcl
set_dont_use $W2_DONT_USE

set DENS [expr {[info exists ::env(DENSITY)] ? $::env(DENSITY) : 0.6}]
global_placement -density $DENS -pad_left 1 -pad_right 1
estimate_parasitics -placement
repair_design
detailed_placement

clock_tree_synthesis -root_buf $W2_CTS_ROOT -buf_list $W2_CTS_BUFS -sink_clustering_enable
set_propagated_clock [all_clocks]
estimate_parasitics -placement
repair_clock_nets
repair_timing -setup -hold -hold_margin [expr $W2_HOLDM * $W2_TU]
detailed_placement
check_placement -verbose

set_global_routing_layer_adjustment $W2_SIG_LAYERS $W2_LAYER_ADJ
set_routing_layers -signal $W2_SIG_LAYERS -clock $W2_CLK_LAYERS
global_route -congestion_report_file $OUT/congestion.rpt -allow_congestion
estimate_parasitics -global_routing
repair_timing -setup -hold -hold_margin [expr $W2_HOLDM * $W2_TU]
global_route -allow_congestion -congestion_report_file $OUT/congestion2.rpt
estimate_parasitics -global_routing

write_db $OUT/groute.odb
write_sdc $OUT/groute.sdc
w2_reports $OUT groute $PERIOD
