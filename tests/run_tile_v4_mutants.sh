#!/bin/sh
# Planted bugs in tile_v4's post-processing stage; each must be caught.
#  1 transpose puts tokens in the wrong lanes     2 "dep" ignored (reads too early)
#  3 converter fed the input row, not the program's results
#  4 block scales written for the wrong token tile
#  5 transpose written out before the converter has finished
#  6 converter fed before the vector unit has finished
OUT=build/mut_t4; mkdir -p $OUT; i=0; missed=0
RTL="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v rtl/matmul_unit.v rtl/sram.v rtl/fp32_ops.v rtl/vu_v1.v rtl/mx_quant.v"
[ -f $OUT/a_meta.hex ] || python3 tools/gen_tile_v4_vectors.py 4 silu mxint8 $OUT/a > /dev/null
[ -f $OUT/b_meta.hex ] || python3 tools/gen_tile_v4_vectors.py 4 rmsnorm mxfp8 $OUT/b 9 > /dev/null
for e in 's/tq\[(qrow % N) \* CMAX + qword \* N + li\]/tq[((qrow + 1) % N) * CMAX + qword * N + li]/' \
         's/(!f_dep(ncmd_ld) || nst >= nli)/(1'"'"'b1)/' \
         "s/p_vaddr <= ((f_pmode(pcmd) == 2'd2) ? 8'd64 : 8'd0)/p_vaddr <= 8'd0/" \
         's/pmem\[f_mt(pcmd) \* p_kc + p_tile \* p_kb + (pe - p_kc)\]/pmem[f_mt(pcmd) * p_kc + (pe - p_kc)]/' \
         's/if (qrow == pr \&\& !fv \&\& !q_iv) begin pe <= 0;/if (1) begin pe <= 0;/' \
         's/PS_VUW:  if (!vu_busy) pstate <= PS_FEED;/PS_VUW:  pstate <= PS_FEED;/'; do
  i=$((i+1)); sed "$e" rtl/tile_v4.v > $OUT/m$i.v
  cmp -s rtl/tile_v4.v $OUT/m$i.v && { echo "bug $i: edit did not apply"; missed=1; continue; }
  if ! iverilog -g2012 -DGRID_N=4 -o $OUT/sim$i $RTL $OUT/m$i.v tests/tb_tile_v4.v 2> $OUT/log$i; then
    echo "bug $i: did not compile (see $OUT/log$i)"; missed=1; continue; fi
  caught=""
  for v in a b; do
    vvp -n $OUT/sim$i +PRE=$OUT/$v +LAT=20 > $OUT/log${i}$v 2>&1
    grep -q '^PASS' $OUT/log${i}$v || { grep -q '^FAIL' $OUT/log${i}$v && caught="$caught $v"; }
  done
  if [ -n "$caught" ]; then echo "bug $i caught (runs:$caught)"; else echo "bug $i MISSED"; missed=1; fi
done
exit $missed
