// pe_v5.v - version 5 processing element: same maths as version 4, smaller
//
// Version 4 gave every cell its own FP32 adder (three quarters of the cell)
// and did the multiply, the block sum and the FP32 add all in one tick.
// Version 5 (decision D-017):
//  * The multiply has its own tick: the product is stored in p_r, and the
//    block total is updated from it one tick later.
//  * The cell has no FP32 adder. At the end of each block it sends a
//    request (its block total so far and its last product, which the adder
//    adds, the exponent e, and its FP32 total acc) to an
//    adder SHARED by a group of cells in the same row (systolic_v5.v). Six
//    ticks later the adder sends the new total back (wb_*).
// Results are bit-for-bit the same as version 4.
module pe_v5 (
    input  wire               clk,
    input  wire               rst,
    input  wire [7:0]         a_in,
    input  wire [1:0]         fa_in,
    input  wire [7:0]         sa_in,
    input  wire               v_in,
    input  wire               bl_in,
    input  wire               jl_in,
    input  wire               ph_in,      // FP4 side: use the high half of its lane (D-020)
    input  wire [7:0]         b_in,
    input  wire [1:0]         fb_in,
    input  wire [7:0]         sb_in,
    output reg  [7:0]         a_out,
    output reg  [1:0]         fa_out,
    output reg  [7:0]         sa_out,
    output reg                v_out,
    output reg                bl_out,
    output reg                jl_out,
    output reg                ph_out,
    output reg  [7:0]         b_out,
    output reg  [1:0]         fb_out,
    output reg  [7:0]         sb_out,
    // request to the shared FP32 adder
    output wire               req_v,
    output wire               req_jl,
    output wire signed [47:0] req_part,   // block total so far (the adder adds req_p)
    output wire signed [47:0] req_p,      // this tick's product
    output wire signed [10:0] req_e,
    output wire [31:0]        req_acc,
    // answer from the shared FP32 adder
    input  wire               wb_v,
    input  wire               wb_jl,
    input  wire [31:0]        wb_sum,
    output reg  [31:0]        res       // FP32 result of the latest finished job
);
    wire signed [47:0] p;
    mx_mul u_mul (.fa(fa_in), .fb(fb_in), .a(a_in), .b(b_in), .ph(ph_in), .p(p));
    wire signed [10:0] e = $signed({3'd0, sa_in}) + $signed({3'd0, sb_in}) - 11'sd272
                         - ((fa_in == 2'd0) ? 11'sd6 : 11'sd0)
                         - ((fb_in == 2'd0) ? 11'sd6 : 11'sd0);

    // tick 1: the product and its tags
    reg signed [47:0] p_r;
    reg signed [10:0] e_r;
    reg               v_r, be_r, jl_r;
    // tick 2: the exact block total
    reg signed [47:0] partial;
    reg        [31:0] acc;
    wire signed [47:0] x = partial + p_r;

    assign req_v   = v_r & be_r;
    assign req_jl  = jl_r;
    assign req_part = partial;
    assign req_p    = p_r;
    assign req_e   = e_r;
    assign req_acc = acc;

    always @(posedge clk) begin
        a_out  <= a_in;  fa_out <= fa_in; sa_out <= sa_in; ph_out <= ph_in;
        b_out  <= b_in;  fb_out <= fb_in; sb_out <= sb_in;
        p_r    <= p;
        e_r    <= e;
        be_r   <= bl_in | jl_in;
        jl_r   <= jl_in;
        if (rst) begin
            v_out <= 1'b0; bl_out <= 1'b0; jl_out <= 1'b0;
            v_r <= 1'b0;
            partial <= 48'sd0;
            acc <= 32'd0;
            res <= 32'd0;
        end else begin
            v_out  <= v_in;
            bl_out <= bl_in;
            jl_out <= jl_in;
            v_r    <= v_in;
            if (v_r) partial <= be_r ? 48'sd0 : x;
            if (wb_v) begin
                if (wb_jl) begin
                    res <= wb_sum;
                    acc <= 32'd0;
                end else begin
                    acc <= wb_sum;
                end
            end
        end
    end
endmodule
