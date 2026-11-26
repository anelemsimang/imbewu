// hbm_ctrl.v - controller for one HBM pseudo-channel (Phase 3, D-029)
//
// Plain language: HBM memory is DRAM. Its storage is split into banks, each
// a grid of rows; to read a word, the controller first opens ("activates")
// its row, which takes many ticks, then reads ("column command") words from
// the open row quickly. Opening another row in the same bank first needs
// the old one closed ("precharge"). Every few microseconds all rows must be
// refreshed, and the memory is busy for a while. On top of that come many
// small timing rules (see the parameters). A controller's job is to keep
// the data pins busy despite all this: this one takes requests from the
// network into a queue and every tick
//   * reads or writes for the oldest request whose row is already open
//     ("row hit", the cheapest), else
//   * opens or closes a row for the oldest request that needs one (but
//     never closes a row that a queued request still hits),
// requests to the same word always go in the order they came,
// which is the usual "first ready, first come first served" policy. Row
// commands (activate, precharge, refresh) and column commands (read,
// write) use separate command buses, as in HBM, so one of each may go out
// per tick. Every request gets exactly one answer (read data, or a write
// acknowledgement) with the request's tag; answers can come back in a
// different order from the requests (the tags say which is which).
//
// Address of a word: {row, column high bits, bank, column low 2 bits}:
// 4 consecutive words share a bank, the next 4 go to the next bank, so a
// stream keeps all 16 banks' rows open and opens them ahead of use. With
// HASH the bank is XOR-ed with the low 4 row bits ("permutation-based
// interleaving"), so several streams at once use different banks instead
// of fighting over the same ones. Timing parameters are in ticks of the
// chip clock (HBM3 values at about 1.2 GHz; the defaults are estimates,
// tests/tb_hbm.v checks every rule in a DRAM model).
module hbm_ctrl #(
    parameter DW   = 256,         // bits per word (one burst)
    parameter TW   = 16,          // tag bits
    parameter CB   = 5,           // column bits (words per row = 2^CB)
    parameter BB   = 4,           // bank bits (16 banks, 4 groups of 4)
    parameter RB   = 14,          // row bits
    parameter Q    = 16,          // request queue entries
    parameter RQ   = 16,          // answer queue entries
    parameter HASH = 1,           // 1: bank = address bank bits XOR low row bits
    // timing, in ticks
    parameter T_RCD = 17,         // activate -> read/write
    parameter T_RP  = 17,         // precharge -> activate
    parameter T_RAS = 40,         // activate -> precharge
    parameter T_CL  = 17,         // read -> first data
    parameter T_WL  = 6,          // write -> first data
    parameter T_BL  = 2,          // data ticks per burst
    parameter T_CCDS = 2,         // column -> column, different bank group
    parameter T_CCDL = 3,         // column -> column, same bank group
    parameter T_RRDS = 3,         // activate -> activate, different bank group
    parameter T_RRDL = 4,         // activate -> activate, same bank group
    parameter T_FAW  = 20,        // at most 4 activates in any T_FAW ticks
    parameter T_RTP  = 6,         // read -> precharge
    parameter T_WR   = 20,        // end of write data -> precharge
    parameter T_WTR  = 10,        // end of write data -> read
    parameter T_RTW  = 4,         // extra gap read data -> write data (bus turnaround)
    parameter T_REFI = 4680,      // refresh interval
    parameter T_RFC  = 420        // refresh -> anything
) (
    input  wire              clk,
    input  wire              rst,
    // requests (credit-based, as the network: send only with credit)
    input  wire              rq_v,
    input  wire              rq_we,
    input  wire [AW-1:0]     rq_addr,
    input  wire [TW-1:0]     rq_tag,
    input  wire [DW-1:0]     rq_wdata,
    output reg               rq_credit,     // one queue place freed
    // answers (credit-based: the controller starts with RC credits)
    output reg               rs_v,
    output reg               rs_we,         // 1: write acknowledgement
    output reg  [TW-1:0]     rs_tag,
    output reg  [DW-1:0]     rs_rdata,
    input  wire              rs_credit,
    // DRAM command buses and data (to the HBM interface; modelled in tests)
    output reg               d_act, d_pre, d_ref,      // row command bus
    output reg  [BB-1:0]     d_rbank,
    output reg  [RB-1:0]     d_row,
    output reg               d_rd, d_wr,               // column command bus
    output reg  [BB-1:0]     d_cbank,
    output reg  [CB-1:0]     d_col,
    output reg  [DW-1:0]     d_wdata,                  // with d_wr (model applies T_WL)
    input  wire              d_rvalid,                 // read data, T_CL after d_rd
    input  wire [DW-1:0]     d_rdata,
    // measurement
    output reg  [31:0]       n_hit, n_act, n_ref
);
    localparam AW = RB + BB + CB;
    localparam NB = 1 << BB;
    localparam QW = $clog2(Q);
    localparam RC = 4;            // answer credits towards the network (its queue depth)
    localparam OW = 16;           // age counter bits

    // ---- request queue -----------------------------------------------------
    reg          e_v   [0:Q-1];
    reg          e_we  [0:Q-1];
    reg [RB-1:0] e_row [0:Q-1];
    reg [BB-1:0] e_bk  [0:Q-1];
    reg [CB-1:0] e_col [0:Q-1];
    reg [TW-1:0] e_tag [0:Q-1];
    reg [DW-1:0] e_wd  [0:Q-1];
    reg [OW-1:0] e_age [0:Q-1];
    reg [OW-1:0] age_ctr;

    // ---- bank state and timers (ticks left until allowed) -------------------
    reg          b_open [0:NB-1];
    reg [RB-1:0] b_row  [0:NB-1];
    reg [7:0]    b_t_col [0:NB-1];      // activate -> column (T_RCD)
    reg [7:0]    b_t_pre [0:NB-1];      // -> precharge (T_RAS, T_RTP, T_WR)
    reg [7:0]    b_t_act [0:NB-1];      // -> activate (T_RP)
    reg [7:0]    g_t_ccd [0:3];         // per bank group: -> column
    reg [7:0]    t_ccd_any;             // -> column, any group (T_CCDS)
    reg [7:0]    g_t_rrd [0:3];         // per bank group: -> activate
    reg [7:0]    t_rrd_any;
    reg [7:0]    t_rd, t_wr;            // -> read (T_WTR), -> write (bus turnaround)
    reg [7:0]    faw [0:3];             // ticks left in the window of the last 4 activates
    reg [12:0]   t_refi;
    reg [9:0]    t_rfc;
    reg          ref_due;

    // ---- answers: reads in flight and the answer queue ----------------------
    // reserved places: an answer queue place is taken when a column command
    // is issued, so the queue can never overflow
    reg [TW-1:0] fl_tag [0:63];        // read tags in flight, in order (T_CL fixed)
    reg [5:0]    fl_wr, fl_rd;
    reg          aq_we  [0:RQ-1];
    reg [TW-1:0] aq_tag [0:RQ-1];
    reg [DW-1:0] aq_d   [0:RQ-1];
    reg [$clog2(RQ):0] aq_n, aq_res;   // filled, reserved (incl. filled)
    reg [$clog2(RQ)-1:0] aq_wp, aq_rp;
    reg [2:0]    rcred;

    integer k;
    // ---- choose this tick's commands -----------------------------------------
    // hit[k]: request k's row is open; b_hits[b]: some request hits bank b
    reg [Q-1:0]  hit, col_ok, blocked, row_ok;   // blocked: an older request has the same address
    integer j;
    reg [NB-1:0] b_hits;
    reg          col_go, row_go, pre_go, act_go;
    reg [QW-1:0] col_e, row_e;
    reg [OW-1:0] col_age, row_age;
    reg          any_open;
    reg [BB-1:0] bk;
    reg [1:0]    gq;
    reg [2:0]    n_faw;
    always @(*) begin
        col_go = 1'b0; row_go = 1'b0; pre_go = 1'b0; act_go = 1'b0;
        col_e = 0; row_e = 0; col_age = 0; row_age = 0;
        any_open = 1'b0; b_hits = 0;
        for (k = 0; k < NB; k = k + 1) any_open = any_open | b_open[k];
        n_faw = (faw[0] != 0) + (faw[1] != 0) + (faw[2] != 0) + (faw[3] != 0);
        // requests to the same word go in the order they came (a read
        // after a write must see the new data)
        for (k = 0; k < Q; k = k + 1) begin
            blocked[k] = 1'b0;
            for (j = 0; j < Q; j = j + 1)
                if (j != k && e_v[j] && e_row[j] == e_row[k] && e_bk[j] == e_bk[k] && e_col[j] == e_col[k]
                    && (age_ctr - e_age[j]) > (age_ctr - e_age[k]))
                    blocked[k] = 1'b1;
        end
        for (k = 0; k < Q; k = k + 1) begin
            bk = e_bk[k]; gq = e_bk[k][BB-1 -: 2];
            hit[k] = e_v[k] && b_open[bk] && (b_row[bk] == e_row[k]);
            if (hit[k]) b_hits[bk] = 1'b1;
            col_ok[k] = hit[k] && !blocked[k] && !ref_due && (t_rfc == 0) && (b_t_col[bk] == 0)
                     && (g_t_ccd[gq] == 0) && (t_ccd_any == 0)
                     && (e_we[k] ? (t_wr == 0) : (t_rd == 0)) && (aq_res < RQ);
        end
        // column command: the oldest request that can read or write now
        for (k = 0; k < Q; k = k + 1)
            if (col_ok[k] && (!col_go || (age_ctr - e_age[k]) > (age_ctr - col_age))) begin
                col_go = 1'b1; col_e = k; col_age = e_age[k];
            end
        // row command: for the oldest request whose row is not open and
        // whose bank can take its command now (close the open row, but only
        // when no queued request still hits it; or open the row)
        for (k = 0; k < Q; k = k + 1) begin
            bk = e_bk[k]; gq = e_bk[k][BB-1 -: 2];
            row_ok[k] = e_v[k] && !hit[k] && !ref_due && (t_rfc == 0) &&
                (b_open[bk] ? (b_t_pre[bk] == 0) && !b_hits[bk]
                            : (b_t_act[bk] == 0) && (g_t_rrd[gq] == 0) && (t_rrd_any == 0) && (n_faw < 4));
            if (row_ok[k] && (!row_go || (age_ctr - e_age[k]) > (age_ctr - row_age))) begin
                row_go = 1'b1; row_e = k; row_age = e_age[k];
            end
        end
        if (row_go) begin
            pre_go = b_open[e_bk[row_e]];
            act_go = !b_open[e_bk[row_e]];
        end
    end

    // refresh: when due, close every open bank (one per tick), then refresh
    reg          ref_pre_go, ref_go;
    reg [BB-1:0] ref_bk;
    always @(*) begin
        ref_pre_go = 1'b0; ref_go = 1'b0; ref_bk = 0;
        if (ref_due && t_rfc == 0) begin
            for (k = NB - 1; k >= 0; k = k - 1)
                if (b_open[k] && b_t_pre[k] == 0) begin ref_pre_go = 1'b1; ref_bk = k; end
            ref_go = !any_open;
            for (k = 0; k < NB; k = k + 1) if (b_t_act[k] != 0) ref_go = 1'b0;
        end
    end

    // ---- state update -------------------------------------------------------
    reg [QW-1:0] free_e;
    reg          has_free;
    always @(*) begin
        has_free = 1'b0; free_e = 0;
        for (k = Q - 1; k >= 0; k = k - 1) if (!e_v[k]) begin has_free = 1'b1; free_e = k; end
    end
    function [7:0] dec; input [7:0] t; dec = (t == 0) ? 8'd0 : t - 1'b1; endfunction
    function [7:0] mx; input [7:0] a, b; mx = (a > b) ? a : b; endfunction

    always @(posedge clk) begin
        d_act <= 1'b0; d_pre <= 1'b0; d_ref <= 1'b0; d_rd <= 1'b0; d_wr <= 1'b0;
        rq_credit <= 1'b0; rs_v <= 1'b0;
        if (rst) begin
            for (k = 0; k < Q; k = k + 1) e_v[k] <= 1'b0;
            for (k = 0; k < NB; k = k + 1) begin
                b_open[k] <= 1'b0; b_t_col[k] <= 0; b_t_pre[k] <= 0; b_t_act[k] <= 0;
            end
            for (k = 0; k < 4; k = k + 1) begin g_t_ccd[k] <= 0; g_t_rrd[k] <= 0; faw[k] <= 0; end
            t_ccd_any <= 0; t_rrd_any <= 0; t_rd <= 0; t_wr <= 0;
            t_refi <= T_REFI; t_rfc <= 0; ref_due <= 1'b0;
            age_ctr <= 0; fl_wr <= 0; fl_rd <= 0;
            aq_n <= 0; aq_res <= 0; aq_wp <= 0; aq_rp <= 0; rcred <= RC;
            n_hit <= 0; n_act <= 0; n_ref <= 0;
        end else begin
            // timers count down
            for (k = 0; k < NB; k = k + 1) begin
                b_t_col[k] <= dec(b_t_col[k]); b_t_pre[k] <= dec(b_t_pre[k]); b_t_act[k] <= dec(b_t_act[k]);
            end
            for (k = 0; k < 4; k = k + 1) begin
                g_t_ccd[k] <= dec(g_t_ccd[k]); g_t_rrd[k] <= dec(g_t_rrd[k]); faw[k] <= dec(faw[k]);
            end
            t_ccd_any <= dec(t_ccd_any); t_rrd_any <= dec(t_rrd_any);
            t_rd <= dec(t_rd); t_wr <= dec(t_wr);
            if (t_rfc != 0) t_rfc <= t_rfc - 1'b1;
            if (t_refi != 0) t_refi <= t_refi - 1'b1; else ref_due <= 1'b1;

            // a new request into a free place
            if (rq_v) begin
                e_v[free_e] <= 1'b1; e_we[free_e] <= rq_we; e_tag[free_e] <= rq_tag;
                e_wd[free_e] <= rq_wdata; e_age[free_e] <= age_ctr;
                {e_row[free_e], e_col[free_e][CB-1:2], e_bk[free_e], e_col[free_e][1:0]} <= rq_addr;
                // bank hashing: the bank number is XOR-ed with the low row bits,
                // so streams in different rows fall into different banks
                if (HASH) e_bk[free_e] <= rq_addr[2 +: BB] ^ rq_addr[CB + BB +: BB];
                age_ctr <= age_ctr + 1'b1;
            end

            // column command
            if (col_go) begin
                bk = e_bk[col_e]; gq = e_bk[col_e][BB-1 -: 2];
                e_v[col_e] <= 1'b0; rq_credit <= 1'b1;
                d_cbank <= bk; d_col <= e_col[col_e]; d_wdata <= e_wd[col_e];
                n_hit <= n_hit + 1'b1;
                for (k = 0; k < 4; k = k + 1) if (k == gq) g_t_ccd[k] <= T_CCDL - 1;
                t_ccd_any <= T_CCDS - 1;
                if (e_we[col_e]) begin
                    d_wr <= 1'b1;
                    b_t_pre[bk] <= mx(dec(b_t_pre[bk]), T_WL + T_BL + T_WR - 1);
                    t_rd <= mx(dec(t_rd), T_WL + T_BL + T_WTR - 1);
                    // write acknowledgement: straight into the answer queue
                    aq_we[aq_wp] <= 1'b1; aq_tag[aq_wp] <= e_tag[col_e];
                    aq_wp <= aq_wp + 1'b1;
                end else begin
                    d_rd <= 1'b1;
                    b_t_pre[bk] <= mx(dec(b_t_pre[bk]), T_RTP - 1);
                    t_wr <= mx(dec(t_wr), T_CL + T_BL + T_RTW - T_WL - 1);
                    fl_tag[fl_wr] <= e_tag[col_e]; fl_wr <= fl_wr + 1'b1;
                end
            end

            // row command (or refresh's precharges / the refresh itself)
            if (ref_pre_go) begin
                d_pre <= 1'b1; d_rbank <= ref_bk; b_open[ref_bk] <= 1'b0; b_t_act[ref_bk] <= T_RP - 1;
            end else if (ref_go) begin
                d_ref <= 1'b1; ref_due <= 1'b0; t_refi <= T_REFI; t_rfc <= T_RFC - 1;
                n_ref <= n_ref + 1'b1;
            end else if (pre_go) begin
                bk = e_bk[row_e];
                d_pre <= 1'b1; d_rbank <= bk; b_open[bk] <= 1'b0; b_t_act[bk] <= T_RP - 1;
            end else if (act_go) begin
                bk = e_bk[row_e]; gq = e_bk[row_e][BB-1 -: 2];
                d_act <= 1'b1; d_rbank <= bk; d_row <= e_row[row_e];
                b_open[bk] <= 1'b1; b_row[bk] <= e_row[row_e];
                b_t_col[bk] <= T_RCD - 1; b_t_pre[bk] <= T_RAS - 1;
                for (k = 0; k < 4; k = k + 1) if (k == gq) g_t_rrd[k] <= T_RRDL - 1;
                t_rrd_any <= T_RRDS - 1;
                // the window of the last 4 activates: replace the oldest
                faw[0] <= dec(faw[1]); faw[1] <= dec(faw[2]); faw[2] <= dec(faw[3]);
                faw[3] <= T_FAW - 1;
                n_act <= n_act + 1'b1;
            end

            // read data back from the DRAM into the answer queue
            if (d_rvalid) begin
                aq_we[aq_wp + (col_go && e_we[col_e])] <= 1'b0;
                aq_tag[aq_wp + (col_go && e_we[col_e])] <= fl_tag[fl_rd];
                aq_d[aq_wp + (col_go && e_we[col_e])] <= d_rdata;
                fl_rd <= fl_rd + 1'b1;
                aq_wp <= aq_wp + 1'b1 + (col_go && e_we[col_e]);
            end

            // answer out to the network
            rcred <= rcred + rs_credit - ((aq_n != 0) && (rcred != 0));
            if (aq_n != 0 && rcred != 0) begin
                rs_v <= 1'b1; rs_we <= aq_we[aq_rp]; rs_tag <= aq_tag[aq_rp]; rs_rdata <= aq_d[aq_rp];
                aq_rp <= aq_rp + 1'b1;
            end
            aq_n   <= aq_n + (col_go && e_we[col_e]) + d_rvalid - ((aq_n != 0) && (rcred != 0));
            aq_res <= aq_res + col_go - ((aq_n != 0) && (rcred != 0));
        end
    end
endmodule
