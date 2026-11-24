// cluster.v - several Imbewu tiles sharing one main memory (Phase 3, goals G2, G3)
//
// Plain language: a real chip has many tiles. They all fetch from the same
// main memory (HBM), which has a limited number of channels. This block
// holds T tiles (tile_v3.v) and a memory arbiter: every tick it lets up to
// B tiles that are asking use the memory (taking turns, so no tile waits
// forever), remembers which tiles each read is for, and sends each answer
// back to them.
//
// Broadcast (BC = 1): when several tiles read the same address, memory
// gets ONE read and its answer goes to all of them. A tile may join a read
// issued in the same tick, or one issued a few ticks earlier whose answer
// has not come back yet (a list of reads in flight, like the "miss
// registers" of a cache). Tiles working on the same tokens (activations)
// then share the fetch instead of each reading its own copy, even if they
// are a few words apart. Joining takes no memory channel.
//
// Main-memory side: up to B requests per tick (channel j = slot j). Memory
// must answer every read, in the order issued (same-tick reads in channel
// order); the answer to the read in slot j comes back on lane j. The
// cluster sends each answer to every tile waiting for it (one tick later).
// Assumption, kept by our workloads: no tile reads an address another tile
// writes during the same layer (inputs and outputs are separate).
module cluster #(
    parameter N   = 4,
    parameter T   = 2,           // tiles
    parameter B   = 1,           // memory requests accepted per tick (channels)
    parameter EAW = 20,
    parameter BC  = 1,           // 1: merge identical reads into one (broadcast)
    parameter W   = 8,           // a read may be joined while among the last W issued
    parameter DW  = 8            // list of reads in flight: 2^DW entries (> memory delay x B)
) (
    input  wire               clk,
    input  wire               rst,
    // command lists, one port per tile (tile t uses slice t)
    input  wire [T-1:0]       cmd_we,
    input  wire [4*T-1:0]     cmd_idx,
    input  wire [200*T-1:0]   cmd_data,
    input  wire [5*T-1:0]     n_cmds,
    input  wire               start,
    output wire               busy,
    output reg                done,
    // main memory: B request slots per tick
    output wire [B-1:0]       m_req,
    output wire [B-1:0]       m_we,
    output wire [B*EAW-1:0]   m_addr,
    output wire [B*N*8-1:0]   m_wdata,
    // read answers, in the order the reads were issued: lane j answers the
    // read that was in slot j
    input  wire [B-1:0]       m_rvalid,
    input  wire [B*N*8-1:0]   m_rdata,
    // measurement
    output wire [32*T-1:0]    ticks_engine,
    output reg  [31:0]        ticks
);
    localparam W8 = N * 8;
    localparam TW = (T > 1) ? $clog2(T) : 1;

    wire [T-1:0]     t_req, t_we, t_busy, t_done;
    wire [T*EAW-1:0] t_addr;
    wire [T*W8-1:0]  t_wdata;
    wire [T-1:0]     t_ready;
    wire [T*32-1:0]  t_ticks_busy;
    wire [T-1:0]     t_rvalid;
    wire [T*W8-1:0]  t_rdata;

    genvar i;
    generate
        for (i = 0; i < T; i = i + 1) begin : tile
            tile_v3 #(.N(N), .EAW(EAW)) u (
                .clk(clk), .rst(rst),
                .cmd_we(cmd_we[i]), .cmd_idx(cmd_idx[4*i +: 4]), .cmd_data(cmd_data[200*i +: 200]),
                .n_cmds(n_cmds[5*i +: 5]), .start(start), .busy(t_busy[i]), .done(t_done[i]),
                .mem_req(t_req[i]), .mem_we(t_we[i]), .mem_addr(t_addr[EAW*i +: EAW]),
                .mem_wdata(t_wdata[W8*i +: W8]), .mem_ready(t_ready[i]),
                .mem_rvalid(t_rvalid[i]), .mem_rdata(t_rdata[W8*i +: W8]),
                .ticks_busy(t_ticks_busy[32*i +: 32]), .ticks_engine(ticks_engine[32*i +: 32]));
        end
    endgenerate

    // ---- memory sharing: arbiter and broadcast (mem_share below) ------------------
    reg [TW-1:0] rr;                     // the tile that gets first choice this tick
    mem_share #(.N(N), .T(T), .B(B), .EAW(EAW), .BC(BC), .W(W), .DW(DW)) u_share (
        .clk(clk), .rst(rst), .rr(rr),
        .t_req(t_req), .t_we(t_we), .t_addr(t_addr), .t_wdata(t_wdata), .t_ready(t_ready),
        .t_rvalid(t_rvalid), .t_rdata(t_rdata),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rvalid(m_rvalid), .m_rdata(m_rdata));

    // ---- whole-cluster status ----------------------------------------------------
    reg [T-1:0] finished;
    reg         running;
    assign busy = running;
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            rr <= 0; finished <= 0; running <= 1'b0; ticks <= 0;
        end else begin
            rr <= (rr == T - 1) ? 0 : rr + 1'b1;
            if (start && !running) begin
                running <= 1'b1; finished <= 0; ticks <= 0;
            end else if (running) begin
                ticks <= ticks + 1;
                if ((finished | t_done) == {T{1'b1}}) begin
                    running <= 1'b0; done <= 1'b1;
                end
                finished <= finished | t_done;
            end
        end
    end
endmodule


// mem_share - the cluster's memory arbiter and broadcast, on its own so it
// can be tested with any requesters (tests/tb_mem_share.v). Requester
// side: as tile_v3's main-memory port (a request is accepted in the tick
// t_ready is high; read answers arrive in the order asked). rr: the
// requester that gets first choice this tick.
module mem_share #(
    parameter N = 4, parameter T = 2, parameter B = 1, parameter EAW = 20,
    parameter BC = 1, parameter W = 8, parameter DW = 8
) (
    input  wire               clk,
    input  wire               rst,
    input  wire [((T > 1) ? $clog2(T) : 1)-1:0] rr,
    input  wire [T-1:0]       t_req,
    input  wire [T-1:0]       t_we,
    input  wire [T*EAW-1:0]   t_addr,
    input  wire [T*N*8-1:0]   t_wdata,
    output reg  [T-1:0]       t_ready,
    output reg  [T-1:0]       t_rvalid,
    output reg  [T*N*8-1:0]   t_rdata,
    output reg  [B-1:0]       m_req,
    output reg  [B-1:0]       m_we,
    output reg  [B*EAW-1:0]   m_addr,
    output reg  [B*N*8-1:0]   m_wdata,
    input  wire [B-1:0]       m_rvalid,
    input  wire [B*N*8-1:0]   m_rdata
);
    localparam W8 = N * 8;
    localparam TW = (T > 1) ? $clog2(T) : 1;
    // ---- list of reads in flight (oldest at hd) -------------------------------
    // Each entry: address, the tick it was issued, which tiles want the
    // answer, and whether it may still be joined.
    localparam D = 1 << DW;
    reg [EAW-1:0] e_addr [0:D-1];
    reg [31:0]    e_tick [0:D-1];
    reg [T-1:0]   e_mask [0:D-1];
    reg [DW-1:0]  hd, tl;
    reg [DW:0]    cnt;
    reg [31:0]    now;                   // free-running tick number (starts at 1)
    reg [31:0]    last_t [0:T-1];        // issue tick of the last read each tile is waiting on
    // A tile may only join a read issued AFTER every read it is already
    // waiting on, so its answers still arrive in the order it asked, one
    // per tick at most.

    // answers coming back this tick (they leave the list, so can't be joined)
    function integer count_ones; input [B-1:0] v; integer q; begin
        count_ones = 0;
        for (q = 0; q < B; q = q + 1) if (v[q]) count_ones = count_ones + 1;
    end endfunction
    wire [7:0] nret = count_ones(m_rvalid);

    // ---- arbiter: up to B grants per tick, round robin ------------------------
    // A tile's request is "accepted" in the tick its mem_ready is high; the
    // granted requests are passed to memory in the same tick.
    integer k, j, g, w, pos, nrd;
    reg [TW:0] idx;
    reg joined;
    reg [DW-1:0] pe;                     // list index (wraps around)
    reg [T-1:0]  jf_v;                   // tile joins an entry already in flight ...
    reg [DW-1:0] jf_e [0:T-1];           // ... this one
    reg [B-1:0]  slot_rd;                // slot j is a new read ...
    reg [T-1:0]  slot_mask [0:B-1];      // ... for these tiles
    always @(*) begin
        t_ready = {T{1'b0}};
        m_req = {B{1'b0}}; m_we = {B{1'b0}}; m_addr = 0; m_wdata = 0;
        jf_v = {T{1'b0}}; slot_rd = {B{1'b0}};
        for (j = 0; j < B; j = j + 1) slot_mask[j] = {T{1'b0}};
        for (k = 0; k < T; k = k + 1) jf_e[k] = 0;
        g = 0; nrd = 0;
        for (k = 0; k < T; k = k + 1) begin
            idx = rr + k;
            if (idx >= T) idx = idx - T;
            joined = 1'b0;
            if (BC && t_req[idx] && !t_we[idx]) begin
                // 1. a read in flight (oldest suitable one)
                for (w = W - 1; w >= 0; w = w - 1) begin
                    pos = cnt - 1 - w;                       // place in the list, 0 = oldest
                    pe  = hd + pos;
                    if (!joined && w < cnt && pos >= nret &&
                        e_addr[pe] == t_addr[EAW*idx +: EAW] && e_tick[pe] > last_t[idx]) begin
                        joined = 1'b1;
                        jf_v[idx] = 1'b1;
                        jf_e[idx] = pe;
                    end
                end
                // 2. a read issued in this same tick
                for (j = 0; j < B; j = j + 1)
                    if (!joined && j < g && slot_rd[j] && m_addr[EAW*j +: EAW] == t_addr[EAW*idx +: EAW]) begin
                        joined = 1'b1;
                        slot_mask[j][idx] = 1'b1;
                    end
                if (joined) t_ready[idx] = 1'b1;
            end
            // 3. otherwise a channel of its own (reads only while the list has room)
            if (t_req[idx] && !joined && g < B && (t_we[idx] || cnt + nrd < D - 1)) begin
                t_ready[idx] = 1'b1;
                for (j = 0; j < B; j = j + 1)
                    if (j == g) begin
                        m_req[j] = 1'b1;
                        m_we[j] = t_we[idx];
                        m_addr[EAW*j +: EAW] = t_addr[EAW*idx +: EAW];
                        m_wdata[W8*j +: W8] = t_wdata[W8*idx +: W8];
                        slot_rd[j] = !t_we[idx];
                        slot_mask[j][idx] = 1'b1;
                    end
                if (!t_we[idx]) nrd = nrd + 1;
                g = g + 1;
            end
        end
    end

    // ---- keep the list; send answers to the tiles waiting for them --------------
    reg [DW-1:0] p;
    integer r, jj, kk;
    always @(posedge clk) begin
        t_rvalid <= {T{1'b0}};
        if (rst) begin
            hd <= 0; tl <= 0; cnt <= 0; now <= 1;
            for (kk = 0; kk < T; kk = kk + 1) last_t[kk] <= 0;
        end else begin
            now <= now + 1;
            // answers: lane j, in order, is the next entry of the list
            r = 0;
            for (jj = 0; jj < B; jj = jj + 1)
                if (m_rvalid[jj]) begin
                    p = hd + r;
                    for (kk = 0; kk < T; kk = kk + 1)
                        if (e_mask[p][kk]) begin
                            t_rvalid[kk] <= 1'b1;
                            t_rdata[W8*kk +: W8] <= m_rdata[W8*jj +: W8];
                        end
                    r = r + 1;
                end
            // tiles joining reads in flight
            for (kk = 0; kk < T; kk = kk + 1)
                if (jf_v[kk]) begin
                    e_mask[jf_e[kk]][kk] <= 1'b1;
                    last_t[kk] <= e_tick[jf_e[kk]];
                end
            // new reads join the end of the list
            r = 0;
            for (jj = 0; jj < B; jj = jj + 1)
                if (slot_rd[jj]) begin
                    p = tl + r;
                    e_addr[p] <= m_addr[EAW*jj +: EAW];
                    e_tick[p] <= now;
                    e_mask[p] <= slot_mask[jj];
                    for (kk = 0; kk < T; kk = kk + 1) if (slot_mask[jj][kk]) last_t[kk] <= now;
                    r = r + 1;
                end
            tl  <= tl + r;
            hd  <= hd + nret;
            cnt <= cnt + r - nret;
        end
    end

endmodule
