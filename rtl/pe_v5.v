// pe_v5.v - version 5 processing element: same maths as version 4, smaller
//
// Version 4 gave every cell its own FP32 adder (three quarters of the cell)
// and did the multiply, the block sum and the FP32 add all in one tick.
// Version 5 (decision D-017):
//  * The multiply has its own ticks: two since D-027. Tick 1 decodes and
//    multiplies the significands (mx_mul_s1, stored in m0_r..sh1_r), tick 2
//    shifts and adds them into the product p_r (mx_mul_s2), and the block
//    total is updated from p_r one tick later.
//  * The cell has no FP32 adder. At the end of each block it sends a
//    request (its block total so far and its last product, which the adder
//    adds, the exponent e, and its FP32 total acc) to an
//    adder SHARED by a group of cells in the same row (systolic_v5.v). Seven
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
    output wire [7:0]         req_sel,    // 8 copies of req_v, for the adder's input select
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
    wire signed [17:0] m0, m1;
    wire        [4:0]  sh0, sh1;
    mx_mul_s1 u_mul1 (.fa(fa_in), .fb(fb_in), .a(a_in), .b(b_in), .ph(ph_in),
                      .m0(m0), .sh0(sh0), .m1(m1), .sh1(sh1));
    wire signed [10:0] e = $signed({3'd0, sa_in}) + $signed({3'd0, sb_in}) - 11'sd272
                         - ((fa_in == 2'd0) ? 11'sd6 : 11'sd0)
                         - ((fb_in == 2'd0) ? 11'sd6 : 11'sd0);

    // tick 1: the significand products and their tags
    reg signed [17:0] m0_r, m1_r;
    reg        [4:0]  sh0_r, sh1_r;
    reg signed [10:0] e_r1;
    reg               v_r1, be_r1, jl_r1;
    wire signed [47:0] p;
    mx_mul_s2 u_mul2 (.m0(m0_r), .sh0(sh0_r), .m1(m1_r), .sh1(sh1_r), .p(p));
    // tick 2: the product and its tags
    reg signed [47:0] p_r;
    reg signed [10:0] e_r;
    reg               v_r, be_r, jl_r;
    // tick 3: the exact block total
    reg signed [47:0] partial;
    reg        [31:0] acc;
    wire signed [47:0] x = partial + p_r;

    assign req_v   = v_r & be_r;
    // The adder's input select is steered by these copies of req_v, each
    // driving about one eighth of the ~140 request bits, instead of one
    // flip-flop driving all of them (first ASAP7 layout, D-027). keep: the
    // synthesis tool must not merge them back into one.
    (* keep *) reg [7:0] sel_r;
    assign req_sel = sel_r;
    assign req_jl  = jl_r;
    assign req_part = partial;
    assign req_p    = p_r;
    assign req_e   = e_r;
    assign req_acc = acc;

    always @(posedge clk) begin
        a_out  <= a_in;  fa_out <= fa_in; sa_out <= sa_in; ph_out <= ph_in;
        b_out  <= b_in;  fb_out <= fb_in; sb_out <= sb_in;
        m0_r   <= m0;  sh0_r <= sh0;  m1_r <= m1;  sh1_r <= sh1;
        e_r1   <= e;
        be_r1  <= bl_in | jl_in;
        jl_r1  <= jl_in;
        p_r    <= p;
        e_r    <= e_r1;
        be_r   <= be_r1;
        jl_r   <= jl_r1;
        if (rst) begin
            v_out <= 1'b0; bl_out <= 1'b0; jl_out <= 1'b0;
            v_r1 <= 1'b0; v_r <= 1'b0; sel_r <= 8'd0;
            partial <= 48'sd0;
            acc <= 32'd0;
            res <= 32'd0;
        end else begin
            v_out  <= v_in;
            bl_out <= bl_in;
            jl_out <= jl_in;
            v_r1   <= v_in;
            v_r    <= v_r1;
            sel_r  <= {8{v_r1 & be_r1}};     // equals v_r & be_r, one tick later
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
