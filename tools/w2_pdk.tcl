# Process settings for the layout flow (sourced by every tools/w2_*.tcl).
# PDK=sky130hd (default; SkyWater 130 nm) or asap7 (ASAP7 7 nm predictive kit,
# Arizona State University and ARM; a university kit, not a factory's).
# Platform files: build/pdk/$PDK (fetched by tools/w2_layout.sh).
#
# Units: SKY130's libraries count time in ns and capacitance in pF; ASAP7's
# in ps and fF. The scripts keep every clock period in ns and multiply by
# W2_TU (time units per ns) where a value goes to the tools.
set PDK [expr {[info exists ::env(PDK)] ? $::env(PDK) : "sky130hd"}]

if {$PDK eq "asap7"} {
  set W2_TU      1000.0
  set W2_TLEF    $P/lef/asap7_tech_1x_201209.lef
  set W2_LEFS    [list $P/lef/asap7sc7p5t_28_R_1x_220121a.lef]
  # corner: TT (25 C, 0.70 V), SS (100 C, 0.63 V), FF (0 C, 0.77 V)
  proc w2_libs {P corner} {
    set d $P/lib/NLDM
    set simple [lindex [lsort [glob $d/asap7sc7p5t_SIMPLE_RVT_${corner}_nldm_*.lib.gz]] end]
    return [list $d/asap7sc7p5t_AO_RVT_${corner}_nldm_211120.lib.gz \
                 $d/asap7sc7p5t_INVBUF_RVT_${corner}_nldm_220122.lib.gz \
                 $d/asap7sc7p5t_OA_RVT_${corner}_nldm_211120.lib.gz $simple \
                 $d/asap7sc7p5t_SEQ_RVT_${corner}_nldm_220123.lib]
  }
  set W2_TYP     TT
  set W2_CORNERS {SS FF}
  set W2_SITE    asap7sc7p5t
  set W2_CORE_SPACE 2
  set W2_DRIVER  {BUFx2_ASAP7_75t_R Y}
  set W2_LOAD    2.0                      ;# fF
  set W2_UNC     0.02                     ;# ns
  set W2_HOLDM   0.01                     ;# ns
  set W2_PIN_LAYERS {M4 M5}
  set W2_SIG_LAYERS M2-M7
  set W2_CLK_LAYERS M4-M7
  set W2_LAYER_ADJ  0.25
  set W2_CTS_ROOT BUFx12f_ASAP7_75t_R
  set W2_CTS_BUFS {BUFx4_ASAP7_75t_R BUFx8_ASAP7_75t_R BUFx12f_ASAP7_75t_R}
  set W2_DONT_USE {*x1p*_ASAP7* *xp*_ASAP7* SDF* ICG*}
  set W2_FILL    {FILLERxp5_ASAP7_75t_R FILLER_ASAP7_75t_R DECAPx1_ASAP7_75t_R DECAPx2_ASAP7_75t_R \
                  DECAPx4_ASAP7_75t_R DECAPx6_ASAP7_75t_R DECAPx10_ASAP7_75t_R}
  set W2_FILL_RE {^(FILLER|DECAP|TAPCELL)}
  proc w2_taps {} {
    tapcell -distance 25 -tapcell_master TAPCELL_ASAP7_75t_R -endcap_master TAPCELL_ASAP7_75t_R
  }
  proc w2_power_nets {} {
    add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {^VDD$} -power
    add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {^VSS$} -ground
  }
  set W2_PDN     $P/openRoad/pdn/grid_strategy-M1-M2-M5-M6.tcl
  set W2_TRACKS  $P/openRoad/make_tracks.tcl
  suppress_message STA 1212   ;# intended output-to-output arcs in FAx1/HAxp5 (see ORFS)
} else {
  set W2_TU      1.0
  set W2_TLEF    $P/lef/sky130_fd_sc_hd.tlef
  set W2_LEFS    [list $P/lef/sky130_fd_sc_hd_merged.lef]
  proc w2_libs {P corner} {
    if {$corner eq "tt"} { return [list $P/lib/sky130_fd_sc_hd__tt_025C_1v80.lib] }
    return [list build/pdk/sky130a_ss/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__$corner.lib]
  }
  set W2_TYP     tt
  set W2_CORNERS {ss_100C_1v60 ff_n40C_1v95}
  set W2_SITE    unithd
  set W2_CORE_SPACE 10
  set W2_DRIVER  {sky130_fd_sc_hd__buf_2 X}
  set W2_LOAD    0.02                     ;# pF
  set W2_UNC     0.1
  set W2_HOLDM   0.05
  set W2_PIN_LAYERS {met3 met2}
  set W2_SIG_LAYERS met1-met5
  set W2_CLK_LAYERS met3-met5
  set W2_LAYER_ADJ  0.2
  set W2_CTS_ROOT sky130_fd_sc_hd__clkbuf_16
  set W2_CTS_BUFS {sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_8 sky130_fd_sc_hd__clkbuf_16}
  set W2_DONT_USE {sky130_fd_sc_hd__probe_p_8 sky130_fd_sc_hd__probec_p_8 sky130_fd_sc_hd__lpflow_*}
  set W2_FILL    {sky130_fd_sc_hd__fill_1 sky130_fd_sc_hd__fill_2 sky130_fd_sc_hd__fill_4 sky130_fd_sc_hd__fill_8}
  set W2_FILL_RE {__(fill|tapvpwrvgnd|decap)}
  proc w2_taps {} {
    tapcell -distance 14 -tapcell_master sky130_fd_sc_hd__tapvpwrvgnd_1
  }
  proc w2_power_nets {} {
    add_global_connection -net VDD -pin_pattern {^VPWR$} -power
    add_global_connection -net VDD -pin_pattern {^VPB$}  -power
    add_global_connection -net VSS -pin_pattern {^VGND$} -ground
    add_global_connection -net VSS -pin_pattern {^VNB$}  -ground
  }
  set W2_PDN     $P/pdn.tcl
  set W2_TRACKS  $P/make_tracks.tcl
}

# Read the process's layers, cells and (for one corner) timing libraries
proc w2_read_tech {P corner} {
  global W2_TLEF W2_LEFS
  read_lef $W2_TLEF
  foreach l $W2_LEFS { read_lef $l }
  foreach l [w2_libs $P $corner] { read_liberty $l }
  # MACROS: layout folders of finished blocks used as parts (D-031), each
  # with abstract.lef and model_<corner>.lib from tools/w2_abstract.sh
  if {[info exists ::env(MACROS)]} {
    foreach d $::env(MACROS) {
      read_lef $d/abstract.lef
      read_liberty $d/model_$corner.lib
    }
  }
}
