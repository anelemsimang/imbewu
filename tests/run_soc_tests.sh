#!/bin/sh
# Tile + RISC-V driver tests: the driver program (fw/tile_driver.c) builds the
# command list itself; it must equal the generator's, and every answer must
# be right. Each line: N GROUPS PER MT NT KB FA FB RELOAD ONE_SLOT
set -e
OUT=${OUT:-build/soc}; mkdir -p $OUT
SOC=${SOC:-rtl/tile_soc.v}
while read N G P MT NT KB FA FB RL OS; do
  [ -z "$N" ] && continue
  tag=${N}_${G}x${P}_${MT}${NT}${KB}_${FA}${FB}_${RL}${OS}
  slots=alt; [ $OS = 1 ] && slots=one
  DEC_MT=$MT DEC_NT=$NT DEC_KB=$KB DEC_FA=$FA DEC_FB=$FB \
    python3 tools/gen_tile_v2_vectors.py $N $G $P $OUT/v_$tag 5 $RL decode $slots v3 > /dev/null
  fw/build.sh $OUT/fw_$tag.hex -DGRID=$N -DGROUPS=$G -DPER=$P -DMT=$MT -DNT=$NT -DKB=$KB \
    -DFA=$FA -DFB=$FB -DRELOAD=$RL -DONE_SLOT=$OS > /dev/null
  [ -f $OUT/tb_$N ] || iverilog -g2012 -DGRID_N=$N -o $OUT/tb_$N rtl/third_party/picorv32.v \
    rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v rtl/matmul_unit.v rtl/sram.v \
    rtl/tile_v3.v $SOC tests/tb_tile_soc.v 2> /dev/null
  log=$(vvp -n $OUT/tb_$N +PRE=$OUT/v_$tag +FW=$OUT/fw_$tag.hex)
  echo "$log" | grep -E "^SOC" | sed "s/^/[$tag] /"
  echo "$log" | grep -q '^PASS' || { echo "FAIL: $tag"; exit 1; }
done <<LIST
4 3 5 1 3 3 1 2 0 0
4 2 4 2 2 2 1 1 0 0
4 2 3 1 2 2 0 0 1 0
4 3 3 1 2 3 2 2 0 1
8 2 4 1 3 2 1 2 0 0
16 2 3 1 2 2 0 2 0 0
LIST
echo "tile + RISC-V driver: all PASS"
