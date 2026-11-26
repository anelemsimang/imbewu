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
    // The multiply in two halves, so the version 5 cell can put a register
    // between them (D-027): mx_mul_s1 decodes and multiplies the 9-bit
    // signed significands, mx_mul_s2 shifts the products into place and adds
    // them. Together they give exactly the same p as before.
    wire signed [17:0] m0, m1;
    wire        [4:0]  sh0, sh1;
    mx_mul_s1 u_s1 (.fa(fa), .fb(fb), .a(a), .b(b), .ph(ph), .m0(m0), .sh0(sh0), .m1(m1), .sh1(sh1));
    mx_mul_s2 u_s2 (.m0(m0), .sh0(sh0), .m1(m1), .sh1(sh1), .p(p));
endmodule

// First half: decode both sides and multiply the signed significands.
// m0 x 2^sh0 (+ m1 x 2^sh1 when both sides are FP4) is the product x 2^18.
// Outside the both-FP4 case m1 and sh1 are zero.
module mx_mul_s1 (
    input  wire [1:0]         fa,
    input  wire [1:0]         fb,
    input  wire [7:0]         a,
    input  wire [7:0]         b,
    input  wire               ph,
    output wire signed [17:0] m0,
    output wire [4:0]         sh0,
    output wire signed [17:0] m1,
    output wire [4:0]         sh1
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

    wire both_fp4 = (fa == 2'd2) && (fb == 2'd2);
    wire [13:0] u0 = both_fp4 ? dec4(a[3:0]) : dec(fa, a, ph);
    wire [13:0] v0 = both_fp4 ? dec4(b[3:0]) : dec(fb, b, ph);
    wire [13:0] u1 = both_fp4 ? dec4(a[7:4]) : 14'd0;
    wire [13:0] v1 = both_fp4 ? dec4(b[7:4]) : 14'd0;
    // Significand sizes: INT8 -128..127, FP8 -15..15, FP4 -3..3, so the
    // first product is an 8 x 8 signed multiply (built as a tree, mul8s_csa)
    // and the second (both sides FP4) a 3 x 3 one (D-027).
    wire signed [15:0] p0;
    mul8s_csa u_m0 (.a(u0[12:5]), .b(v0[12:5]), .p(p0));
    assign m0  = p0;
    assign m1  = $signed(u1[7:5]) * $signed(v1[7:5]);
    assign sh0 = u0[4:0] + v0[4:0];     // at most 28 (FP8 14 + 14)
    assign sh1 = u1[4:0] + v1[4:0];
endmodule

// Second half: shift each product into place and add them.
module mx_mul_s2 (
    input  wire signed [17:0] m0,
    input  wire [4:0]         sh0,
    input  wire signed [17:0] m1,
    input  wire [4:0]         sh1,
    output wire signed [47:0] p
);
    wire signed [47:0] w0 = m0;
    wire signed [47:0] w1 = m1;
    assign p = (w0 <<< sh0) + (w1 <<< sh1);
endmodule

// 8 x 8 signed multiply as a tree (Wallace / carry-save): the 8 partial
// product rows (Baugh-Wooley form, so the signs need no extension) plus one
// row of constants are added three rows into two per level (each bit:
// sum = a ^ b ^ c, carry = majority, moved one place up), 9 -> 6 -> 4 -> 3
// -> 2 rows, then one carry-propagate add (built as a Kogge-Stone adder in
// the layout flow). Exact for all inputs (modulo 2^16, where the product
// fits); tests/tb_mx_mul_exhaustive.v checks every INT8 x INT8 pair.
module mul8s_csa (
    input  wire [7:0]         a,
    input  wire [7:0]         b,
    output wire signed [15:0] p
);
    reg [15:0] r [0:8];
    integer i, j;
    always @(*) begin
        for (i = 0; i < 8; i = i + 1) begin
            r[i] = 16'd0;
            for (j = 0; j < 8; j = j + 1)
                // Baugh-Wooley: invert the terms that mix one sign bit with
                // one ordinary bit
                r[i][i + j] = ((i == 7) ^ (j == 7)) ? ~(a[j] & b[i]) : (a[j] & b[i]);
        end
        r[8] = 16'h8100;            // 2^8 + 2^15: Baugh-Wooley correction
    end
    function [31:0] csa;            // {carry, sum} of three rows
        input [15:0] x, y, z;
        csa = {((x & y) | (x & z) | (y & z)) << 1, x ^ y ^ z};
    endfunction
    wire [31:0] l1a = csa(r[0], r[1], r[2]);
    wire [31:0] l1b = csa(r[3], r[4], r[5]);
    wire [31:0] l1c = csa(r[6], r[7], r[8]);
    wire [31:0] l2a = csa(l1a[15:0], l1a[31:16], l1b[15:0]);
    wire [31:0] l2b = csa(l1b[31:16], l1c[15:0], l1c[31:16]);
    wire [31:0] l3  = csa(l2a[15:0], l2a[31:16], l2b[15:0]);
    wire [31:0] l4  = csa(l3[15:0], l3[31:16], l2b[31:16]);
    assign p = l4[15:0] + l4[31:16];
endmodule
