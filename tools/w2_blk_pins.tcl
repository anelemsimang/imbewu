# Pin places of the engine block v5_blk (D-031), sourced by tools/w2_layout.tcl
# when PINS is set. The block is repeated in a grid, so a pin leaving one block
# must sit exactly where the matching pin of its neighbour arrives:
#   a lane:            a_in on the left edge, a_out on the right, same height
#   column j (of GE):  b_in[j], dr_in[j] on the top edge, b_out[j], dr_out[j]
#                      on the bottom edge at the same x, inside column j's
#                      share of the width (above and below cell j)
#   cap, inj:          as the column pins, left of column 0
#   clk, rst:          top edge, middle (between columns GE/2 - 1 and GE/2)
# Vertical pins on M7 and horizontal ones on M4: the power grid uses M1, M2,
# M5 and M6 (tools/w2_pdk.tcl), so no pin can land on a power strap.
lassign [ord::get_die_area] X0 Y0 X1 Y1
set GE 16; set BW 18; set AW 22
set W [expr {$X1 - $X0}]
set H [expr {$Y1 - $Y0}]
# tracks (make_tracks.tcl): M7 x = 0.016 + k * 0.064; M4 y = 0.012 + k * 0.048
proc xt {x} { return [expr {0.016 + round(($x - 0.016) / 0.064) * 0.064}] }
proc yt {y} { return [expr {0.012 + round(($y - 0.012) / 0.048) * 0.048}] }
proc vpin {name x y} {
  place_pin -pin_name $name -layer M7 -location [list $x $y] -pin_size {0.032 0.256}
}
proc hpin {name x y} {
  place_pin -pin_name $name -layer M4 -location [list $x $y] -pin_size {0.256 0.024}
}
proc pair {in out x} {
  global Y0 Y1
  set x [xt $x]
  vpin $in  $x $Y1
  vpin $out $x $Y0
}
set slot [expr {$W / $GE}]
set step 0.256                      ;# 4 M7 tracks between neighbouring pins
for {set j 0} {$j < $GE} {incr j} {
  set x [expr {$X0 + $j * $slot + 0.5 * $slot - 25 * $step}]
  for {set k 0} {$k < $BW} {incr k} {
    set b [expr {$j * $BW + $k}]
    pair "b_in\[$b\]" "b_out\[$b\]" [expr {$x + $k * $step}]
  }
  for {set k 0} {$k < 32} {incr k} {
    set b [expr {$j * 32 + $k}]
    pair "dr_in\[$b\]" "dr_out\[$b\]" [expr {$x + ($BW + $k) * $step}]
  }
}
pair cap_in cap_out [expr {$X0 + 1.0}]
pair inj_in inj_out [expr {$X0 + 1.5}]
vpin clk [xt [expr {$X0 + $W / 2}]] $Y1
vpin rst [xt [expr {$X0 + $W / 2 + 2 * $step}]] $Y1
for {set k 0} {$k < $AW} {incr k} {
  set y [yt [expr {$Y0 + $H / 2 + ($k - $AW / 2) * 0.192}]]
  hpin "a_in\[$k\]"  $X0 $y
  hpin "a_out\[$k\]" $X1 $y
}
