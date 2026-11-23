// systolic_v5.v - Streaming multi-format engine, version 5 (goals G1, G5)
//
// Same inputs, outputs and answers as version 4 (systolic_v4.v), but:
//  * Each row's cells are split into groups of G (default 16). Each group
//    shares ONE FP32 adder. This works because cells in a row reach the end
//    of a block one tick apart, so their requests arrive one after another.
//  * Short steps for a fast clock: each cell does its multiply in its own
//    tick (see pe_v5.v); the shared adder is a hand-off register and five
//    one-tick steps (S1a, S1b, S2, S3, S4 in fp32_add_fx.v).
// Output rows leave 6 ticks later than in version 4: row r appears
// N + 7 + r ticks after the job's last beat.
//
// Rules:
//  * every job has at least N beats (as before);
//  * every MX block has at least max(min(G, N), 6) beats (new): a shared
//    adder serves its cells one per tick, and a cell's new total takes 6
//    ticks to come back. A standard MX block of 32 numbers is 32 beats, or 16
//    beats when both sides are FP4, so standard blocks always qualify. A short final block (K not a
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
    input  wire              in_ph,      // FP4 side uses the high half of its lanes (D-020)
    input  wire [N*8-1:0]    a_col,
    input  wire [N*8-1:0]    b_row,
    input  wire [N*8-1:0]    in_a_scale,
    input  wire [N*8-1:0]    in_b_scale,
    output reg               out_valid,
    output reg  [IW-1:0]     out_row_idx,
    output reg  [N*32-1:0]   out_row
`ifdef FORMAL
    , output wire [N+5:0]    f_last_dly,     // N + LAT bits
    output wire              f_draining,
    output wire [IW-1:0]     f_rd_row,
    output wire [N*N-1:0]    f_req
`endif
);
    localparam IW  = $clog2(N) + 1;
    localparam GE  = (N < G) ? N : G;           // cells per adder
    localparam NG  = (N + GE - 1) / GE;         // adders per row
    localparam GW  = $clog2(GE) + 1;
    localparam LAT = 6;                         // extra ticks vs version 4
    localparam AW  = 8 + 2 + 8 + 3 + 1;     // a, fa, sa, {v, bl, jl}, ph
    localparam BW  = 8 + 2 + 8;

    wire job_last = in_valid & in_job_last;

    wire [AW-1:0] a_bus [0:N-1][0:N];
    wire [BW-1:0] b_bus [0:N][0:N-1];
    wire [N*N*32-1:0] res_flat;

    // request / answer wires of every cell
    wire        rq_v   [0:N-1][0:N-1];
    wire        rq_jl  [0:N-1][0:N-1];
    wire [47:0] rq_pt  [0:N-1][0:N-1];   // block total so far
    wire [47:0] rq_p   [0:N-1][0:N-1];   // last product
    wire [10:0] rq_e   [0:N-1][0:N-1];
    wire [31:0] rq_acc [0:N-1][0:N-1];
    wire        wb_v   [0:N-1][0:N-1];
    wire        wb_jl  [0:N-1][0:NG-1];
    wire [31:0] wb_sum [0:N-1][0:NG-1];

    genvar i, j, g;
    generate
        for (i = 0; i < N; i = i + 1) begin : skew
            wire [AW-1:0] a_new = {in_ph, a_col[i*8 +: 8], in_fa, in_a_scale[i*8 +: 8],
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
                wire vo, blo, jlo, pho;
                wire signed [47:0] qpt, qp;
                wire signed [10:0] qe;
                pe_v5 u_pe (
                    .clk(clk), .rst(rst),
                    .a_in(ai[20:13]), .fa_in(ai[12:11]), .sa_in(ai[10:3]),
                    .v_in(ai[2]), .bl_in(ai[1]), .jl_in(ai[0]), .ph_in(ai[21]),
                    .b_in(bi[17:10]), .fb_in(bi[9:8]), .sb_in(bi[7:0]),
                    .a_out(ao), .fa_out(fao), .sa_out(sao), .v_out(vo), .bl_out(blo), .jl_out(jlo),
                    .ph_out(pho),
                    .b_out(bo), .fb_out(fbo), .sb_out(sbo),
                    .req_v(rq_v[i][j]), .req_jl(rq_jl[i][j]), .req_part(qpt), .req_p(qp), .req_e(qe),
                    .req_acc(rq_acc[i][j]),
                    .wb_v(wb_v[i][j]), .wb_jl(wb_jl[i][j / GE]), .wb_sum(wb_sum[i][j / GE]),
                    .res(res));
                assign rq_pt[i][j] = qpt;
                assign rq_p[i][j]  = qp;
                assign rq_e[i][j] = qe;
                assign a_bus[i][j+1] = {pho, ao, fao, sao, vo, blo, jlo};
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
                reg [47:0] s_pt, s_p;
                wire [47:0] s_x = s_pt + s_p;   // pick first, then add: a short hand-off
                reg [10:0] s_e;
                reg [31:0] s_acc;
                reg [GW-1:0] s_who;
                integer c;
                always @(*) begin
                    s_v = 1'b0; s_jl = 1'b0; s_pt = 48'd0; s_p = 48'd0; s_e = 11'd0; s_acc = 32'd0; s_who = 0;
                    for (c = J0; c < J1; c = c + 1)
                        if (rq_v[i][c]) begin
                            s_v = 1'b1; s_jl = rq_jl[i][c]; s_pt = rq_pt[i][c]; s_p = rq_p[i][c];
                            s_e = rq_e[i][c]; s_acc = rq_acc[i][c]; s_who = c - J0;
                        end
                end
                // The shared adder: a hand-off register, then steps S1a, S1b,
                // S2, S3 and S4 (rtl/fp32_add_fx.v), one tick each. The new
                // total reaches the cell 5 ticks after the hand-off.
                reg               q0_v, q0_jl;
                reg        [47:0] q0_x;
                reg        [10:0] q0_e;
                reg        [31:0] q0_acc;
                reg     [GW-1:0]  q0_who;
                always @(posedge clk) begin
                    q0_v <= rst ? 1'b0 : s_v;
                    q0_jl <= s_jl; q0_x <= s_x; q0_e <= s_e; q0_acc <= s_acc; q0_who <= s_who;
                end
                wire               a_inf, a_sa, a_sx;
                wire        [23:0] a_ma;
                wire        [47:0] a_mx;
                wire signed [12:0] a_sha, a_shx, a_B;
                fp32_s1a_unpack u1a (.acc(q0_acc), .x(q0_x), .e(q0_e), .inf(a_inf), .s_a(a_sa),
                    .s_x(a_sx), .m_a(a_ma), .m_x(a_mx), .sh_a(a_sha), .sh_x(a_shx), .B(a_B));
                reg               q1_v, q1_jl, q1_inf, q1_is, q1_sa, q1_sx;
                reg        [23:0] q1_ma;
                reg        [47:0] q1_mx;
                reg signed [12:0] q1_sha, q1_shx, q1_B;
                reg     [GW-1:0]  q1_who;
                always @(posedge clk) begin
                    q1_v <= rst ? 1'b0 : q0_v;
                    q1_jl <= q0_jl; q1_inf <= a_inf; q1_is <= q0_acc[31]; q1_sa <= a_sa; q1_sx <= a_sx;
                    q1_ma <= a_ma; q1_mx <= a_mx; q1_sha <= a_sha; q1_shx <= a_shx; q1_B <= a_B;
                    q1_who <= q0_who;
                end
                wire [82:0] b_ala, b_alx;
                fp32_s1b_align u1b (.m_a(q1_ma), .m_x(q1_mx), .sh_a(q1_sha), .sh_x(q1_shx),
                                    .al_a(b_ala), .al_x(b_alx));
                reg               q2_v, q2_jl, q2_inf, q2_is, q2_sa, q2_sx;
                reg        [82:0] q2_ala, q2_alx;
                reg signed [12:0] q2_B;
                reg     [GW-1:0]  q2_who;
                always @(posedge clk) begin
                    q2_v <= rst ? 1'b0 : q1_v;
                    q2_jl <= q1_jl; q2_inf <= q1_inf; q2_is <= q1_is; q2_sa <= q1_sa; q2_sx <= q1_sx;
                    q2_ala <= b_ala; q2_alx <= b_alx; q2_B <= q1_B; q2_who <= q1_who;
                end
                wire        c_sr;
                wire [82:0] c_R;
                fp32_s2_add u2 (.s_a(q2_sa), .s_x(q2_sx), .al_a(q2_ala), .al_x(q2_alx), .s_r(c_sr), .R(c_R));
                reg               q3_v, q3_jl, q3_inf, q3_is, q3_sr;
                reg        [82:0] q3_R;
                reg signed [12:0] q3_B;
                reg     [GW-1:0]  q3_who;
                always @(posedge clk) begin
                    q3_v <= rst ? 1'b0 : q2_v;
                    q3_jl <= q2_jl; q3_inf <= q2_inf; q3_is <= q2_is; q3_sr <= c_sr;
                    q3_R <= c_R; q3_B <= q2_B; q3_who <= q2_who;
                end
                wire signed [7:0]  d_L;
                wire signed [12:0] d_lsb, d_s;
                fp32_s3_norm u3 (.R(q3_R), .B(q3_B), .L(d_L), .lsb(d_lsb), .s(d_s));
                reg               p_v, p_jl, q4_inf, q4_is, q4_sr;
                reg        [82:0] q4_R;
                reg signed [7:0]  q4_L;
                reg signed [12:0] q4_lsb, q4_s;
                reg     [GW-1:0]  p_who;
                always @(posedge clk) begin
                    p_v <= rst ? 1'b0 : q3_v;
                    p_jl <= q3_jl; q4_inf <= q3_inf; q4_is <= q3_is; q4_sr <= q3_sr;
                    q4_R <= q3_R; q4_L <= d_L; q4_lsb <= d_lsb; q4_s <= d_s; p_who <= q3_who;
                end
                fp32_s4_round u4 (.inf(q4_inf), .inf_sign(q4_is), .s_r(q4_sr), .R(q4_R), .L(q4_L),
                                  .lsb_in(q4_lsb), .s(q4_s), .sum(wb_sum[i][g]));
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
