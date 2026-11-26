// tb_hbm.v - rtl/hbm_ctrl.v against a DRAM model that checks every timing
// rule, with a scoreboard for the data.
// plusargs: +PAT=<0..3> +SEED=<n> +NREQ=<n> +RATE=<percent>
//   PAT 0: streaming reads (consecutive words: mostly row hits)
//   PAT 1: random reads over the whole channel (mostly row misses)
//   PAT 2: random reads and writes (30%) over a few rows (same-word hazards)
//   PAT 3: streaming writes, then streaming reads of the same words
// Checks: every DRAM timing rule (tests/hbm_dram_model.v), data bus never used
// twice at once, refresh never overdue, every request answered exactly
// once, read data equal to the last earlier write. Prints the share of the
// data bus used (100% = the channel's peak bandwidth), row-hit rate and
// average answer time.
`timescale 1ns/1ps
module tb_hbm;
    localparam DW = 64, TW = 16, CB = 5, BB = 4, RB = 6, AW = RB + BB + CB;
    localparam Q = 16;
    // HBM3-like timing in ticks of a ~1.2 GHz clock (as hbm_ctrl defaults)
    localparam T_RCD = 17, T_RP = 17, T_RAS = 40, T_CL = 17, T_WL = 6, T_BL = 2,
               T_CCDS = 2, T_CCDL = 3, T_RRDS = 3, T_RRDL = 4, T_FAW = 20,
               T_RTP = 6, T_WR = 20, T_WTR = 10, T_RTW = 4, T_REFI = 4680, T_RFC = 420;
    reg clk = 0, rst = 1;
    always #1 clk = ~clk;

    reg              rq_v = 0, rq_we = 0;
    reg  [AW-1:0]    rq_addr = 0;
    reg  [TW-1:0]    rq_tag = 0;
    reg  [DW-1:0]    rq_wdata = 0;
    wire             rq_credit, rs_v, rs_we;
    wire [TW-1:0]    rs_tag;
    wire [DW-1:0]    rs_rdata;
    reg              rs_credit = 0;
    wire             d_act, d_pre, d_ref, d_rd, d_wr;
    wire [BB-1:0]    d_rbank, d_cbank;
    wire [RB-1:0]    d_row;
    wire [CB-1:0]    d_col;
    wire [DW-1:0]    d_wdata;
    wire             d_rvalid;
    wire [DW-1:0]    d_rdata;
    wire [31:0]      n_hit, n_act, n_ref;
    hbm_ctrl #(.DW(DW), .TW(TW), .CB(CB), .BB(BB), .RB(RB), .Q(Q)) dut (
        .clk(clk), .rst(rst), .rq_v(rq_v), .rq_we(rq_we), .rq_addr(rq_addr), .rq_tag(rq_tag),
        .rq_wdata(rq_wdata), .rq_credit(rq_credit), .rs_v(rs_v), .rs_we(rs_we), .rs_tag(rs_tag),
        .rs_rdata(rs_rdata), .rs_credit(rs_credit),
        .d_act(d_act), .d_pre(d_pre), .d_ref(d_ref), .d_rbank(d_rbank), .d_row(d_row),
        .d_rd(d_rd), .d_wr(d_wr), .d_cbank(d_cbank), .d_col(d_col), .d_wdata(d_wdata),
        .d_rvalid(d_rvalid), .d_rdata(d_rdata), .n_hit(n_hit), .n_act(n_act), .n_ref(n_ref));

    hbm_dram_model #(.DW(DW), .CB(CB), .BB(BB), .RB(RB)) dram (.clk(clk), .rst(rst),
        .d_act(d_act), .d_pre(d_pre), .d_ref(d_ref), .d_rd(d_rd), .d_wr(d_wr),
        .d_rbank(d_rbank), .d_cbank(d_cbank), .d_row(d_row), .d_col(d_col), .d_wdata(d_wdata),
        .d_rvalid(d_rvalid), .d_rdata(d_rdata));
    integer now, errors;
    task bad; input [8*48-1:0] what; begin
        errors = errors + 1;
        if (errors < 8) $display("ERROR tick %0d: %0s", now, what);
    end endtask
    integer k;

    // ---------------- traffic and scoreboard ----------------
    integer pat, seed, nreq, rate, sent, got, cred, t0, lat_sum, i, m;
    reg [DW-1:0] shadow [0:(1<<AW)-1];
    reg [DW-1:0] exp_d [0:1023];
    reg          exp_we [0:1023], outst [0:1023];
    integer      t_sent [0:1023];
    reg [AW-1:0] a;
    reg          we;
    always @(posedge clk) now <= rst ? 0 : now + 1;

    initial begin
        if (!$value$plusargs("PAT=%d", pat)) pat = 0;
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("NREQ=%d", nreq)) nreq = 4000;
        if (!$value$plusargs("RATE=%d", rate)) rate = 100;
        m = $urandom(seed);
        errors = 0; now = 0;
        for (i = 0; i < (1 << AW); i = i + 1) shadow[i] = i;
        for (i = 0; i < 1024; i = i + 1) outst[i] = 0;
        sent = 0; got = 0; cred = Q; lat_sum = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        t0 = now;
        while (got < nreq && now < 400 * nreq + 20000) begin
            @(negedge clk);
            // answers
            rs_credit = 0;
            if (rs_v) begin
                if (!outst[rs_tag % 1024]) bad("answer with an unknown tag");
                else begin
                    if (rs_we != exp_we[rs_tag % 1024]) bad("answer of the wrong kind");
                    if (!rs_we && rs_rdata !== exp_d[rs_tag % 1024]) bad("read data wrong");
                    outst[rs_tag % 1024] = 0; got = got + 1;
                    lat_sum = lat_sum + (now - t_sent[rs_tag % 1024]);
                end
                rs_credit = 1;
            end
            if (rq_credit) cred = cred + 1;
            // requests
            rq_v = 0;
            if (sent < nreq && cred > 0 && ($urandom % 100) < rate) begin
                case (pat)
                    0: begin a = sent; we = 0; end
                    1: begin a = $urandom; we = 0; end
                    2: begin a = (($urandom % 4) << (BB + CB)) | (($urandom % 16) << 2) | ($urandom % 4);
                       we = ($urandom % 100) < 30; end
                    default: begin a = sent % (nreq / 2); we = (sent < nreq / 2); end
                endcase
                rq_v = 1; rq_we = we; rq_addr = a; rq_tag = sent; rq_wdata = {$urandom, $urandom};
                exp_we[sent % 1024] = we; exp_d[sent % 1024] = shadow[a]; outst[sent % 1024] = 1;
                t_sent[sent % 1024] = now;
                if (we) shadow[a] = rq_wdata;
                sent = sent + 1; cred = cred - 1;
            end
        end
        errors = errors + dram.errors;
        if (got != nreq) begin
            errors = errors + 1; $display("ERROR %0d requests, %0d answered", nreq, got);
        end
        $display("HBM pattern %0d: %0d requests, %0d errors; data bus busy %0.1f%% of %0d ticks, row hits %0.1f%%, %0d refreshes, answer time %0.1f ticks",
                 pat, nreq, errors, 100.0 * n_hit * T_BL / (now - t0), now - t0,
                 100.0 * (n_hit - n_act) / n_hit, n_ref, lat_sum * 1.0 / (got > 0 ? got : 1));
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
