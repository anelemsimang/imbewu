#!/bin/sh
# Planted bugs in the FP32 -> MX converter; each must make the test fail.
#  1 ties rounded up instead of to even      2 FP8 block scale one step off
#  3 FP8 capped at 480 instead of 448        4 block scale not kept above -127
#  5 tiny (subnormal) inputs' exponent off   6 INT8 not allowed to reach -128
OUT=build/mut_mxq; mkdir -p $OUT; i=0; missed=0
for e in 's/R = R0 + (g \&\& (st || R0\[0\]));/R = R0 + g;/' \
         "s/emax_of = (f == 2'd1) ? 4'd8/emax_of = (f == 2'd1) ? 4'd7/" \
         's/if (ef > 15 || (ef == 15 \&\& mant > 6))/if (ef > 15)/' \
         's/block_e = (t < -10.sd127) ? -10.sd127 : t;/block_e = t;/' \
         's/else for (b = 0; b < 23; b = b + 1) if (x\[b\]) ilog2 = b - 149;/else for (b = 0; b < 23; b = b + 1) if (x[b]) ilog2 = b - 150;/' \
         "s/else      sv = (R > 128) ? -10'sd128/else      sv = (R > 127) ? -10'sd127/"; do
  i=$((i+1)); sed "$e" rtl/mx_quant.v > $OUT/m$i.v
  cmp -s rtl/mx_quant.v $OUT/m$i.v && { echo "bug $i: edit did not apply"; missed=1; continue; }
  if MXQ=$OUT/m$i.v OUT=$OUT tests/run_mx_quant_tests.sh > $OUT/log$i 2>&1; then
    echo "bug $i MISSED"; missed=1
  elif grep -q '^FAIL: N=' $OUT/log$i; then echo "bug $i caught: $(grep '^FAIL:' $OUT/log$i)"
  else echo "bug $i: test did not run (see $OUT/log$i)"; missed=1; fi
done
exit $missed
