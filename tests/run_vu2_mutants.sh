#!/bin/sh
# Planted bugs in vector unit version 2; each must be caught by the 2^x / 1/x
# test (tests/run_vu2_special.py) or the program tests (tests/run_vu_tests.py).
#  1 2^x reads the wrong table entry        2 2^x rounds negative inputs the wrong way
#  3 2^x drops its second-order correction  4 1/x exponent one step off
#  5 1/x second-order correction with the wrong sign
#  6 constant-operand instructions use a register instead of the constant
OUT=build/mut_vu2; mkdir -p $OUT; i=0; missed=0
for e in 's/m  = ({40.d0, ex2_t(fr\[23:18\])} \* e2) >> 30;/m  = ({40'"'"'d0, ex2_t(fr[23:18] + 6'"'"'d1)} * e2) >> 30;/' \
         's/ - (lost ? 34.sd1 : 34.sd0) :/ :/' \
         's/e2 = e2 + t1\[31:0\] + t2\[31:0\];/e2 = e2 + t1[31:0];/' \
         's/field = 10.sd253 - /field = 10'"'"'sd252 - /' \
         's/R  = \$signed({32.d0, c\[95:64\]}) - p1 + p2;/R  = $signed({32'"'"'d0, c[95:64]}) - p1 - p2;/' \
         's/wire        cop = (op >= 6.d17 \&\& op <= 6.d21);/wire        cop = 1'"'"'b0;/'; do
  i=$((i+1)); sed "$e" rtl/vu_v2.v > $OUT/m$i.v
  cmp -s rtl/vu_v2.v $OUT/m$i.v && { echo "bug $i: edit did not apply"; missed=1; continue; }
  if IMBEWU_VU2=$OUT/m$i.v python3 tests/run_vu2_special.py > $OUT/log$i 2>&1; then
    if IMBEWU_VU2=$OUT/m$i.v python3 tests/run_vu_tests.py >> $OUT/log$i 2>&1; then
      echo "bug $i MISSED"; missed=1
    else echo "bug $i caught by the program tests"; fi
  elif grep -q '^FAIL' $OUT/log$i; then echo "bug $i caught by the 2^x / 1/x test"
  else echo "bug $i: test did not run (see $OUT/log$i)"; missed=1; fi
done
exit $missed
