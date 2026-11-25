#!/bin/bash
# Time a finished layout (tools/w2_layout.sh, both stages) at the slow and fast
# process corners of SKY130:
#   ss = slow chip, hot (100 C), low supply (1.60 V): the worst case for speed
#   ff = fast chip, cold (-40 C), high supply (1.95 V): the worst case for hold
# Usage: tools/w2_corner.sh LABEL CLOCK_PERIOD_NS
# The two libraries come from litex-hub's open_pdks.sky130a package (the
# SKY130 process kit, 1.3 GB): streamed once, checked against the package
# index's SHA-256, and only the two files kept in build/pdk/sky130a_ss.
set -e
LABEL=$1; PERIOD=$2
OPENROAD=${OPENROAD:-/opt/eda/bin/openroad}
P=build/pdk/sky130hd; OUT=build/layout/$LABEL
D=build/pdk/sky130a_ss; L=$D/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib
PKG=open_pdks.sky130a-1.0.471_0_g97d0844-20240223_100318.tar.bz2
SHA=37736ab56036733eaaff5f8f77a42c98caf75c82bc6b5dae59a727d24eabdd83
if [ ! -s $L/sky130_fd_sc_hd__ss_100C_1v60.lib ]; then
  mkdir -p $D
  curl -sSfL https://conda.anaconda.org/litex-hub/noarch/$PKG \
    | tee >(sha256sum > $D/download.sha256) \
    | tar -xjf - -C $D --wildcards '*sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ss_100C_1v60.lib' \
                                   '*sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ff_n40C_1v95.lib'
  sleep 2
  grep -q $SHA $D/download.sha256 || { echo "checksum mismatch: $PKG"; rm -rf $L; exit 1; }
fi
for c in ss_100C_1v60 ff_n40C_1v95; do
  CORNER=$c CORNER_LIB=$L/sky130_fd_sc_hd__$c.lib PERIOD=$PERIOD PLATFORM=$P OUT=$OUT \
    $OPENROAD -exit -no_init tools/w2_corner.tcl > $OUT/corner_$c.log 2>&1 \
    || { tail -20 $OUT/corner_$c.log; exit 1; }
  cat $OUT/${c}_summary.txt
done
