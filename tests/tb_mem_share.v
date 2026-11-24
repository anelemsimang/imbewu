// tb_mem_share.v - stress test of the cluster's memory arbiter and broadcast
// (mem_share in rtl/cluster.v), with random requesters instead of tiles.
//
// Each requester asks, at random moments, to read an address from a small
// shared set (so reads are often merged, in the same tick or while in
// flight), to read along a shared moving window (like tiles streaming the
// same tokens a few words apart), or to write into its own area. Checked:
// every read answer reaches the requester that asked, in the order it
// asked, with the right data; no answer is lost or extra; every write lands.
// Settings: -DTILES=4 -DCHANNELS=1 -DBCAST=1   plusargs: +LAT=<ticks> +SEED=<n> +NREQ=<n>
`timescale 1ns/1ps
`ifndef TILES
`define TILES 4
`endif
`ifndef CHANNELS
`define CHANNELS 1
`endif
`ifndef BCAST
`define BCAST 1
`endif
module tb_mem_share;
    localparam N = 4, T = `TILES, B = `CHANNELS, EAW = 12, W8 = N * 8;
    localparam TW = (T > 1) ? $clog2(T) : 1;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg  [TW-1:0]    rr = 0;
    reg  [T-1:0]     t_req = 0, t_we = 0;
    reg  [T*EAW-1:0] t_addr = 0;
    reg  [T*W8-1:0]  t_wdata = 0;
    wire [T-1:0]     t_ready, t_rvalid;
    wire [T*W8-1:0]  t_rdata;
    wire [B-1:0]     m_req, m_we;
    wire [B*EAW-1:0] m_addr;
    wire [B*W8-1:0]  m_wdata;
    reg  [B-1:0]     m_rvalid = 0;
    reg  [B*W8-1:0]  m_rdata = 0;

`ifdef GATE
    mem_share dut (                   // gate-level netlist: settings fixed at synthesis
`else
    mem_share #(.N(N), .T(T), .B(B), .EAW(EAW), .BC(`BCAST)) dut (
`endif
        .clk(clk), .rst(rst), .rr(rr),
        .t_req(t_req), .t_we(t_we), .t_addr(t_addr), .t_wdata(t_wdata), .t_ready(t_ready),
        .t_rvalid(t_rvalid), .t_rdata(t_rdata),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rvalid(m_rvalid), .m_rdata(m_rdata));

    // ---- memory: B channels, fixed delay, answers in the order issued ----------
    function [W8-1:0] init_word; input [EAW-1:0] a; init_word = a * 32'h9E3779B1 + 32'h7F4A7C15; endfunction
    reg [W8-1:0] mem [0:(1<<EAW)-1];
    reg [W8-1:0] pd [0:B-1][0:127];
    reg          pv [0:B-1][0:127];
    integer lat = 6, q, j, mreads = 0;
    always @(posedge clk) begin
        for (j = 0; j < B; j = j + 1) begin
            for (q = 127; q > 0; q = q - 1) begin pd[j][q] <= pd[j][q-1]; pv[j][q] <= pv[j][q-1]; end
            pv[j][0] <= 1'b0;
            if (m_req[j]) begin
                if (m_we[j]) mem[m_addr[EAW*j +: EAW]] <= m_wdata[W8*j +: W8];
                else begin
                    pd[j][0] <= mem[m_addr[EAW*j +: EAW]];
                    pv[j][0] <= 1'b1;
                    mreads = mreads + 1;
                end
            end
            m_rvalid[j] <= pv[j][lat - 1];
            m_rdata[W8*j +: W8] <= pd[j][lat - 1];
        end
    end

    // ---- requesters and checks ----------------------------------------------------
    // reads use addresses 0..1023 (never written); requester t writes only
    // into 1024 + 64t .. 1024 + 64t + 63
    reg [EAW-1:0] expq [0:T-1][0:1023];        // addresses each requester is waiting on
    integer qh [0:T-1], qt [0:T-1];
    reg [W8-1:0]  lastw [0:T-1][0:63];          // last value each requester wrote, per address
    reg           wrote [0:T-1][0:63];
    integer nreq = 3000, seed = 1, t, issued [0:T-1], errors = 0, accepted_reads = 0, answers = 0;
    integer cursor = 0, r, tick = 0, quiet = 0;
    reg [EAW-1:0] a;
    reg [T-1:0] t_ready_q = 0;                  // was the request accepted at the last tick?

    always @(posedge clk) if (!rst) begin
        tick = tick + 1;
        // checks: answers delivered this tick
        for (t = 0; t < T; t = t + 1)
            if (t_rvalid[t]) begin
                answers = answers + 1;
                if (qh[t] == qt[t]) begin
                    errors = errors + 1;
                    if (errors < 5) $display("requester %0d: answer it was not waiting for", t);
                end else begin
                    if (t_rdata[W8*t +: W8] !== init_word(expq[t][qh[t] % 1024])) begin
                        errors = errors + 1;
                        if (errors < 5) $display("requester %0d: wrong data for address %0d (got %h)",
                                                 t, expq[t][qh[t] % 1024], t_rdata[W8*t +: W8]);
                    end
                    qh[t] = qh[t] + 1;
                end
            end
        // requests accepted this tick
        for (t = 0; t < T; t = t + 1)
            if (t_req[t] && t_ready[t]) begin
                issued[t] = issued[t] + 1;
                if (!t_we[t]) begin
                    expq[t][qt[t] % 1024] = t_addr[EAW*t +: EAW];
                    qt[t] = qt[t] + 1;
                    accepted_reads = accepted_reads + 1;
                end else begin
                    lastw[t][t_addr[EAW*t +: EAW] % 64] = t_wdata[W8*t +: W8];
                    wrote[t][t_addr[EAW*t +: EAW] % 64] = 1'b1;
                end
            end
        // next tick's requests (a request not yet accepted stays as it is)
        #1;
        if (($urandom % 8) == 0) cursor = cursor + 1;
        rr = $urandom % T;
        for (t = 0; t < T; t = t + 1)
            if (!(t_req[t] && !t_ready_q[t])) begin
                t_req[t] = 1'b0;
                if (issued[t] < nreq && ($urandom % 4) != 0) begin
                    r = $urandom % 16;
                    t_req[t] = 1'b1; t_we[t] = 1'b0;
                    if (r < 6)       a = $urandom % 12;                          // small shared set
                    else if (r < 13) a = 100 + ((cursor + $urandom % 6) % 900);  // shared moving window
                    else begin                                                   // a write of its own
                        t_we[t] = 1'b1;
                        a = 1024 + 64 * t + $urandom % 64;
                        t_wdata[W8*t +: W8] = $urandom;
                    end
                    t_addr[EAW*t +: EAW] = a;
                end
            end
    end
    always @(posedge clk) t_ready_q <= t_ready & t_req;

    integer k, tt, done_all;
    initial begin
        if (!$value$plusargs("LAT=%d", lat)) lat = 6;
        if ($value$plusargs("SEED=%d", seed)) r = $urandom(seed);
        if (!$value$plusargs("NREQ=%d", nreq)) nreq = 3000;
        for (k = 0; k < (1 << EAW); k = k + 1) mem[k] = init_word(k);
        for (j = 0; j < B; j = j + 1) for (q = 0; q < 128; q = q + 1) pv[j][q] = 0;
        for (tt = 0; tt < T; tt = tt + 1) begin
            qh[tt] = 0; qt[tt] = 0; issued[tt] = 0;
            for (k = 0; k < 64; k = k + 1) wrote[tt][k] = 0;
        end
        repeat (3) @(posedge clk); #1 rst = 0;
        // run until every requester has issued nreq requests and all answers are in
        done_all = 0;
        while (!done_all) begin
            @(posedge clk); #2;
            done_all = 1;
            for (tt = 0; tt < T; tt = tt + 1)
                if (issued[tt] < nreq || qh[tt] != qt[tt]) done_all = 0;
            if (tick > 200 * nreq) begin $display("TIMEOUT: answers missing"); errors = errors + 1; done_all = 1; end
        end
        repeat (lat + 10) @(posedge clk);       // anything extra arriving late?
        for (tt = 0; tt < T; tt = tt + 1) begin
            if (qh[tt] != qt[tt]) begin errors = errors + 1; $display("requester %0d: %0d answers missing", tt, qt[tt] - qh[tt]); end
            for (k = 0; k < 64; k = k + 1)
                if (wrote[tt][k] && mem[1024 + 64 * tt + k] !== lastw[tt][k]) begin
                    errors = errors + 1;
                    if (errors < 5) $display("requester %0d: write to %0d lost", tt, 1024 + 64 * tt + k);
                end
        end
        $display("MEMSHARE %0d requesters, %0d channel(s), broadcast %0d, delay %0d: %0d reads asked, %0d memory reads (%0d shared), %0d answers, %0d errors, %0d ticks",
                 T, B, `BCAST, lat, accepted_reads, mreads, accepted_reads - mreads, answers, errors, tick);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
