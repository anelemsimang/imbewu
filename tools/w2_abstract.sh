#!/bin/bash
# Block abstract and timing models for every corner (tools/w2_abstract.tcl).
# Usage: [PDK=asap7] tools/w2_abstract.sh LABEL     (a finished block layout)
set -e
export PDK=${PDK:-asap7}
OPENROAD=${OPENROAD:-/opt/eda/bin/openroad}
export PLATFORM=build/pdk/$PDK OUT=build/layout/$1
[ $PDK = asap7 ] && CORNERS="TT SS FF" || CORNERS="tt ss_100C_1v60 ff_n40C_1v95"
for c in $CORNERS; do
  CORNER=$c $OPENROAD -exit -no_init tools/w2_abstract.tcl > $OUT/abstract_$c.log 2>&1 \
    || { tail -20 $OUT/abstract_$c.log; exit 1; }
  grep "model written" $OUT/abstract_$c.log
done
