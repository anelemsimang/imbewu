#!/bin/sh
# Planted bugs in the cluster arbiter: each must make tests/run_cluster_tests.sh fail.
# 1: every answer labelled for tile 0;  2: one more grant per tick than memory channels.
OUT=build/mut_cl; mkdir -p $OUT; i=0; missed=0
for e in 's/                        m_tag\[8\*j +: 8\] = idx;/                        m_tag[8*j +: 8] = 0;/' \
         's/if (t_req\[idx\] \&\& g < B) begin/if (t_req[idx] \&\& g < B + 1) begin/'; do
  i=$((i+1)); sed "$e" rtl/cluster.v > $OUT/m$i.v
  cmp -s rtl/cluster.v $OUT/m$i.v && { echo "bug $i: edit did not apply"; missed=1; continue; }
  rm -f $OUT/run$i/tb_*
  if OUT=$OUT/run$i CLUSTER=$OUT/m$i.v tests/run_cluster_tests.sh > $OUT/log$i 2>&1; then
    echo "bug $i MISSED"; missed=1
  else echo "bug $i caught: $(grep -E 'FAIL:|TIMEOUT' $OUT/log$i | head -2 | tr '\n' ' ')"; fi
done
exit $missed
