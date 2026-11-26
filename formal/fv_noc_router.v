// fv_noc_router.v - formal checks of one network router (rtl/noc_router.v)
// for any traffic, any router position and any downstream behaviour:
//   N1  an input queue never overflows: its flits + credits on the way back
//       + the upstream neighbour's credits = D;
//   N2  credits are never lost or made up: for each output, the router's
//       credits + flits on the link + flits in the next router's queue = D;
//   N3  every flit leaves by the port XY routing calls for (east/west first,
//       then north/south, local when it has arrived);
//   N4  flits are not created or lost inside the router: flits in = flits
//       out + flits held;
//   N5  fairness: while a flit waits at the head of input i for output o,
//       o sends at most 4 other flits before it (round robin over 5 inputs).
// Assumptions: upstream neighbours only send with credit (the protocol);
// the next routers free places in their queues whenever they like.
module fv_noc_router #(parameter D = 2) (
    input wire        clk,
    input wire [4:0]  in_v,
    input wire [5*FW-1:0] in_flit,
    input wire [4:0]  ds_pop,          // next router takes a flit from its queue
    input wire [1:0]  my_x, my_y
);
    localparam XW = 2, YW = 2, PW = 3, FW = XW + YW + PW;
    localparam CW = $clog2(D + 1), QW = $clog2(D + 1);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst = init;

    (* anyconst *) reg [1:0] kx, ky;
    always @(*) assume(my_x == kx && my_y == ky);

    wire [4:0] in_credit, out_v, out_credit;
    wire [5*FW-1:0] out_flit;
    wire [5*CW-1:0] f_cred;
    wire [5*QW-1:0] f_cnt;
    wire [24:0] f_want, f_gnt;
    wire [4:0]  f_send;
    wire [14:0] f_last;
    noc_router #(.XW(XW), .YW(YW), .PW(PW), .D(D)) dut (.clk(clk), .rst(rst),
        .my_x(my_x), .my_y(my_y), .in_v(in_v), .in_flit(in_flit), .in_credit(in_credit),
        .out_v(out_v), .out_flit(out_flit), .out_credit(out_credit)
        , .f_cred(f_cred), .f_cnt(f_cnt), .f_want(f_want), .f_gnt(f_gnt), .f_send(f_send), .f_last(f_last));

    // upstream credits (what each neighbour believes) and downstream queues
    reg [CW:0] up [0:4];
    reg [CW:0] dn [0:4];
    integer i;
    initial for (i = 0; i < 5; i = i + 1) begin up[i] = D; dn[i] = 0; end
    assign out_credit = ds_pop;
    always @(posedge clk)
        for (i = 0; i < 5; i = i + 1) begin
            up[i] <= rst ? D : up[i] - in_v[i] + in_credit[i];
            dn[i] <= rst ? 0 : dn[i] + out_v[i] - ds_pop[i];
        end
    always @(*) for (i = 0; i < 5; i = i + 1) begin
        if (!rst && in_v[i]) assume(up[i] > 0);
        if (!rst && ds_pop[i]) assume(dn[i] > 0);
        if (rst) assume(in_v[i] == 0 && ds_pop[i] == 0);
    end

    // which output a flit must take (XY)
    function [2:0] route;
        input [FW-1:0] f;
        reg [1:0] dx, dy;
        begin
            dx = f[FW-1 -: XW]; dy = f[FW-XW-1 -: YW];
            if (dx > kx) route = 3'd2; else if (dx < kx) route = 3'd4;
            else if (dy > ky) route = 3'd3; else if (dy < ky) route = 3'd1;
            else route = 3'd0;
        end
    endfunction
    // inputs never carry flits that would have to turn from Y back to X,
    // or go back where they came from: a neighbour on the X sides sends
    // only flits for other columns or this column; on the Y sides only
    // flits for this column (what XY routing upstream guarantees)
    always @(*) for (i = 1; i < 5; i = i + 1)
        if (in_v[i]) begin
            if (i == 1 || i == 3) assume(in_flit[i*FW + FW - 1 -: XW] == kx);
            if (i == 1) assume(in_flit[i*FW + FW - XW - 1 -: YW] >= ky);
            if (i == 3) assume(in_flit[i*FW + FW - XW - 1 -: YW] <= ky);
            if (i == 2) assume(in_flit[i*FW + FW - 1 -: XW] <= kx);
            if (i == 4) assume(in_flit[i*FW + FW - 1 -: XW] >= kx);
        end

    integer o;
    always @(*) if (!init) begin
        for (o = 0; o < 5; o = o + 1) begin
            assert(f_cnt[o*QW +: QW] + in_credit[o] + up[o] == D);      // N1
            assert(f_cnt[o*QW +: QW] <= D);
            assert(f_cred[o*CW +: CW] + out_v[o] + dn[o] == D);         // N2
            if (out_v[o]) assert(route(out_flit[o*FW +: FW]) == o);     // N3
        end
    end
    // N4: a flit only leaves when one was waiting (count check)
    reg [7:0] n_in = 0, n_out = 0;
    always @(posedge clk) if (!rst) begin
        n_in  <= n_in + in_v[0] + in_v[1] + in_v[2] + in_v[3] + in_v[4];
        n_out <= n_out + out_v[0] + out_v[1] + out_v[2] + out_v[3] + out_v[4];
    end
    wire [7:0] held = f_cnt[0 +: QW] + f_cnt[QW +: QW] + f_cnt[2*QW +: QW]
                    + f_cnt[3*QW +: QW] + f_cnt[4*QW +: QW];
    reg [7:0] n_link;
    always @(*) begin
        n_link = out_v[0] + out_v[1] + out_v[2] + out_v[3] + out_v[4];
        if (!init) assert(n_in == n_out + n_link + held);          // N4
    end
    // N5: overtakes[i][o] counts flits o sent while input i's head waited for it
    reg [2:0] ovt [0:24];
    integer a, b;
    initial for (a = 0; a < 25; a = a + 1) ovt[a] = 0;
    always @(posedge clk)
        for (a = 0; a < 5; a = a + 1)
            for (b = 0; b < 5; b = b + 1)
                if (rst || !f_want[a*5+b] || f_gnt[a*5+b]) ovt[a*5+b] <= 0;
                else if (f_send[b]) ovt[a*5+b] <= ovt[a*5+b] + 1;
    always @(*) if (!init)
        for (a = 0; a < 25; a = a + 1) begin
            assert(ovt[a] <= 4);                                     // N5
            // helper for the induction: passed over + distance from the
            // round-robin pointer to input a/5 never exceeds 4
            if (f_want[a]) assert(ovt[a] + ((a / 5 + 4 - f_last[3*(a%5) +: 3]) % 5) <= 4);
            assert(f_last[3*(a%5) +: 3] <= 4);
        end
    always @(*) cover(!init && out_v[2] && out_v[3]);
endmodule
