// noc_router.v - one router of the on-chip network (Phase 3, D-028)
//
// Plain language: on a chip with hundreds of tiles, one central switch
// (cluster.v's arbiter) cannot reach them all. Instead each tile has a small
// router, and routers are wired to their four neighbours in a grid (a
// "mesh", noc_mesh.v). A message ("flit": one word plus its destination)
// hops from router to router, one hop per tick, first east or west until it
// is in the right column, then north or south (dimension-order or "XY"
// routing). Because every message turns at most once, and always from the
// X direction to the Y direction, messages can never wait on each other in
// a circle, so the network cannot deadlock.
//
// Ports: 0 = local (the tile), 1 = north (y - 1), 2 = east (x + 1),
//        3 = south (y + 1), 4 = west (x - 1).
// Each input has a small queue (D flits). A router only sends a flit when
// the next router's queue has room: it holds one "credit" per free place
// downstream, spends one per flit sent, and gets one back each time the
// next router takes a flit from that queue (credit-based flow control).
// All outputs are registered, so no signal crosses more than one link in a
// tick: the network's speed does not depend on its size.
// When several inputs want the same output, the output takes turns (round
// robin), so no input waits forever.
//
// Flit: {dst_x, dst_y, payload}; the router reads only dst_x and dst_y.
module noc_router #(
    parameter XW = 5,             // bits of the x coordinate
    parameter YW = 5,             // bits of the y coordinate
    parameter PW = 64,            // payload bits
    parameter D  = 4              // places in each input queue (>= 2)
) (
    input  wire                   clk,
    input  wire                   rst,
    input  wire [XW-1:0]          my_x,
    input  wire [YW-1:0]          my_y,
    // inputs, one flit per port per tick
    input  wire [4:0]             in_v,
    input  wire [5*FW-1:0]        in_flit,
    output reg  [4:0]             in_credit,   // one place freed in that input's queue
    // outputs
    output reg  [4:0]             out_v,
    output reg  [5*FW-1:0]        out_flit,
    input  wire [4:0]             out_credit   // the next router freed a place
`ifdef FORMAL
    , output wire [5*CW-1:0]      f_cred,
    output wire [5*QW-1:0]        f_cnt,
    output wire [24:0]            f_want,      // f_want[i*5+o]: input i's head wants output o
    output wire [24:0]            f_gnt,       // f_gnt[i*5+o]: granted this tick
    output wire [4:0]             f_send,
    output wire [14:0]            f_last       // last[o] at bits 3o+2:3o
`endif
);
    localparam FW = XW + YW + PW;
    localparam QW = $clog2(D + 1);
    localparam CW = $clog2(D + 1);
    localparam AW = (D > 1) ? $clog2(D) : 1;

    // ---- input queues ----------------------------------------------------
    reg [FW-1:0] q    [0:5*D-1];         // queue i holds q[i*D .. i*D+D-1]
    reg [AW-1:0] q_rd [0:4];
    reg [AW-1:0] q_wr [0:4];
    reg [QW-1:0] q_n  [0:4];
    wire [4:0]   pop;                          // head leaves this tick

    // head of each queue and the output it wants (one-hot)
    wire [FW-1:0] head [0:4];
    wire [4:0]    want [0:4];                  // want[i][o]
    genvar i, o;
    generate
        for (i = 0; i < 5; i = i + 1) begin : inq
            assign head[i] = q[i*D + q_rd[i]];
            wire [XW-1:0] dx = head[i][FW-1 -: XW];
            wire [YW-1:0] dy = head[i][FW-XW-1 -: YW];
            wire go_e = dx > my_x, go_w = dx < my_x;
            wire go_s = (dx == my_x) && (dy > my_y);
            wire go_n = (dx == my_x) && (dy < my_y);
            wire here = (dx == my_x) && (dy == my_y);
            assign want[i] = (q_n[i] == 0) ? 5'd0 : {go_w, go_s, go_e, go_n, here};
        end
    endgenerate

    // ---- outputs: credits, round-robin choice ------------------------------
    reg  [CW-1:0] cred [0:4];
    reg  [2:0]    last [0:4];                  // input served last, per output
    wire [4:0]    gnt  [0:4];                  // gnt[o][i]
    wire [2:0]    sel  [0:4];
    wire [4:0]    send;
    generate
        for (o = 0; o < 5; o = o + 1) begin : outp
            wire [4:0] req = {want[4][o], want[3][o], want[2][o], want[1][o], want[0][o]};
            // round robin: first requester after the one served last
            reg [2:0] pick;
            reg       any;
            integer k, c;
            always @(*) begin
                pick = 3'd0; any = 1'b0;
                for (k = 5; k >= 1; k = k - 1) begin
                    c = (last[o] + k) % 5;
                    if (req[c]) begin pick = c; any = 1'b1; end
                end
            end
            assign send[o] = any && (cred[o] != 0);
            assign sel[o]  = pick;
            assign gnt[o]  = send[o] ? (5'd1 << pick) : 5'd0;
        end
        for (i = 0; i < 5; i = i + 1) begin : popi
            assign pop[i] = gnt[0][i] | gnt[1][i] | gnt[2][i] | gnt[3][i] | gnt[4][i];
        end
    endgenerate

    integer p;
    always @(posedge clk) begin
        for (p = 0; p < 5; p = p + 1) begin
            // queue p: write the arriving flit, read the head if granted
            if (in_v[p]) begin
                q[p*D + q_wr[p]] <= in_flit[p*FW +: FW];
            end
            out_flit[p*FW +: FW] <= head[sel[p]];
            if (rst) begin
                q_rd[p] <= 0; q_wr[p] <= 0; q_n[p] <= 0;
                cred[p] <= D; last[p] <= 3'd4;
                out_v[p] <= 1'b0; in_credit[p] <= 1'b0;
            end else begin
                if (in_v[p])  q_wr[p] <= (q_wr[p] == D - 1) ? 0 : q_wr[p] + 1'b1;
                if (pop[p])   q_rd[p] <= (q_rd[p] == D - 1) ? 0 : q_rd[p] + 1'b1;
                q_n[p]  <= q_n[p] + in_v[p] - pop[p];
                in_credit[p] <= pop[p];
                out_v[p] <= send[p];
                cred[p]  <= cred[p] - send[p] + out_credit[p];
                if (send[p]) last[p] <= sel[p];
            end
        end
    end

`ifdef FORMAL
    generate
        for (o = 0; o < 5; o = o + 1) begin : fo
            assign f_cred[o*CW +: CW] = cred[o];
            assign f_cnt[o*QW +: QW]  = q_n[o];
            for (i = 0; i < 5; i = i + 1) begin : fi
                assign f_want[i*5 + o] = want[i][o];
                assign f_gnt[i*5 + o]  = gnt[o][i];
            end
        end
        assign f_send = send;
        for (o = 0; o < 5; o = o + 1) begin : fl
            assign f_last[3*o +: 3] = last[o];
        end
    endgenerate
`endif
endmodule
