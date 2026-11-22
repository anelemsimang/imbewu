// pe_mx.v - Multi-format processing element (precision flexibility, goal G1)
//
// Plain language: the same cell can multiply numbers in three formats, and
// the format can change from one job to the next:
//   fmt 0  INT8      whole numbers -128..127            1 multiply per tick
//   fmt 1  FP8 E4M3  small floating-point, up to +/-448 1 multiply per tick
//   fmt 2  FP4 E2M1  tiny floating-point, up to +/-6    2 multiplies per tick
//                    (two FP4 numbers fit in each 8-bit lane)
//   fmt 3  reserved (treated as zero)
// FP8 and FP4 follow the OCP Microscaling (MX) v1.0 element definitions.
// The FP8 NaN code (S.1111.111) is not handled yet; see docs/RESULTS.md.
//
// How it works: every number is turned into a small whole number and a shift
// ("decoding"), multiplied on one shared multiplier, then shifted into a wide
// fixed-point total. The total's smallest step is 2^-18, the smallest product
// two FP8 numbers can make, so every product is added EXACTLY: no rounding.
//
// Total: signed 48 bits, value = acc * 2^-18 (before the MX block scale).
// Safe lengths: up to 2048 FP8 or 32768 INT8 multiplies per job.
module pe_mx (
    input  wire               clk,
    input  wire               rst,
    input  wire [7:0]         a_in,    // from the left neighbour
    input  wire [7:0]         b_in,    // from the neighbour above
    input  wire               v_in,    // valid tag
    input  wire               l_in,    // last tag
    input  wire [1:0]         f_in,    // format tag
    output reg  [7:0]         a_out,
    output reg  [7:0]         b_out,
    output reg                v_out,
    output reg                l_out,
    output reg  [1:0]         f_out,
    output reg  signed [47:0] res      // finished result of the latest job
);
    // Decode one number into a signed whole number and a left shift, so that
    // value = sig * 2^(sh - 9).
    function [13:0] dec;               // {sig[8:0] signed, sh[4:0]}
        input [1:0] fmt;
        input [7:0] x;
        reg   [3:0] mag;
        reg   [4:0] sh;
        reg   [3:0] n;
        begin
            case (fmt)
                2'd0: dec = {x[7], x, 5'd9};                         // INT8
                2'd1: begin                                          // FP8 E4M3
                    if (x[6:3] == 4'd0) begin mag = {1'b0, x[2:0]}; sh = 5'd0; end
                    else begin mag = {1'b1, x[2:0]}; sh = {1'b0, x[6:3]} - 5'd1; end
                    dec = {(x[7] ? -{5'd0, mag} : {5'd0, mag}), sh};
                end
                default: dec = 14'd0;
            endcase
        end
    endfunction

    // Decode one FP4 E2M1 number (4 bits): value = sig * 2^(sh - 9)
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

    wire [13:0] da  = dec(f_in, a_in);
    wire [13:0] db  = dec(f_in, b_in);
    wire [13:0] da0 = dec4(a_in[3:0]), da1 = dec4(a_in[7:4]);
    wire [13:0] db0 = dec4(b_in[3:0]), db1 = dec4(b_in[7:4]);

    // One product: (sig_a * sig_b) shifted into place (2^-18 steps)
    function signed [47:0] prod;
        input [13:0] p, q;
        reg signed [47:0] m;
        begin
            m    = $signed(p[13:5]) * $signed(q[13:5]);
            prod = m <<< (p[4:0] + q[4:0]);
        end
    endfunction

    wire signed [47:0] p_main = prod(da, db);
    wire signed [47:0] p_fp4  = prod(da0, db0) + prod(da1, db1);
    wire signed [47:0] p      = (f_in == 2'd2) ? p_fp4 :
                                (f_in == 2'd3) ? 48'sd0 : p_main;

    reg signed [47:0] acc;

    always @(posedge clk) begin
        a_out <= a_in;
        b_out <= b_in;
        f_out <= f_in;
        if (rst) begin
            acc   <= 48'sd0;
            res   <= 48'sd0;
            v_out <= 1'b0;
            l_out <= 1'b0;
        end else begin
            v_out <= v_in;
            l_out <= l_in;
            if (v_in) begin
                if (l_in) begin
                    res <= acc + p;
                    acc <= 48'sd0;
                end else begin
                    acc <= acc + p;
                end
            end
        end
    end
endmodule
