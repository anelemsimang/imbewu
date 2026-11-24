// tb_cluster.v - several tiles sharing one main memory (rtl/cluster.v).
// The memory model accepts up to B requests per tick (B channels, set by
// -DCHANNELS) and answers each read LAT ticks later, on the lane of the
// channel it came in on (so in the order issued); the cluster passes each
// answer on to the tiles waiting for it.
// Settings: -DGRID_N=4 -DTILES=2 -DCHANNELS=1 -DBCAST=1 (merge identical
// reads)   plusargs: +PRE=<prefix> +LAT=<ticks>
`timescale 1ns/1ps
`ifndef GRID_N
`define GRID_N 4
`endif
`ifndef TILES
`define TILES 2
`endif
`ifndef CHANNELS
`define CHANNELS 1
`endif
`ifndef BCAST
`define BCAST 1
`endif
module tb_cluster;
    localparam N = `GRID_N, T = `TILES, B = `CHANNELS, EAW = 20, W8 = N * 8;
    reg clk = 0, rst = 1, start = 0;
    reg [T-1:0] cmd_we = 0; reg [4*T-1:0] cmd_idx = 0; reg [200*T-1:0] cmd_data = 0; reg [5*T-1:0] n_cmds = 0;
    wire busy, done;
    wire [B-1:0] m_req, m_we;
    wire [B*EAW-1:0] m_addr;
    wire [B*W8-1:0] m_wdata;
    reg  [B-1:0] m_rvalid = 0;
    reg  [B*W8-1:0] m_rdata = 0;
    wire [32*T-1:0] ticks_engine;
    wire [31:0] ticks;

    cluster #(.N(N), .T(T), .B(B), .EAW(EAW), .BC(`BCAST)) dut (.clk(clk), .rst(rst), .cmd_we(cmd_we),
        .cmd_idx(cmd_idx), .cmd_data(cmd_data), .n_cmds(n_cmds), .start(start), .busy(busy),
        .done(done), .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
        .m_rvalid(m_rvalid), .m_rdata(m_rdata), .ticks_engine(ticks_engine), .ticks(ticks));
    always #5 clk = ~clk;

    // ---- main memory: B channels, fixed delay, answers in the order issued -------
    reg [W8-1:0] mem [0:(1<<EAW)-1];
    reg [W8-1:0] pd [0:B-1][0:127];
    reg          pv [0:B-1][0:127];
    integer lat = 40, q, j, reads = 0, writes = 0;
    always @(posedge clk) begin
        for (j = 0; j < B; j = j + 1) begin
            for (q = 127; q > 0; q = q - 1) begin pd[j][q] <= pd[j][q-1]; pv[j][q] <= pv[j][q-1]; end
            pv[j][0] <= 1'b0;
            if (m_req[j]) begin
                if (m_we[j]) begin mem[m_addr[EAW*j +: EAW]] <= m_wdata[W8*j +: W8]; writes = writes + 1; end
                else begin
                    pd[j][0] <= mem[m_addr[EAW*j +: EAW]];
                    pv[j][0] <= 1'b1;
                    reads = reads + 1;
                end
            end
            m_rvalid[j] <= pv[j][lat - 1];
            m_rdata[W8*j +: W8] <= pd[j][lat - 1];
        end
    end
    integer jq;
    initial for (jq = 0; jq < B; jq = jq + 1) for (q = 0; q < 128; q = q + 1) pv[jq][q] = 0;

    // ---- the test -----------------------------------------------------------------
    reg [199:0] cmds [0:15];
    reg [EAW+W8-1:0] expv [0:65535];
    reg [31:0] meta [0:40];
    initial for (k = 0; k < 41; k = k + 1) meta[k] = 0;
    reg [1023:0] pre;
    reg [8*8-1:0] num;
    integer k, n, nexp, errors = 0, fed = 0, tt;   // tt: own loop counter (t belongs to the memory model)
    initial begin
        if (!$value$plusargs("PRE=%s", pre)) begin $display("need +PRE="); $finish; end
        if (!$value$plusargs("LAT=%d", lat)) lat = 40;
        $readmemh({pre, "_meta.hex"}, meta, 0, 3 + T);
        if (meta[0] != T) begin $display("vectors are for %0d tiles", meta[0]); $display("FAIL"); $finish; end
        nexp = meta[2];
        $readmemh({pre, "_mem.hex"}, mem, 0, meta[1] - 1);
        $readmemh({pre, "_exp.hex"}, expv, 0, nexp - 1);
        repeat (3) @(posedge clk); #1 rst = 0;
        for (tt = 0; tt < T; tt = tt + 1) begin
            num = "0" + tt;
            $readmemh({pre, "_cmd", num[7:0], ".hex"}, cmds, 0, meta[4 + tt] - 1);
            for (k = 0; k < meta[4 + tt]; k = k + 1) begin
                cmd_we = 0; cmd_we[tt] = 1'b1;
                cmd_idx[4*tt +: 4] = k; cmd_data[200*tt +: 200] = cmds[k];
                @(posedge clk); #1;
            end
            n_cmds[5*tt +: 5] = meta[4 + tt];
        end
        cmd_we = 0;
        start = 1; @(posedge clk); #1 start = 0;
        wait (done); @(posedge clk); #1;
        for (n = 0; n < nexp; n = n + 1)
            if (mem[expv[n][EAW+W8-1:W8]] !== expv[n][W8-1:0]) errors = errors + 1;
        for (tt = 0; tt < T; tt = tt + 1) fed = fed + ticks_engine[32*tt +: 32];
        $display("CLUSTER %0d tiles of %0dx%0d, %0d memory channel(s): %0d answer words checked, %0d errors",
                 T, N, N, B, nexp, errors);
        $display("CLUSTER %0d tiles, %0d channel(s), broadcast %0d: %0d ticks; engines fed %0d of %0d tile-ticks (%0d%%); memory %0d reads, %0d writes",
                 T, B, `BCAST, ticks, fed, T * ticks, 100 * fed / (T * ticks), reads, writes);
        if (errors == 0 && fed == meta[3]) $display("PASS"); else $display("FAIL");
        $finish;
    end
    // time limit: +MAXT=<ticks> (default 2,000,000)
    integer maxt;
    initial begin
        if (!$value$plusargs("MAXT=%d", maxt)) maxt = 2000000;
        #(10 * maxt); $display("TIMEOUT (cluster stuck)");
        $display("  requests %b, accepted %b; tile 0: commands loaded %0d computed %0d stored %0d",
                 dut.t_req, dut.t_ready, dut.tile[0].u.nld, dut.tile[0].u.ncomp, dut.tile[0].u.nst);
        $display("  reads in flight %0d", dut.u_share.cnt);
        $display("FAIL"); $finish;
    end
endmodule
