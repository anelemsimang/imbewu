// systolic_v5.v - Streaming multi-format engine, version 5 (goals G1, G5)
//
// Same inputs, outputs and answers as version 4 (systolic_v4.v), but:
//  * Each row's cells are split into groups of G (default 16). Each group
//    shares ONE FP32 adder. This works because cells in a row reach the end
//    of a block one tick apart, so their requests arrive one after another.
//  * Short steps for a fast clock: each cell does its multiply in two ticks
//    of its own (see pe_v5.v; two since D-027, when the SKY130 layout showed
//    the one-tick multiply was the slowest path); the shared adder is a hand-off register and six
//    one-tick steps (S1a, S1b, S2, S3, S4a, S4b in fp32_add_fx.v). S4 was
//    one tick until the second SKY130 layout showed it was the slowest
//    path (docs/RESULTS.md 2026-11-26).
// Output rows leave 8 ticks later than in version 4: row r appears
// N + 9 + r ticks after the job's last beat.
//
// Rules:
//  * every job has at least N beats (as before);
//  * every MX block has at least max(min(G, N), 7) beats (new): a shared
//    adder serves its cells one per tick, and a cell's new total takes 7
//    ticks to come back. A standard MX block of 32 numbers is 32 beats, or 16
//    beats when both sides are FP4, so standard blocks always qualify. A short final block (K not a
//    multiple of 32) can be padded with zeros, which changes nothing.
// The formal proof (formal/fv_systolic_v5.v) shows that under these rules
// two cells never use the same adder in the same tick.
module systolic_v5 #(
    parameter N = 4,
    parameter G = 16,
    parameter DRAIN = 0       // 1: results handed down the columns (D-031)
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
    output wire              out_valid,
    output wire [IW-1:0]     out_row_idx,
    output wire [N*32-1:0]   out_row
`ifdef FORMAL
    , output wire [N+7:0]    f_last_dly,     // N + LAT bits
    output wire              f_draining,
    output wire [IW-1:0]     f_rd_row,
    output wire [N*N-1:0]    f_req
`endif
);
    localparam IW  = $clog2(N) + 1;
    localparam GE  = (N < G) ? N : G;           // cells per adder
    localparam NG  = (N + GE - 1) / GE;         // adders per row
    localparam GW  = $clog2(GE) + 1;
    localparam LAT = 8;                         // extra ticks vs version 4
    localparam AW  = 8 + 2 + 8 + 3 + 1;     // a, fa, sa, {v, bl, jl}, ph
    localparam BW  = 8 + 2 + 8;

    wire job_last = in_valid & in_job_last;

    wire [AW-1:0] a_bus [0:N-1][0:N];
    wire [BW-1:0] b_bus [0:N][0:N-1];
    wire [N*N*32-1:0] res_flat;
    // DRAIN = 1: results go down each column, one block per tick (D-031)
    wire [N*32-1:0] dr [0:N];         // into row i (row N: out of the last row)
    wire            cap [0:N][0:NG-1], inj [0:N][0:NG-1];
    wire            cap0;             // row 0 reads its results (as the mux read-out)
    reg             inj0;
    assign dr[0] = {(N*32){1'b0}};

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
            // groups of GE cells, each with its shared adder (v5_grp below):
            // the unit laid out once and repeated (D-031)
            for (g = 0; g < NG; g = g + 1) begin : grp
                localparam J0 = g * GE;
                localparam J1 = ((g + 1) * GE < N) ? (g + 1) * GE : N;
                wire [(J1-J0)*BW-1:0] bi, bo;
                wire [(J1-J0)*32-1:0] rs;
                for (j = J0; j < J1; j = j + 1) begin : bw
                    assign bi[(j-J0)*BW +: BW] = b_bus[i][j];
                    assign b_bus[i+1][j] = bo[(j-J0)*BW +: BW];
                end
                if (i == 0) begin : top
                    assign cap[0][g] = cap0;
                    assign inj[0][g] = inj0;
                end
                if (DRAIN) begin : blk
                    // the laid-out block (v5_blk: no result outputs)
                    v5_blk #(.GE(J1 - J0)) u_blk (
                        .clk(clk), .rst(rst), .a_in(a_bus[i][J0]), .a_out(a_bus[i][J1]),
                        .b_in(bi), .b_out(bo),
                        .cap_in(cap[i][g]), .cap_out(cap[i+1][g]), .inj_in(inj[i][g]), .inj_out(inj[i+1][g]),
                        .dr_in(dr[i][J0*32 +: (J1-J0)*32]), .dr_out(dr[i+1][J0*32 +: (J1-J0)*32])
`ifdef FORMAL
                        , .f_req(f_req[i*N+J0 +: J1-J0])
`endif
                    );
                    assign rs = {((J1-J0)*32){1'b0}};      // the mux read-out is not used
                end else begin : grp
                    v5_grp #(.GE(J1 - J0)) u_grp (
                        .clk(clk), .rst(rst), .a_in(a_bus[i][J0]), .a_out(a_bus[i][J1]),
                        .b_in(bi), .b_out(bo), .res(rs),
                        .cap_in(1'b0), .cap_out(), .inj_in(1'b0), .inj_out(),
                        .dr_in({((J1-J0)*32){1'b0}}), .dr_out()
`ifdef FORMAL
                        , .f_req(f_req[i*N+J0 +: J1-J0])
`endif
                    );
                end
                assign res_flat[(i*N+J0)*32 +: (J1-J0)*32] = rs;
            end
        end
    endgenerate

    // Read-out: as version 4, LAT ticks later
    reg             m_valid;
    reg [IW-1:0]    m_idx;
    reg [N*32-1:0]  m_row;
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
            m_valid <= 1'b0;
        end else begin
            last_dly <= {last_dly[N+LAT-2:0], job_last};
            if (last_dly[N+LAT-1]) begin
                m_row       <= res_flat[0 +: N*32];
                m_idx       <= {IW{1'b0}};
                m_valid     <= 1'b1;
                rd_row      <= 1;
                draining    <= (N > 1);
            end else if (draining) begin
                m_row       <= res_flat[rd_row*N*32 +: N*32];
                m_idx       <= rd_row;
                m_valid     <= 1'b1;
                rd_row      <= rd_row + 1'b1;
                draining    <= (rd_row != N-1);
            end else begin
                m_valid     <= 1'b0;
            end
        end
    end

    // DRAIN = 1: each block keeps its results when the mux read-out would
    // read its row (cap, one row per tick), and puts them on the column's
    // hand-down register two ticks per row later (inj). Row r reaches the
    // bottom N ticks after the mux read-out would give it; valid and row
    // number are delayed to match. Every wire is between neighbouring blocks.
    assign cap0 = last_dly[N+LAT-1];
    always @(posedge clk) inj0 <= rst ? 1'b0 : cap0;
    generate
        if (DRAIN) begin : drain
            reg [N-1:0]  v_d;
            reg [IW-1:0] i_d [0:N-1];
            integer m;
            always @(posedge clk) begin
                v_d <= rst ? {N{1'b0}} : {v_d[N-2:0], m_valid};
                i_d[0] <= m_idx;
                for (m = 1; m < N; m = m + 1) i_d[m] <= i_d[m-1];
            end
            assign out_valid = v_d[N-1];
            assign out_row_idx = i_d[N-1];
            assign out_row = dr[N];
        end else begin : mux
            assign out_valid = m_valid;
            assign out_row_idx = m_idx;
            assign out_row = m_row;
        end
    endgenerate
endmodule


// v5_grp - one group of GE cells of a row and the FP32 adder they share
// (D-031). systolic_v5 is N rows of N / G of these. Kept as a module of its
// own so the layout can be made once and repeated (step 3 of D-026): the
// group's only connections are the a lane passing through it left to right,
// the GE b lanes passing top to bottom, and the GE results.
module v5_grp #(
    parameter GE = 16,                // cells in this group
    parameter DRAIN = 0,              // 1: hand results down the column (D-031)
    parameter AW = 8 + 2 + 8 + 3 + 1, // lane widths as systolic_v5 (not to be changed)
    parameter BW = 8 + 2 + 8
) (
    input  wire              clk,
    input  wire              rst,
    input  wire [AW-1:0]     a_in,
    output wire [AW-1:0]     a_out,
    input  wire [GE*BW-1:0]  b_in,
    output wire [GE*BW-1:0]  b_out,
    output wire [GE*32-1:0]  res,
    // result hand-down (DRAIN = 1; unused otherwise)
    input  wire              cap_in,     // keep this group's results now
    output wire              cap_out,    // to the group below, one tick later
    input  wire              inj_in,     // put them on the hand-down register now
    output wire              inj_out,    // to the group below, two ticks later
    input  wire [GE*32-1:0]  dr_in,      // from the group above
    output wire [GE*32-1:0]  dr_out      // to the group below
`ifdef FORMAL
    , output wire [GE-1:0]   f_req
`endif
);
    localparam GW = $clog2(GE) + 1;
    localparam J0 = 0, J1 = GE;

    wire [AW-1:0] a_bus [0:GE];
    assign a_bus[0] = a_in;
    assign a_out = a_bus[GE];

    // request / answer wires of every cell
    wire        rq_v   [0:GE-1];
    wire        rq_jl  [0:GE-1];
    wire [47:0] rq_x   [0:GE-1];   // block total so far + last product
    wire [10:0] rq_e   [0:GE-1];
    wire [31:0] rq_acc [0:GE-1];
    wire        wb_v   [0:GE-1];
    wire        wb_jl;
    wire [31:0] wb_sum;

    genvar j;
    generate
        for (j = 0; j < GE; j = j + 1) begin : col
            wire [AW-1:0] ai = a_bus[j];
            wire [BW-1:0] bi = b_in[j*BW +: BW];
            wire [31:0] rs;
            wire [7:0] ao, bo, sao, sbo;
            wire [1:0] fao, fbo;
            wire vo, blo, jlo, pho;
            wire signed [47:0] qx;
            wire signed [10:0] qe;
            pe_v5 u_pe (
                .clk(clk), .rst(rst),
                .a_in(ai[20:13]), .fa_in(ai[12:11]), .sa_in(ai[10:3]),
                .v_in(ai[2]), .bl_in(ai[1]), .jl_in(ai[0]), .ph_in(ai[21]),
                .b_in(bi[17:10]), .fb_in(bi[9:8]), .sb_in(bi[7:0]),
                .a_out(ao), .fa_out(fao), .sa_out(sao), .v_out(vo), .bl_out(blo), .jl_out(jlo),
                .ph_out(pho),
                .b_out(bo), .fb_out(fbo), .sb_out(sbo),
                .req_v(rq_v[j]), .req_jl(rq_jl[j]), .req_x(qx), .req_e(qe),
                .req_acc(rq_acc[j]),
                .wb_v(wb_v[j]), .wb_jl(wb_jl), .wb_sum(wb_sum),
                .res(rs));
            assign rq_x[j] = qx;
            assign rq_e[j] = qe;
            assign a_bus[j+1] = {pho, ao, fao, sao, vo, blo, jlo};
            assign b_out[j*BW +: BW] = {bo, fbo, sbo};
            assign res[j*32 +: 32] = rs;
`ifdef FORMAL
            assign f_req[j] = rq_v[j];
`endif
        end
    endgenerate

    // The shared, two-tick FP32 adder of the group
    // pick the requesting cell. At most one asks per tick (the
    // rules; proven in formal/fv_systolic_v5.v), so the pick is a
    // plain AND-OR: each cell's words are gated by its own
    // request, then OR-ed (D-027).
    reg        s_v, s_jl;
    reg [47:0] s_x;
    reg [10:0] s_e;
    reg [31:0] s_acc;
    reg [GW-1:0] s_who;
    integer c;
    always @(*) begin
        s_v = 1'b0; s_jl = 1'b0; s_x = 48'd0; s_e = 11'd0; s_acc = 32'd0; s_who = 0;
        for (c = J0; c < J1; c = c + 1) begin
            s_v   = s_v   | rq_v[c];
            s_x   = s_x   | ({48{rq_v[c]}} & rq_x[c]);
            s_acc = s_acc | ({32{rq_v[c]}} & rq_acc[c]);
            s_e   = s_e   | ({11{rq_v[c]}} & rq_e[c]);
            s_jl  = s_jl  | (rq_v[c] & rq_jl[c]);
            s_who = s_who | ({GW{rq_v[c]}} & (c - J0));
        end
    end
    // The shared adder: a hand-off register, then steps S1a, S1b,
    // S2, S3, S4a and S4b (rtl/fp32_add_fx.v), one tick each. The
    // new total reaches the cell 6 ticks after the hand-off.
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
    // S4 in two halves with a register between them: S4a shifts,
    // S4b rounds, packs and hands the new total back to its cell
    wire [24:0] e_n0;
    wire        e_g, e_st;
    fp32_s4a_shift u4a (.R(q4_R), .s(q4_s), .n0(e_n0), .g(e_g), .st(e_st));
    reg               q5_v, q5_jl, q5_inf, q5_is, q5_sr, q5_g, q5_st;
    reg        [24:0] q5_n0;
    reg signed [7:0]  q5_L;
    reg signed [12:0] q5_lsb;
    reg     [GW-1:0]  q5_who;
    always @(posedge clk) begin
        q5_v <= rst ? 1'b0 : p_v;
        q5_jl <= p_jl; q5_inf <= q4_inf; q5_is <= q4_is; q5_sr <= q4_sr;
        q5_n0 <= e_n0; q5_g <= e_g; q5_st <= e_st; q5_L <= q4_L; q5_lsb <= q4_lsb;
        q5_who <= p_who;
    end
    wire [31:0] q5_sum;
    fp32_s4b_pack u4b (.inf(q5_inf), .inf_sign(q5_is), .s_r(q5_sr), .n0(q5_n0),
                       .g(q5_g), .st(q5_st), .L(q5_L), .lsb_in(q5_lsb), .sum(q5_sum));
    assign wb_sum = q5_sum;
    assign wb_jl = q5_jl;
    generate
        if (DRAIN) begin : drain
            reg             cap_q;
            reg [1:0]       inj_q;
            reg [GE*32-1:0] hold, dr;
            always @(posedge clk) begin
                cap_q <= rst ? 1'b0 : cap_in;
                inj_q <= rst ? 2'b0 : {inj_q[0], inj_in};
                if (cap_in) hold <= res;
                dr <= inj_in ? hold : dr_in;
            end
            assign cap_out = cap_q;
            assign inj_out = inj_q[1];
            assign dr_out  = dr;
        end else begin : nodrain
            assign cap_out = 1'b0;
            assign inj_out = 1'b0;
            assign dr_out  = {(GE*32){1'b0}};
        end
        for (j = J0; j < J1; j = j + 1) begin : back
            assign wb_v[j] = q5_v && (q5_who == j - J0);
        end
    endgenerate
endmodule

// v5_blk - the block laid out once and repeated for the hand-down engine
// (systolic_v5 with DRAIN = 1, D-031): v5_grp without its result outputs,
// which only the mux read-out uses. Its edges: a lane in on the left and out
// on the right; b lanes, hand-down results, cap and inj in at the top and
// out at the bottom.
module v5_blk #(
    parameter GE = 16,
    parameter AW = 8 + 2 + 8 + 3 + 1,
    parameter BW = 8 + 2 + 8
) (
    input  wire              clk,
    input  wire              rst,
    input  wire [AW-1:0]     a_in,
    output wire [AW-1:0]     a_out,
    input  wire [GE*BW-1:0]  b_in,
    output wire [GE*BW-1:0]  b_out,
    input  wire              cap_in,
    output wire              cap_out,
    input  wire              inj_in,
    output wire              inj_out,
    input  wire [GE*32-1:0]  dr_in,
    output wire [GE*32-1:0]  dr_out
`ifdef FORMAL
    , output wire [GE-1:0]   f_req
`endif
);
    wire [GE*32-1:0] res;
    v5_grp #(.GE(GE), .DRAIN(1)) u (
        .clk(clk), .rst(rst), .a_in(a_in), .a_out(a_out), .b_in(b_in), .b_out(b_out), .res(res),
        .cap_in(cap_in), .cap_out(cap_out), .inj_in(inj_in), .inj_out(inj_out),
        .dr_in(dr_in), .dr_out(dr_out)
`ifdef FORMAL
        , .f_req(f_req)
`endif
    );
endmodule
