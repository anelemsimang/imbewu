// systolic_v5.v - Streaming multi-format engine, version 5 (goals G1, G5)
//
// Same inputs, outputs and answers as version 4 (systolic_v4.v), but:
//  * Each row's cells are split into groups of G (default 16). Each group
//    shares ONE FP32 adder, split over two ticks (fp32_align_add, then
//    fp32_round_pack). This works because cells in a row reach the end of a
//    block one tick apart, so their requests arrive one after another.
//  * Each cell does its multiply in its own tick (see pe_v5.v).
// Output rows leave 2 ticks later than in version 4: row r appears
// N + 3 + r ticks after the job's last beat.
//
// Rules:
//  * every job has at least N beats (as before);
//  * every MX block has at least min(G, N) beats (new). A standard MX block
//    of 32 numbers is 32 beats, or 16 beats when both sides are FP4, so with
//    G = 16 standard blocks always qualify. A short final block (K not a
//    multiple of 32) can be padded with zeros, which changes nothing.
// The formal proof (formal/fv_systolic_v5.v) shows that under these rules
// two cells never use the same adder in the same tick.
module systolic_v5 #(
    parameter N = 4,
    parameter G = 16
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              in_valid,
    input  wire              in_blk_last,
    input  wire              in_job_last,
    input  wire [1:0]        in_fa,
    input  wire [1:0]        in_fb,
    input  wire [N*8-1:0]    a_col,
    input  wire [N*8-1:0]    b_row,
    input  wire [N*8-1:0]    in_a_scale,
    input  wire [N*8-1:0]    in_b_scale,
    output reg               out_valid,
    output reg  [IW-1:0]     out_row_idx,
    output reg  [N*32-1:0]   out_row
`ifdef FORMAL
    , output wire [N+1:0]    f_last_dly,
    output wire              f_draining,
    output wire [IW-1:0]     f_rd_row,
    output wire [N*N-1:0]    f_req
`endif
);
    localparam IW  = $clog2(N) + 1;
    localparam GE  = (N < G) ? N : G;           // cells per adder
    localparam NG  = (N + GE - 1) / GE;         // adders per row
    localparam GW  = $clog2(GE) + 1;
    localparam LAT = 2;                         // extra ticks vs version 4
    localparam AW  = 8 + 2 + 8 + 3;
    localparam BW  = 8 + 2 + 8;

    wire job_last = in_valid & in_job_last;

    wire [AW-1:0] a_bus [0:N-1][0:N];
    wire [BW-1:0] b_bus [0:N][0:N-1];
    wire [N*N*32-1:0] res_flat;

    // request / answer wires of every cell
    wire        rq_v   [0:N-1][0:N-1];
    wire        rq_jl  [0:N-1][0:N-1];
    wire [47:0] rq_x   [0:N-1][0:N-1];
    wire [10:0] rq_e   [0:N-1][0:N-1];
    wire [31:0] rq_acc [0:N-1][0:N-1];
    wire        wb_v   [0:N-1][0:N-1];
    wire        wb_jl  [0:N-1][0:NG-1];
    wire [31:0] wb_sum [0:N-1][0:NG-1];

    genvar i, j, g;
    generate
        for (i = 0; i < N; i = i + 1) begin : skew
            wire [AW-1:0] a_new = {a_col[i*8 +: 8], in_fa, in_a_scale[i*8 +: 8],
                                   in_valid, in_valid & in_blk_last, job_last};
            wire [BW-1:0] b_new = {b_row[i*8 +: 8], in_fb, in_b_scale[i*8 +: 8]};
            if (i == 0) begin : direct
                assign a_bus[0][0] = a_new;
                assign b_bus[0][0] = b_new;
            end else begin : delayed
                reg [AW-1:0] ad [0:i-1];
                reg [BW-1:0] bd [0:i-1];
                integer m;
                always @(posedge clk) begin
                    ad[0] <= rst ? {AW{1'b0}} : a_new;
                    bd[0] <= b_new;
                    for (m = 1; m < i; m = m + 1) begin
                        ad[m] <= rst ? {AW{1'b0}} : ad[m-1];
                        bd[m] <= bd[m-1];
                    end
                end
                assign a_bus[i][0] = ad[i-1];
                assign b_bus[0][i] = bd[i-1];
            end
        end

        for (i = 0; i < N; i = i + 1) begin : row
            for (j = 0; j < N; j = j + 1) begin : col
                wire [AW-1:0] ai = a_bus[i][j];
                wire [BW-1:0] bi = b_bus[i][j];
                wire [31:0] res;
                wire [7:0] ao, bo, sao, sbo;
                wire [1:0] fao, fbo;
                wire vo, blo, jlo;
                wire signed [47:0] qx;
                wire signed [10:0] qe;
                pe_v5 u_pe (
                    .clk(clk), .rst(rst),
                    .a_in(ai[20:13]), .fa_in(ai[12:11]), .sa_in(ai[10:3]),
                    .v_in(ai[2]), .bl_in(ai[1]), .jl_in(ai[0]),
                    .b_in(bi[17:10]), .fb_in(bi[9:8]), .sb_in(bi[7:0]),
                    .a_out(ao), .fa_out(fao), .sa_out(sao), .v_out(vo), .bl_out(blo), .jl_out(jlo),
                    .b_out(bo), .fb_out(fbo), .sb_out(sbo),
                    .req_v(rq_v[i][j]), .req_jl(rq_jl[i][j]), .req_x(qx), .req_e(qe),
                    .req_acc(rq_acc[i][j]),
                    .wb_v(wb_v[i][j]), .wb_jl(wb_jl[i][j / GE]), .wb_sum(wb_sum[i][j / GE]),
                    .res(res));
                assign rq_x[i][j] = qx;
                assign rq_e[i][j] = qe;
                assign a_bus[i][j+1] = {ao, fao, sao, vo, blo, jlo};
                assign b_bus[i+1][j] = {bo, fbo, sbo};
                assign res_flat[(i*N+j)*32 +: 32] = res;
`ifdef FORMAL
                assign f_req[i*N+j] = rq_v[i][j];
`endif
            end

            // One shared, two-tick FP32 adder per group of GE cells
            for (g = 0; g < NG; g = g + 1) begin : grp
                localparam J0 = g * GE;
                localparam J1 = ((g + 1) * GE < N) ? (g + 1) * GE : N;
                // pick the requesting cell (at most one per tick, by the rules)
                reg        s_v, s_jl;
                reg [47:0] s_x;
                reg [10:0] s_e;
                reg [31:0] s_acc;
                reg [GW-1:0] s_who;
                integer c;
                always @(*) begin
                    s_v = 1'b0; s_jl = 1'b0; s_x = 48'd0; s_e = 11'd0; s_acc = 32'd0; s_who = 0;
                    for (c = J0; c < J1; c = c + 1)
                        if (rq_v[i][c]) begin
                            s_v = 1'b1; s_jl = rq_jl[i][c]; s_x = rq_x[i][c];
                            s_e = rq_e[i][c]; s_acc = rq_acc[i][c]; s_who = c - J0;
                        end
                end
                // half 1 of the adder, this tick
                wire               h_inf, h_sr;
                wire        [82:0] h_R;
                wire signed [12:0] h_B;
                fp32_align_add u_a (.acc(s_acc), .x(s_x), .e(s_e),
                                    .inf(h_inf), .s_r(h_sr), .R(h_R), .B(h_B));
                // pipeline register between the halves
                reg               p_v, p_jl, p_inf, p_sr;
                reg        [82:0] p_R;
                reg signed [12:0] p_B;
                reg        [31:0] p_acc;
                reg     [GW-1:0]  p_who;
                always @(posedge clk) begin
                    p_v   <= rst ? 1'b0 : s_v;
                    p_jl  <= s_jl;  p_inf <= h_inf; p_sr <= h_sr;
                    p_R   <= h_R;   p_B   <= h_B;   p_acc <= s_acc; p_who <= s_who;
                end
                // half 2 of the adder, next tick, and the answer back to the cell
                fp32_round_pack u_r (.inf(p_inf), .acc(p_acc), .s_r(p_sr), .R(p_R), .B(p_B),
                                     .sum(wb_sum[i][g]));
                assign wb_jl[i][g] = p_jl;
                for (j = J0; j < J1; j = j + 1) begin : back
                    assign wb_v[i][j] = p_v && (p_who == j - J0);
                end
            end
        end
    endgenerate

    // Read-out: as version 4, LAT ticks later
    reg [N+LAT-1:0] last_dly;
    reg [IW-1:0]    rd_row;
    reg             draining;
`ifdef FORMAL
    assign f_last_dly = last_dly;
    assign f_draining = draining;
    assign f_rd_row   = rd_row;
`endif

    always @(posedge clk) begin
        if (rst) begin
            last_dly  <= {(N+LAT){1'b0}};
            draining  <= 1'b0;
            rd_row    <= {IW{1'b0}};
            out_valid <= 1'b0;
        end else begin
            last_dly <= {last_dly[N+LAT-2:0], job_last};
            if (last_dly[N+LAT-1]) begin
                out_row     <= res_flat[0 +: N*32];
                out_row_idx <= {IW{1'b0}};
                out_valid   <= 1'b1;
                rd_row      <= 1;
                draining    <= (N > 1);
            end else if (draining) begin
                out_row     <= res_flat[rd_row*N*32 +: N*32];
                out_row_idx <= rd_row;
                out_valid   <= 1'b1;
                rd_row      <= rd_row + 1'b1;
                draining    <= (rd_row != N-1);
            end else begin
                out_valid   <= 1'b0;
            end
        end
    end
endmodule
