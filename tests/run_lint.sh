#!/bin/sh
# Lint (Verilator) of the current designs. Fails on serious findings:
# latches built by accident, signals driven from two places, missing or
# misconnected parts, and errors. Other warnings (mostly deliberate width
# changes and test-only signals) are counted, not fatal; each width
# narrowing in the current designs was checked by hand (docs/RESULTS.md).
OUT=build/lint; mkdir -p $OUT; bad=0
ENG="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v rtl/matmul_unit.v rtl/sram.v"
for job in "tile_v4:$ENG rtl/fp32_ops.v rtl/vu_v2.v rtl/mx_quant.v rtl/tile_v4.v" \
           "cluster:$ENG rtl/tile_v3.v rtl/cluster.v" \
           "vu_v1:rtl/fp32_add_fx.v rtl/fp32_ops.v rtl/vu_v1.v" \
           "mx_quant:rtl/mx_quant.v"; do
  top=${job%%:*}; files=${job#*:}
  verilator --lint-only -Wall -Wno-fatal -Irtl --top-module $top $files > $OUT/$top.log 2>&1
  serious=$(grep -cE '^%(Error|Warning-(LATCH|MULTIDRIVEN|PINMISSING|PINNOTFOUND|UNDRIVEN|IMPLICIT|COMBDLY))' $OUT/$top.log)
  echo "lint $top: $(grep -c '^%Warning' $OUT/$top.log) warnings, $serious serious"
  [ "$serious" = 0 ] || { grep -E '^%(Error|Warning-(LATCH|MULTIDRIVEN|PINMISSING|PINNOTFOUND|UNDRIVEN|IMPLICIT|COMBDLY))' $OUT/$top.log | head; bad=1; }
done
[ $bad = 0 ] && echo "lint: no serious findings" || { echo "lint: FAIL"; exit 1; }
