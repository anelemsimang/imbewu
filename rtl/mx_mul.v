// mx_mul.v - one multi-format multiply, exact (used by the version 4 cell)
//
// Each side has its own format, so mixed jobs work (e.g. FP4 weights times
// FP8 activations, decision D-015):
//   fmt 0 INT8   fmt 1 FP8 E4M3   fmt 2 FP4 E2M1   fmt 3 reserved (zero)
// When BOTH sides are FP4, each 8-bit lane holds two numbers and two products
// are summed (2 multiplies per tick). In every other case one product is made
// per tick, and an FP4 side uses half of its lane: the low 4 bits, or the
// high 4 bits when ph = 1. (So two FP4 weights can share one byte in memory
// and be used on two ticks in a row: decision D-020.)
//
// Output p: signed whole number, value = p * 2^-18 (exact). INT8 elements
// count as whole numbers here; the MX INT8 factor 2^-6 is applied with the
// block scale (see fp32_add_fx / pe_v4).
module mx_mul (
    input  wire [1:0]         fa,
    input  wire [1:0]         fb,
    input  wire [7:0]         a,
    input  wire [7:0]         b,
    input  wire               ph,       // FP4 side: use the high half of the lane
    output wire signed [47:0] p
);
    // value = sig * 2^(sh - 9)
    function [13:0] dec4;
        input [3:0] n;
        reg   [3:0] mag;
        reg   [4:0] sh;
        begin
            if (n[2:1] == 2'd0) begin mag = {3'd0, n[0]}; sh = 5'd8; end
            else begin mag = {2'd0, 1'b1, n[0]}; sh = {3'd0, n[2:1]} + 5'd7; end
            dec4 = {(n[3] ? -{5'd0, mag} : {5'd0, mag}), sh};
        end
    endfunction

    function [13:0] dec;
        input [1:0] fmt;
        input [7:0] x;
        input       hi;
        reg   [3:0] mag;
        reg   [4:0] sh;
        begin
            case (fmt)
                2'd0: dec = {x[7], x, 5'd9};
                2'd1: begin
                    if (x[6:3] == 4'd0) begin mag = {1'b0, x[2:0]}; sh = 5'd0; end
                    else begin mag = {1'b1, x[2:0]}; sh = {1'b0, x[6:3]} - 5'd1; end
                    dec = {(x[7] ? -{5'd0, mag} : {5'd0, mag}), sh};
                end
                2'd2: dec = dec4(hi ? x[7:4] : x[3:0]);
                default: dec = 14'd0;
            endcase
        end
    endfunction

    function signed [47:0] prod;
        input [13:0] u, v;
        reg signed [47:0] m;
        begin
            m    = $signed(u[13:5]) * $signed(v[13:5]);
            prod = m <<< (u[4:0] + v[4:0]);
        end
    endfunction

    wire both_fp4 = (fa == 2'd2) && (fb == 2'd2);
    assign p = both_fp4 ? prod(dec4(a[3:0]), dec4(b[3:0])) + prod(dec4(a[7:4]), dec4(b[7:4]))
                        : prod(dec(fa, a, ph), dec(fb, b, ph));
endmodule
