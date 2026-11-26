// tb_noc.v - random traffic through noc_mesh.v, every flit checked
// Settings: -DMX=4 -DMY=4   plusargs: +RATE=<percent> +PAT=<0|1|2> +SEED=<n> +CYC=<n>
//   PAT 0: uniform (any node to any node)
//   PAT 1: transpose ((x, y) -> (y, x); square meshes)
//   PAT 2: to the edges (every node sends to a node in the first or last
//          column, where the memory controllers sit, D-028)
// Each flit carries its source, a sequence number per (source, destination)
// pair and the tick it entered the network. The checker requires: right
// destination, each pair's flits in order with none missing or repeated, and
// every flit delivered after injection stops. It prints throughput and
// latency (ticks from entering the network to leaving it, without the wait
// at the source).
`timescale 1ns/1ps
module tb_noc;
`ifndef MX
`define MX 4
`endif
`ifndef MY
`define MY 4
`endif
    localparam X = `MX, Y = `MY, NN = X * Y;
    localparam XW = 5, YW = 5, PW = 64, D = 4, FW = XW + YW + PW;
    reg clk = 0, rst = 1;
    always #1 clk = ~clk;

    reg  [NN-1:0]    in_v;
    reg  [NN*FW-1:0] in_f;
    wire [NN-1:0]    in_c;
    wire [NN-1:0]    out_v;
    wire [NN*FW-1:0] out_f;
    reg  [NN-1:0]    out_c;
    noc_mesh #(.X(X), .Y(Y), .XW(XW), .YW(YW), .PW(PW), .D(D)) dut (
        .clk(clk), .rst(rst), .loc_in_v(in_v), .loc_in_flit(in_f), .loc_in_credit(in_c),
        .loc_out_v(out_v), .loc_out_flit(out_f), .loc_out_credit(out_c));

    integer rate, pat, seed, cyc, t, n, m, errors, sent, got, waiting, last_got;
    integer cred [0:NN-1];
    integer pend [0:NN-1];                  // flits generated, not yet sent
    reg [21:0] sseq [0:NN*NN-1];            // next sequence number to send, per pair
    reg [21:0] rseq [0:NN*NN-1];            // next expected, per pair
    reg [63:0] lat_sum;
    integer lat_max, dst, sx, sy, dx, dy, src;
    reg [FW-1:0] f;
    reg inject;

    function integer pick_dst;
        input integer s;
        integer r, ex, ey;
        begin
            ex = s % X; ey = s / X;
            if (pat == 1) pick_dst = (X == Y) ? ex * X + ey : s;
            else if (pat == 2) begin
                r = $urandom % (2 * Y);
                pick_dst = (r % Y) * X + ((r < Y) ? 0 : X - 1);
            end else pick_dst = $urandom % NN;
        end
    endfunction

    initial begin
        if (!$value$plusargs("RATE=%d", rate)) rate = 20;
        if (!$value$plusargs("PAT=%d", pat)) pat = 0;
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        if (!$value$plusargs("CYC=%d", cyc)) cyc = 3000;
        m = $urandom(seed);
        errors = 0; sent = 0; got = 0; last_got = 0; lat_sum = 0; lat_max = 0;
        for (n = 0; n < NN; n = n + 1) begin cred[n] = D; pend[n] = 0; end
        for (n = 0; n < NN * NN; n = n + 1) begin sseq[n] = 0; rseq[n] = 0; end
        in_v = 0; in_f = 0; out_c = 0;
        repeat (3) @(posedge clk);
        rst = 0;
        for (t = 0; t < cyc + 20000; t = t + 1) begin
            @(negedge clk);
            inject = (t < cyc);
            // credits back from the routers' local queues
            for (n = 0; n < NN; n = n + 1) if (in_c[n]) cred[n] = cred[n] + 1;
            // deliveries: check and give the credit back next tick
            out_c = 0;
            for (n = 0; n < NN; n = n + 1) if (out_v[n]) begin
                f = out_f[n*FW +: FW];
                dx = f[FW-1 -: XW]; dy = f[FW-XW-1 -: YW];
                src = f[63:54];
                if (dx != n % X || dy != n / X) begin
                    errors = errors + 1;
                    if (errors < 5) $display("ERROR wrong node: flit for (%0d,%0d) at node %0d", dx, dy, n);
                end
                if (f[53:32] != rseq[src*NN + n]) begin
                    errors = errors + 1;
                    if (errors < 5) $display("ERROR order: %0d -> %0d got #%0d, expected #%0d",
                                             src, n, f[53:32], rseq[src*NN + n]);
                end
                rseq[src*NN + n] = f[53:32] + 1;
                got = got + 1;
                lat_sum = lat_sum + (t - f[31:0]);
                if (t - f[31:0] > lat_max) lat_max = t - f[31:0];
                out_c[n] = 1'b1;
            end
            // new traffic
            in_v = 0;
            for (n = 0; n < NN; n = n + 1) begin
                if (inject && ($urandom % 100) < rate) pend[n] = pend[n] + 1;
                if (pend[n] > 0 && cred[n] > 0) begin
                    dst = pick_dst(n);
                    f = 0;
                    f[FW-1 -: XW] = dst % X; f[FW-XW-1 -: YW] = dst / X;
                    f[63:54] = n; f[53:32] = sseq[n*NN + dst]; f[31:0] = t + 1;
                    sseq[n*NN + dst] = sseq[n*NN + dst] + 1;
                    in_f[n*FW +: FW] = f; in_v[n] = 1'b1;
                    cred[n] = cred[n] - 1; pend[n] = pend[n] - 1; sent = sent + 1;
                end
            end
            if (got != last_got) last_got = t;
            if (!inject && t - last_got > 2000) begin
                $display("ERROR network stopped: nothing delivered for 2000 ticks");
                t = cyc + 20000;
            end
            if (!inject && got == sent) begin
                waiting = 0;
                for (n = 0; n < NN; n = n + 1) waiting = waiting + pend[n];
                if (waiting == 0) t = cyc + 20000;
            end
        end
        if (got != sent) begin
            errors = errors + 1;
            $display("ERROR %0d flits sent, %0d delivered", sent, got);
        end
        $display("NOC %0dx%0d pattern %0d offered %0d%%: %0d flits, %0d errors; accepted %0.3f flits/node/tick, latency mean %0.1f max %0d ticks",
                 X, Y, pat, rate, got, errors, got * 1.0 / NN / cyc, lat_sum * 1.0 / (got > 0 ? got : 1), lat_max);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
