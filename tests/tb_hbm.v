// tb_hbm.v - rtl/hbm_ctrl.v against a DRAM model that checks every timing
// rule, with a scoreboard for the data.
// plusargs: +PAT=<0..3> +SEED=<n> +NREQ=<n> +RATE=<percent>
//   PAT 0: streaming reads (consecutive words: mostly row hits)
//   PAT 1: random reads over the whole channel (mostly row misses)
//   PAT 2: random reads and writes (30%) over a few rows (same-word hazards)
//   PAT 3: streaming writes, then streaming reads of the same words
// Checks: every DRAM timing rule (dram model below), data bus never used
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
    reg              d_rvalid = 0;
    reg  [DW-1:0]    d_rdata = 0;
    wire [31:0]      n_hit, n_act, n_ref;
    hbm_ctrl #(.DW(DW), .TW(TW), .CB(CB), .BB(BB), .RB(RB), .Q(Q)) dut (
        .clk(clk), .rst(rst), .rq_v(rq_v), .rq_we(rq_we), .rq_addr(rq_addr), .rq_tag(rq_tag),
        .rq_wdata(rq_wdata), .rq_credit(rq_credit), .rs_v(rs_v), .rs_we(rs_we), .rs_tag(rs_tag),
        .rs_rdata(rs_rdata), .rs_credit(rs_credit),
        .d_act(d_act), .d_pre(d_pre), .d_ref(d_ref), .d_rbank(d_rbank), .d_row(d_row),
        .d_rd(d_rd), .d_wr(d_wr), .d_cbank(d_cbank), .d_col(d_col), .d_wdata(d_wdata),
        .d_rvalid(d_rvalid), .d_rdata(d_rdata), .n_hit(n_hit), .n_act(n_act), .n_ref(n_ref));

    // ---------------- DRAM model with timing checks ----------------
    localparam NEG = -100000;
    integer now, errors;
    reg [DW-1:0] mem [0:(1<<AW)-1];
    integer b_open [0:15], b_row [0:15], b_act [0:15], b_pre [0:15], b_rd [0:15], b_wre [0:15];
    integer g_act [0:3], g_col [0:3];
    integer act_any, col_any, ref_t, wr_end, rd_end, bus_free;
    integer acts [0:3];
    integer rd_due [0:63]; reg [DW-1:0] rd_val [0:63]; integer rd_w, rd_r;
    integer b, g, k;
    task bad; input [8*48-1:0] what; begin
        errors = errors + 1;
        if (errors < 8) $display("ERROR tick %0d: %0s", now, what);
    end endtask

    always @(posedge clk) if (!rst) begin
        // row commands
        if (d_act) begin
            b = d_rbank; g = b / 4;
            if (b_open[b]) bad("ACT to an open bank");
            if (now - b_pre[b] < T_RP) bad("tRP");
            if (now - act_any < T_RRDS) bad("tRRD_S");
            if (now - g_act[g] < T_RRDL) bad("tRRD_L");
            if (now - acts[0] < T_FAW) bad("tFAW");
            if (now - ref_t < T_RFC) bad("tRFC (ACT)");
            b_open[b] = 1; b_row[b] = d_row; b_act[b] = now; act_any = now; g_act[g] = now;
            acts[0] = acts[1]; acts[1] = acts[2]; acts[2] = acts[3]; acts[3] = now;
        end
        if (d_pre) begin
            b = d_rbank;
            if (!b_open[b]) bad("PRE to a closed bank");
            if (now - b_act[b] < T_RAS) bad("tRAS");
            if (now - b_rd[b] < T_RTP) bad("tRTP");
            if (now - b_wre[b] < T_WR) bad("tWR");
            b_open[b] = 0; b_pre[b] = now;
        end
        if (d_ref) begin
            for (k = 0; k < 16; k = k + 1) begin
                if (b_open[k]) bad("REF with a bank open");
                if (now - b_pre[k] < T_RP) bad("tRP before REF");
            end
            if (now - ref_t < T_RFC) bad("tRFC (REF)");
            ref_t = now;
        end
        if (now - (ref_t < 0 ? 0 : ref_t) > T_REFI + 200) bad("refresh overdue");
        // column commands
        if (d_rd || d_wr) begin
            b = d_cbank; g = b / 4;
            if (!b_open[b]) bad("column command to a closed bank");
            if (now - b_act[b] < T_RCD) bad("tRCD");
            if (now - col_any < T_CCDS) bad("tCCD_S");
            if (now - g_col[g] < T_CCDL) bad("tCCD_L");
            if (now - ref_t < T_RFC) bad("tRFC (column)");
            col_any = now; g_col[g] = now;
            if (d_rd) begin
                if (now < wr_end + T_WTR) bad("tWTR");
                if (now + T_CL < bus_free) bad("data bus clash (read)");
                bus_free = now + T_CL + T_BL; rd_end = now + T_CL + T_BL; b_rd[b] = now;
                rd_due[rd_w % 64] = now + T_CL; rd_val[rd_w % 64] = mem[{b_row[b][RB-1:0], d_col[CB-1:2], d_cbank, d_col[1:0]}];
                rd_w = rd_w + 1;
            end else begin
                if (now + T_WL < bus_free) bad("data bus clash (write)");
                if (now + T_WL < rd_end + T_RTW) bad("read-to-write turnaround");
                bus_free = now + T_WL + T_BL; wr_end = now + T_WL + T_BL; b_wre[b] = wr_end;
                mem[{b_row[b][RB-1:0], d_col[CB-1:2], d_cbank, d_col[1:0]}] = d_wdata;
            end
        end
    end
    // read data back to the controller
    always @(negedge clk) begin
        d_rvalid = 0;
        if (rd_r < rd_w && rd_due[rd_r % 64] == now + 1) begin
            d_rvalid = 1; d_rdata = rd_val[rd_r % 64]; rd_r = rd_r + 1;
        end
    end

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
        errors = 0; now = 0; act_any = NEG; col_any = NEG; ref_t = -T_RFC; wr_end = NEG; rd_end = NEG;
        bus_free = 0; rd_w = 0; rd_r = 0;
        for (k = 0; k < 16; k = k + 1) begin
            b_open[k] = 0; b_act[k] = NEG; b_pre[k] = NEG; b_rd[k] = NEG; b_wre[k] = NEG;
        end
        for (k = 0; k < 4; k = k + 1) begin g_act[k] = NEG; g_col[k] = NEG; acts[k] = NEG; end
        for (i = 0; i < (1 << AW); i = i + 1) begin mem[i] = i; shadow[i] = i; end
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
