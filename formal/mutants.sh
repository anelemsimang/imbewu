#!/bin/bash
# Test the tests: plant one bug at a time in a copy of the design and check
# that the exhaustive cell test or the formal proof catches it.
# Usage: formal/mutants.sh      (run from the repo root, after make test-cell)
OUT=build/mutants; mkdir -p $OUT
caught=0; total=0
mutate() {   # file, description, sed expression, checker (cell|formal)
    local src=$1 desc=$2 expr=$3 kind=$4 m=$OUT/m.v
    sed "$expr" $src > $m
    if cmp -s $src $m; then echo "SETUP ERROR (no change): $desc"; exit 1; fi
    total=$((total+1))
    if [ $kind = cell ]; then
        iverilog -g2012 -o $OUT/tb $m tests/tb_pe_mx_exhaustive.v && \
          vvp -n $OUT/tb +EXP=build/cell_exh.hex | grep -q '^PASS' && r=missed || r=caught
    else
        SYS=$m formal/run.sh 4 > /dev/null 2>&1 && r=missed || r=caught
    fi
    [ $r = caught ] && caught=$((caught+1))
    echo "  $r: $desc"
}
P=rtl/pe_mx.v; S=rtl/systolic_mx.v
mutate $P "INT8 decoded with the wrong shift"        's/5'"'"'d9}; /5'"'"'d8}; /' cell
mutate $P "FP8 subnormals given the wrong shift"     's/sh = 5'"'"'d0; end/sh = 5'"'"'d1; end/' cell
mutate $P "FP4 subnormals given the wrong shift"     's/sh = 5'"'"'d8; end/sh = 5'"'"'d7; end/' cell
mutate $P "FP4 high nibble ignored"                  's/prod(da0, db0) + prod(da1, db1)/prod(da0, db0)/' cell
mutate $P "sign of FP8 numbers ignored"              's/(x\[7\] ? -{5'"'"'d0, mag} : {5'"'"'d0, mag})/{5'"'"'d0, mag}/' cell
mutate $S "read pointer for scales never moves"      's/rd_slot     <= ~rd_slot;/rd_slot     <= rd_slot;/' formal
mutate $S "last row of each job dropped"             's/draining    <= (rd_row != N-1);/draining    <= (rd_row != N-2);/' formal
mutate $S "output exponent off by one"               's/10'"'"'d272/10'"'"'d271/' formal
mutate $S "first row uses the previous job's scales" 's/row_exp(sa_slot\[rd_slot\], sb_slot\[rd_slot\], 0)/row_exp(sa_slot[cur_slot], sb_slot[cur_slot], 0)/' formal
mutate $S "row number not advanced"                  's/rd_row      <= rd_row + 1'"'"'b1;/rd_row      <= rd_row;/' formal
echo "mutants: $caught of $total planted bugs caught"
[ $caught = $total ]
