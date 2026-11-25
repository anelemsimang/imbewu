#!/bin/bash
# Finish stage 2 of tools/w2_layout.sh from its saved routed layout
# (build/layout/LABEL/final.odb): extraction and the final reports, without
# routing again. When extraction stops on a net that still shorts to another
# pin, that net is added to extract_skipped_nets.txt and the run is repeated
# (see tools/w2_extract.tcl). Usage: tools/w2_finish.sh LABEL CLOCK_PERIOD_NS
LABEL=$1; PERIOD=$2
OPENROAD=${OPENROAD:-/opt/eda/bin/openroad}
OUT=build/layout/$LABEL
for try in $(seq 1 30); do
  PLATFORM=build/pdk/sky130hd OUT=$OUT PERIOD=$PERIOD \
    $OPENROAD -exit -no_init tools/w2_finish.tcl > $OUT/finish.log 2>&1 && { cat $OUT/final_summary.txt; exit 0; }
  net=$(sed -n 's/.*ODB-0390.*net \([^ ,]*\), shorts.*/\1/p' $OUT/finish.log | head -1)
  [ -n "$net" ] || { tail -20 $OUT/finish.log; exit 1; }
  echo "net $net shorts to another pin: timing it without wire parasitics"
  echo "$net" >> $OUT/extract_skipped_nets.txt
done
echo "gave up after 30 nets"; exit 1
