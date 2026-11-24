#!/bin/sh
# Planted bugs in the cluster's arbiter and broadcast: each must make
# tests/run_mem_share_tests.sh or tests/run_cluster_tests.sh fail.
#  1 answers sent to the wrong tile
#  2 one more grant per tick than memory has channels
#  3 a tile may join a read issued before one it is already waiting on
#  4 a tile may join a read whose answer is arriving this very tick
#  5 joining compares addresses without their lowest bit
#  6 the cluster waits for switched-off tiles to finish (never ends)
#  7 a switched-off tile is not held in reset (it may still run)
OUT=build/mut_cl; mkdir -p $OUT; i=0; missed=0
for e in 's/if (e_mask\[p\]\[kk\]) begin/if (e_mask[p][(kk + 1) % T]) begin/' \
         's/if (t_req\[idx\] \&\& !joined \&\& g < B \&\&/if (t_req[idx] \&\& !joined \&\& g < B + 1 \&\&/' \
         's/ \&\& e_tick\[pe\] > last_t\[idx\]) begin/) begin/' \
         's/if (!joined \&\& w < cnt \&\& pos >= nret \&\&/if (!joined \&\& w < cnt \&\&/' \
         's/e_addr\[pe\] == t_addr\[EAW\*idx +: EAW\]/e_addr[pe][EAW-1:1] == t_addr[EAW*idx+1 +: EAW-1]/' \
         's/if ((finished | t_done | tile_off) == {T{1.b1}}) begin/if ((finished | t_done) == {T{1'"'"'b1}}) begin/' \
         's/.clk(clk), .rst(rst | tile_off\[i\]),/.clk(clk), .rst(rst),/'; do
  i=$((i+1)); sed "$e" rtl/cluster.v > $OUT/m$i.v
  cmp -s rtl/cluster.v $OUT/m$i.v && { echo "bug $i: edit did not apply"; missed=1; continue; }
  rm -rf $OUT/run$i $OUT/share$i
  # (CLUSTER first: the OUT given here must not change the path it reads)
  # the fast stress test first; the whole-cluster test only if it misses
  if CLUSTER=$OUT/m$i.v OUT=$OUT/share$i tests/run_mem_share_tests.sh > $OUT/log$i 2>&1 &&
     CLUSTER=$OUT/m$i.v OUT=$OUT/run$i tests/run_cluster_tests.sh >> $OUT/log$i 2>&1; then
    echo "bug $i MISSED"; missed=1
  elif grep -q '^FAIL: T=' $OUT/log$i; then
    echo "bug $i caught: $(grep -E '^FAIL:' $OUT/log$i | head -1)"
  else echo "bug $i: test did not run (see $OUT/log$i)"; missed=1; fi
done
exit $missed
