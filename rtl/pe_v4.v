// pe_v4.v - version 4 processing element: sums many MX blocks inside the cell
//
// What changed from version 3 (pe_mx.v), and why (decisions D-015, D-016):
//  * Each side has its own format (fa travels with a, fb with b), so FP4
//    weights can be multiplied by FP8 activations.
//  * A job is now a whole row-times-column (any length K), made of many MX
//    blocks. Inside a block the cell adds exactly, as before. At the end of
//    each block it scales that exact total by the block's two shared scales
//    (sa travels with a, sb with b) and adds it into an FP32 running total,
//    rounding once (fp32_add_fx.v). So the output is a normal FP32 number.
//  * Jobs no longer have to be one block long, which is what wasted half the
//    engine's time on FP4 in grids larger than 16x16.
//
// Tags on the a side: v (valid), bl (last beat of a block), jl (last beat of
// the job; also ends a block).
module pe_v4 (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  a_in,
    input  wire [1:0]  fa_in,
    input  wire [7:0]  sa_in,
    input  wire        v_in,
    input  wire        bl_in,
    input  wire        jl_in,
    input  wire [7:0]  b_in,
    input  wire [1:0]  fb_in,
    input  wire [7:0]  sb_in,
    output reg  [7:0]  a_out,
    output reg  [1:0]  fa_out,
    output reg  [7:0]  sa_out,
    output reg         v_out,
    output reg         bl_out,
    output reg         jl_out,
    output reg  [7:0]  b_out,
    output reg  [1:0]  fb_out,
    output reg  [7:0]  sb_out,
    output reg  [31:0] res          // FP32 result of the latest finished job
);
    wire signed [47:0] p;
    mx_mul u_mul (.fa(fa_in), .fb(fb_in), .a(a_in), .b(b_in), .p(p));

    reg  signed [47:0] partial;     // exact total of the current block, units 2^-18
    reg         [31:0] acc;         // FP32 total of the finished blocks
    wire signed [47:0] x = partial + p;

    // block exponent: scales (E8M0, bias 127 each), the 2^-18 unit, and the
    // MX INT8 factor 2^-6 for each INT8 side
    wire signed [10:0] e = $signed({3'd0, sa_in}) + $signed({3'd0, sb_in}) - 11'sd272
                         - ((fa_in == 2'd0) ? 11'sd6 : 11'sd0)
                         - ((fb_in == 2'd0) ? 11'sd6 : 11'sd0);
    wire [31:0] acc_next;
    fp32_add_fx u_add (.acc(acc), .x(x), .e(e), .sum(acc_next));

    wire block_end = bl_in | jl_in;

    always @(posedge clk) begin
        a_out  <= a_in;  fa_out <= fa_in; sa_out <= sa_in;
        b_out  <= b_in;  fb_out <= fb_in; sb_out <= sb_in;
        if (rst) begin
            partial <= 48'sd0;
            acc     <= 32'd0;
            res     <= 32'd0;
            v_out   <= 1'b0;
            bl_out  <= 1'b0;
            jl_out  <= 1'b0;
        end else begin
            v_out  <= v_in;
            bl_out <= bl_in;
            jl_out <= jl_in;
            if (v_in) begin
                if (block_end) begin
                    partial <= 48'sd0;
                    if (jl_in) begin
                        res <= acc_next;
                        acc <= 32'd0;
                    end else begin
                        acc <= acc_next;
                    end
                end else begin
                    partial <= x;
                end
            end
        end
    end
endmodule
