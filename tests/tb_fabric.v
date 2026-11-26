// tb_fabric.v - the chip's memory system end to end (D-030): tiles, two
// meshes (requests, answers), HBM controllers with DRAM models on the left
// and right edges, shared on-chip memory blocks inside.
// Settings: -DMX=6 -DMY=4   plusargs: +PAT=<0..4> +SEED=<n> +NREQ=<per tile> +OUTS=<n>
//   PAT 0: each tile streams reads through HBM (consecutive words; words
//          spread over all channels)
//   PAT 1: random HBM reads          PAT 2: random HBM reads and writes (30%)
//   PAT 3: random on-chip memory reads and writes (30%)
//   PAT 4: half streaming HBM reads, half on-chip memory reads
// Node kinds: x = 0 or x = X-1: HBM controller; inside, (x + y) % 3 == 0:
// on-chip memory block; else a tile (a traffic generator here, checking
// every answer). Each tile reads and writes only its own part of every
// memory, so the expected data is known: the last earlier write, or the
// starting value (memories start as mem[i] = i).
`timescale 1ns/1ps
module tb_fabric;
`ifndef MX
`define MX 6
`endif
`ifndef MY
`define MY 4
`endif
    localparam X = `MX, Y = `MY, NN = X * Y;
    localparam XW = 3, YW = 3, TW = 8, AW = 15, DW = 64, D = 4;
    localparam PW = 1 + XW + YW + TW + AW + DW, FW = XW + YW + PW;
    localparam CB = 5, BB = 4, RB = 6, SAW = 12, T_BL = 2;
    localparam NMC = 2 * Y;
    reg clk = 0, rst = 1;
    always #1 clk = ~clk;

    function integer kind;      // 0 tile, 1 HBM controller, 2 on-chip memory
        input integer n;
        integer x, y;
        begin
            x = n % X; y = n / X;
            kind = (x == 0 || x == X - 1) ? 1 : (((x + y) % 3 == 0) ? 2 : 0);
        end
    endfunction

    // two meshes
    wire [NN-1:0]    q_in_v, q_in_c, q_out_v, q_out_c;     // requests
    wire [NN*FW-1:0] q_in_f, q_out_f;
    wire [NN-1:0]    a_in_v, a_in_c, a_out_v, a_out_c;     // answers
    wire [NN*FW-1:0] a_in_f, a_out_f;
    noc_mesh #(.X(X), .Y(Y), .XW(XW), .YW(YW), .PW(PW), .D(D)) reqnet (.clk(clk), .rst(rst),
        .loc_in_v(q_in_v), .loc_in_flit(q_in_f), .loc_in_credit(q_in_c),
        .loc_out_v(q_out_v), .loc_out_flit(q_out_f), .loc_out_credit(q_out_c));
    noc_mesh #(.X(X), .Y(Y), .XW(XW), .YW(YW), .PW(PW), .D(D)) ansnet (.clk(clk), .rst(rst),
        .loc_in_v(a_in_v), .loc_in_flit(a_in_f), .loc_in_credit(a_in_c),
        .loc_out_v(a_out_v), .loc_out_flit(a_out_f), .loc_out_credit(a_out_c));

    // tile side, driven by the traffic loop below
    reg  [NN-1:0]    t_q_v = 0, t_a_c = 0;
    reg  [NN*FW-1:0] t_q_f = 0;
    wire [31:0] mc_col [0:NN-1];
    wire [31:0] sr_acc [0:NN-1];
    integer dram_err [0:NN-1];

    genvar n;
    generate
        for (n = 0; n < NN; n = n + 1) begin : node
            if (kind(n) == 1) begin : mc
                wire d_act, d_pre, d_ref, d_rd, d_wr, d_rvalid;
                wire [BB-1:0] d_rbank, d_cbank;
                wire [RB-1:0] d_row;
                wire [CB-1:0] d_col;
                wire [DW-1:0] d_wdata, d_rdata;
                wire [31:0] n_act, n_ref;
                mc_node #(.XW(XW), .YW(YW), .TW(TW), .AW(AW), .DW(DW), .D(D), .CB(CB), .BB(BB), .RB(RB)) u (
                    .clk(clk), .rst(rst),
                    .in_v(q_out_v[n]), .in_flit(q_out_f[n*FW +: FW]), .in_credit(q_out_c[n]),
                    .out_v(a_in_v[n]), .out_flit(a_in_f[n*FW +: FW]), .out_credit(a_in_c[n]),
                    .d_act(d_act), .d_pre(d_pre), .d_ref(d_ref), .d_rd(d_rd), .d_wr(d_wr),
                    .d_rbank(d_rbank), .d_cbank(d_cbank), .d_row(d_row), .d_col(d_col), .d_wdata(d_wdata),
                    .d_rvalid(d_rvalid), .d_rdata(d_rdata), .n_col(mc_col[n]), .n_act(n_act), .n_ref(n_ref));
                hbm_dram_model #(.DW(DW), .CB(CB), .BB(BB), .RB(RB), .NAME("HBM")) dram (.clk(clk), .rst(rst),
                    .d_act(d_act), .d_pre(d_pre), .d_ref(d_ref), .d_rd(d_rd), .d_wr(d_wr),
                    .d_rbank(d_rbank), .d_cbank(d_cbank), .d_row(d_row), .d_col(d_col), .d_wdata(d_wdata),
                    .d_rvalid(d_rvalid), .d_rdata(d_rdata));
                always @(*) dram_err[n] = dram.errors;
                assign q_in_v[n] = 1'b0; assign q_in_f[n*FW +: FW] = 0;
                assign a_out_c[n] = 1'b0;
                assign sr_acc[n] = 0;
            end else if (kind(n) == 2) begin : sr
                sram_node #(.XW(XW), .YW(YW), .TW(TW), .AW(AW), .DW(DW), .D(D), .SAW(SAW)) u (
                    .clk(clk), .rst(rst),
                    .in_v(q_out_v[n]), .in_flit(q_out_f[n*FW +: FW]), .in_credit(q_out_c[n]),
                    .out_v(a_in_v[n]), .out_flit(a_in_f[n*FW +: FW]), .out_credit(a_in_c[n]),
                    .n_acc(sr_acc[n]));
                initial dram_err[n] = 0;
                assign q_in_v[n] = 1'b0; assign q_in_f[n*FW +: FW] = 0;
                assign a_out_c[n] = 1'b0;
                assign mc_col[n] = 0;
            end else begin : tile
                assign q_in_v[n] = t_q_v[n]; assign q_in_f[n*FW +: FW] = t_q_f[n*FW +: FW];
                assign a_out_c[n] = t_a_c[n];
                assign q_out_c[n] = 1'b0;            // tiles receive no requests
                assign a_in_v[n] = 1'b0; assign a_in_f[n*FW +: FW] = 0;
                assign mc_col[n] = 0; assign sr_acc[n] = 0;
                initial dram_err[n] = 0;
            end
        end
    endgenerate

    // ---------------- traffic and checking ----------------
    integer pat, seed, nreq, outs, t, i, m, errors, done_all, t0, sent_tot, got_tot, lat_sum;
    integer nt, ns, ti, tn [0:NN-1], mcn [0:NN-1], srn [0:NN-1], tile_ix [0:NN-1];
    integer cred [0:NN-1], sent [0:NN-1], got [0:NN-1], outst [0:NN-1];
    reg [DW-1:0] sh_mc [0:NMC*32768-1];
    reg [DW-1:0] sh_sr [0:16*4096-1];
    reg          ex_v  [0:NN*256-1];
    reg          ex_we [0:NN*256-1];
    reg [DW-1:0] ex_d  [0:NN*256-1];
    integer      ex_t  [0:NN*256-1];
    reg [FW-1:0] f;
    integer a, tgt, loc, we, tg, dx, dy, src_x, src_y, ch, hbm, last_got, last_t;

    task bad; input [8*48-1:0] what; begin
        errors = errors + 1;
        if (errors < 8) $display("ERROR tick %0d: %0s", t, what);
    end endtask

    initial begin
        if (!$value$plusargs("PAT=%d", pat)) pat = 0;
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("NREQ=%d", nreq)) nreq = 1000;
        if (!$value$plusargs("OUTS=%d", outs)) outs = 64;
        m = $urandom(seed);
        nt = 0; ns = 0; ch = 0;
        for (i = 0; i < NN; i = i + 1) begin
            cred[i] = D; sent[i] = 0; got[i] = 0; outst[i] = 0;
            if (kind(i) == 0) begin tn[nt] = i; tile_ix[i] = nt; nt = nt + 1; end
            if (kind(i) == 1) begin mcn[ch] = i; ch = ch + 1; end
            if (kind(i) == 2) begin srn[ns] = i; ns = ns + 1; end
        end
        for (i = 0; i < NMC * 32768; i = i + 1) sh_mc[i] = i % 32768;
        for (i = 0; i < 16 * 4096; i = i + 1) sh_sr[i] = i % 4096;
        for (i = 0; i < NN * 256; i = i + 1) ex_v[i] = 0;
        errors = 0; sent_tot = 0; got_tot = 0; lat_sum = 0; last_got = 0; last_t = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        t0 = 0;
        for (t = 0; t < 400 * nreq + 50000; t = t + 1) begin
            @(negedge clk);
            // answers arriving at tiles
            t_a_c = 0;
            for (ti = 0; ti < nt; ti = ti + 1) begin
                i = tn[ti];
                if (a_out_v[i]) begin
                    f = a_out_f[i*FW +: FW];
                    dx = f[FW-1 -: XW]; dy = f[FW-XW-1 -: YW];
                    tg = f[DW + AW +: TW];
                    if (dx != i % X || dy != i / X) bad("answer at the wrong tile");
                    else if (!ex_v[i*256 + tg]) bad("answer with an unknown tag");
                    else begin
                        if (f[PW-1] != ex_we[i*256 + tg]) bad("answer of the wrong kind");
                        else if (!f[PW-1] && f[DW-1:0] !== ex_d[i*256 + tg]) bad("read data wrong");
                        ex_v[i*256 + tg] = 0; got[i] = got[i] + 1; outst[i] = outst[i] - 1;
                        got_tot = got_tot + 1; lat_sum = lat_sum + (t - ex_t[i*256 + tg]);
                    end
                    t_a_c[i] = 1'b1;
                end
                if (q_in_c[i]) cred[i] = cred[i] + 1;
            end
            // new requests
            t_q_v = 0;
            for (ti = 0; ti < nt; ti = ti + 1) begin
                i = tn[ti];
                if (sent[i] < nreq && cred[i] > 0 && outst[i] < outs && !ex_v[i*256 + sent[i] % 256]) begin
                    we = 0;
                    case (pat)
                        0: begin hbm = 1; a = sent[i]; end
                        1: begin hbm = 1; a = $urandom % 2048 * NMC + $urandom % NMC; end
                        2: begin hbm = 1; a = $urandom % 64 * NMC + $urandom % NMC; we = ($urandom % 100) < 30; end
                        3: begin hbm = 0; a = $urandom % 256 * ns + $urandom % ns; we = ($urandom % 100) < 30; end
                        default: begin hbm = sent[i] % 2; a = hbm ? sent[i] / 2 : (sent[i] / 2) % (256 * ns); end
                    endcase
                    if (hbm) begin
                        tgt = mcn[a % NMC]; loc = tile_ix[i] * 2048 + (a / NMC) % 2048;
                    end else begin
                        tgt = srn[a % ns]; loc = tile_ix[i] * 256 + (a / ns) % 256;
                    end
                    tg = sent[i] % 256;
                    f = 0;
                    f[FW-1 -: XW] = tgt % X; f[FW-XW-1 -: YW] = tgt / X;
                    f[PW-1] = we; f[PW-2 -: XW] = i % X; f[PW-2-XW -: YW] = i / X;
                    f[DW + AW +: TW] = tg; f[DW +: AW] = loc;
                    f[DW-1:0] = {$urandom, $urandom};
                    ex_v[i*256 + tg] = 1; ex_we[i*256 + tg] = we; ex_t[i*256 + tg] = t;
                    if (hbm) begin
                        ex_d[i*256 + tg] = sh_mc[(a % NMC) * 32768 + loc];
                        if (we) sh_mc[(a % NMC) * 32768 + loc] = f[DW-1:0];
                    end else begin
                        ex_d[i*256 + tg] = sh_sr[(a % ns) * 4096 + loc];
                        if (we) sh_sr[(a % ns) * 4096 + loc] = f[DW-1:0];
                    end
                    t_q_f[i*FW +: FW] = f; t_q_v[i] = 1'b1;
                    cred[i] = cred[i] - 1; sent[i] = sent[i] + 1; outst[i] = outst[i] + 1;
                    sent_tot = sent_tot + 1;
                end
            end
            done_all = (got_tot == nt * nreq);
            if (done_all) t = 400 * nreq + 50000;
            if (got_tot != last_got) begin last_got = got_tot; last_t = t; end
            if (t - last_t > 3000) begin
                bad("memory system stopped: nothing answered for 3000 ticks");
                t = 400 * nreq + 50000;
            end
        end
        for (i = 0; i < NN; i = i + 1) errors = errors + dram_err[i];
        if (got_tot != nt * nreq) begin
            errors = errors + 1; $display("ERROR %0d requests, %0d answered", nt * nreq, got_tot);
        end
        a = 0; for (i = 0; i < NN; i = i + 1) a = a + mc_col[i];
        $display("FABRIC %0dx%0d pattern %0d: %0d tiles, %0d HBM channels, %0d memory blocks; %0d requests, %0d errors",
                 X, Y, pat, nt, NMC, ns, got_tot, errors);
        $display("FABRIC   %0d ticks: %0.2f words per tick delivered (%0.2f per tile), HBM data buses %0.1f%% busy, answer time %0.1f ticks",
                 t_end(0), got_tot * 1.0 / t_end(0), got_tot * 1.0 / t_end(0) / nt,
                 100.0 * a * T_BL / t_end(0) / NMC, lat_sum * 1.0 / (got_tot > 0 ? got_tot : 1));
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
    // ticks used (the loop counter is moved to its end when all is answered)
    integer t_last = 0;
    always @(posedge clk) if (!rst && got_tot < nt * nreq) t_last <= t_last + 1;
    function integer t_end; input integer dummy; t_end = (t_last > 0) ? t_last : 1; endfunction
endmodule
