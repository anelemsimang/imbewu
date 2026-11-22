#!/bin/bash
# Test the tests: plant one bug at a time in a copy of the design and check
# that the exhaustive cell test or the formal proof catches it.
# Usage: formal/mutants.sh      (run from the repo root, after make test-cell)
OUT=build/mutants; mkdir -p $OUT
# vectors needed by the checkers (independent Python references)
[ -f build/cell_exh.hex ] || python3 tools/gen_cell_exhaustive.py build/cell_exh.hex
[ -f build/mul_exh.hex ]  || python3 tools/gen_mul_exhaustive.py build/mul_exh.hex
[ -f build/fp32_stim.hex ] || python3 tools/fp32_ref.py build/fp32 200000
mkdir -p build/v4; [ -f build/v4/v4_N4_stress_exp.hex ] || python3 tools/gen_v4_vectors.py 4 build/v4
mkdir -p build/v5m; [ -f build/v5m/v4_N4_stress_exp.hex ] || python3 tools/gen_v4_vectors.py 4 build/v5m 60 6
V5="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v5.v rtl/systolic_v5.v"
v5sim() {   # 4x4 version 5 tests (adders shared by 4 cells) with one file replaced
    local files=$(echo $V5 | sed "s#$1#$2#")
    iverilog -g2012 -DGRID_N=4 -DV5 -DGROUP=4 -o $OUT/tb5 $files tests/tb_systolic_v4.v || return 1
    for sc in same mixed stress; do
        vvp -n $OUT/tb5 +PRE=build/v5m/v4_N4_$sc | grep -q '^PASS' || return 1
    done
}
V4="rtl/mx_mul.v rtl/fp32_add_fx.v rtl/pe_v4.v rtl/systolic_v4.v"
v4sim() {   # run the 4x4 version 4 tests with one file replaced
    local files=$(echo $V4 | sed "s#$1#$2#")
    iverilog -g2012 -DGRID_N=4 -o $OUT/tb4 $files tests/tb_systolic_v4.v || return 1
    for sc in same mixed stress; do
        vvp -n $OUT/tb4 +PRE=build/v4/v4_N4_$sc | grep -q '^PASS' || return 1
    done
}
caught=0; total=0
mutate() {   # file, description, sed expression, checker (cell|mul|fadd|v4|formal)
    local src=$1 desc=$2 expr=$3 kind=$4 m=$OUT/m.v
    sed "$expr" $src > $m
    if cmp -s $src $m; then echo "SETUP ERROR (no change): $desc"; exit 1; fi
    # the planted bug must still be valid Verilog, so a "catch" is a real catch
    yosys -q -p "read_verilog -DFORMAL $m" > /dev/null 2>&1 || { echo "SETUP ERROR (does not parse): $desc"; exit 1; }
    total=$((total+1))
    if [ $kind = cell ]; then
        iverilog -g2012 -o $OUT/tb $m tests/tb_pe_mx_exhaustive.v && \
          vvp -n $OUT/tb +EXP=build/cell_exh.hex | grep -q '^PASS' && r=missed || r=caught
    elif [ $kind = mul ]; then
        iverilog -g2012 -o $OUT/tb $m tests/tb_mx_mul_exhaustive.v && \
          vvp -n $OUT/tb +EXP=build/mul_exh.hex | grep -q '^PASS' && r=missed || r=caught
    elif [ $kind = fadd ]; then
        iverilog -g2012 -o $OUT/tb $m tests/tb_fp32_add.v && \
          vvp -n $OUT/tb +PRE=build/fp32 +COUNT=200000 | grep -q '^PASS' && r=missed || r=caught
    elif [ $kind = v4 ]; then
        v4sim $src $m && r=missed || r=caught
    elif [ $kind = v5 ]; then
        v5sim $src $m && r=missed || r=caught
    elif [ $kind = tile ]; then
        rm -rf $OUT/tile; OUT=$OUT/tile MM=$m tests/run_tile_tests.sh > /dev/null 2>&1 && r=missed || r=caught
    elif [ $kind = tilev1 ]; then
        rm -rf $OUT/tilev1; OUT=$OUT/tilev1 TILE=$m tests/run_tile_v1_tests.sh > /dev/null 2>&1 && r=missed || r=caught
    elif [ $kind = tilev2 ]; then
        rm -rf $OUT/tilev2; OUT=$OUT/tilev2 TILE=$m tests/run_tile_v2_tests.sh > /dev/null 2>&1 && r=missed || r=caught
    elif [ $kind = formalmm ]; then
        SYS=$m formal/run.sh 4 mm 4 > /dev/null 2>&1 && r=missed || r=caught
    elif [ $kind = formal5 ]; then
        SYS=$m formal/run.sh 4 v5 4 > /dev/null 2>&1 && r=missed || r=caught
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
echo "version 4 engine:"
M=rtl/mx_mul.v; F=rtl/fp32_add_fx.v; Q=rtl/pe_v4.v
mutate $M "mixed job: FP4 side reads the wrong half of its lane"  's/2'"'"'d2: dec = dec4(x\[3:0\]);/2'"'"'d2: dec = dec4(x[7:4]);/' mul
mutate $F "FP32 rounding: ties always rounded up"     's/(g \&\& (st || n_wide\[0\]))/(g)/' fadd
mutate $F "FP32 rounding: sticky bits ignored"        's/st = |(R \& ~({83{1'"'"'b1}} << (s - 1)));/st = 1'"'"'b0;/' fadd
mutate $F "FP32 overflow not turned into infinity"    's/biased >= 13'"'"'sd255/biased >= 13'"'"'sd256/' fadd
mutate $F "FP32 smallest step (subnormals) wrong"     's/s_min = -13'"'"'sd149 - B;/s_min = -13'"'"'sd148 - B;/' fadd
mutate $Q "MX INT8 factor missing on the B side"      '50s/11'"'"'sd6 : 11'"'"'sd0/11'"'"'sd0 : 11'"'"'sd0/' v4
mutate $Q "block total not cleared at block end"      '72s/partial <= 48'"'"'sd0;/partial <= x;/' v4
mutate $Q "FP32 total not cleared between jobs"       '75s/acc <= 32'"'"'d0;/acc <= acc;/' v4
echo "version 5 engine:"
P5=rtl/pe_v5.v; S5=rtl/systolic_v5.v
mutate $S5 "shared adder answers the wrong cell"            's/(p_who == j - J0)/(p_who == J1 - 1 - j)/' v5
mutate $P5 "block total not cleared at block end"            's/if (v_r) partial <= be_r ? 48'"'"'sd0 : x;/if (v_r) partial <= x;/' v5
mutate $P5 "FP32 total not cleared between jobs"             's/                    acc <= 32'"'"'d0;/                    acc <= wb_sum;/' v5
mutate $S5 "rows read out one tick too early"                's/localparam LAT = 6;/localparam LAT = 5;/' formal5
mutate $F "adder: larger and smaller swapped when subtracting" 's/end else if (al_a >= al_x) begin/end else if (al_a < al_x) begin/' fadd
mutate $S5 "adder requests not picked from the whole group"  's/for (c = J0; c < J1; c = c + 1)/for (c = J0; c < J1 - 1; c = c + 1)/' v5
echo "tiling controller:"
T=rtl/matmul_unit.v
mutate $T "block counter never advances (wrong scales)"     's/if (last_inblk) begin bib <= 0; blk <= blk + 1'"'"'b1; end/if (last_inblk) begin bib <= 0; blk <= blk; end/' tile
mutate $T "answers written to the wrong place"              's/c_addr <= (omt \* N + o_idx) \* cfg_nt + ont;/c_addr <= (omt * N + o_idx) + ont;/' tile
mutate $T "job end marked at every block end"               's/t_jl <= run \& last_beat;/t_jl <= run \& last_inblk;/' formalmm
mutate $T "skips every other row of tiles"                  's/begin nt <= 0; mt <= mt + 1'"'"'b1; end/begin nt <= 0; mt <= mt + 2'"'"'d2; end/' formalmm
echo "tile (Phase 2):"
TL=rtl/tile_v1.v
mutate $TL "data mover loads into the half the engine is using" 's/dhalf <= nld\[0\];/dhalf <= ~nld[0];/' tilev1
mutate $TL "next command loaded before its half is free"       's/wire can_load  = (nld < n_cmds) \&\& (nld < ncomp + 2);/wire can_load  = (nld < n_cmds) \&\& (nld < ncomp + 3);/' tilev1
mutate $TL "engine overwrites answers not yet sent back"       's/ncomp < nld \&\& ncomp < nst + 2/ncomp < nld \&\& ncomp < nst + 3/' tilev1
echo "tile version 2 (weights kept):"
T2=rtl/tile_v2.v
mutate $T2 "weights overwritten while an earlier command still needs them" 's/|| (ncomp > lu\[nslot\]);/|| 1'"'"'b1;/' tilev2
mutate $T2 "engine reads the other weight slot"                 's/comp_slot <= f_slot(cmds\[ncomp\[3:0\]\]);/comp_slot <= ~f_slot(cmds[ncomp[3:0]]);/' tilev2
mutate $T2 "weights written into the activation half"           's/ld_we_b <= 1'"'"'b1; ld_baddr <= {dslot,/ld_we_b <= 1'"'"'b1; ld_baddr <= {dhalf,/' tilev2
echo "mutants: $caught of $total planted bugs caught"
[ $caught = $total ]
