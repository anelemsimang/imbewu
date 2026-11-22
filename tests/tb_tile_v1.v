// tb_tile_v1.v - checks the Imbewu tile on a list of matrix multiplies, with
// a model of main memory (HBM) that answers each read LAT ticks later and
// accepts a request only on some ticks (limited bandwidth).
// Settings: -DGRID_N=4 [-DTILE_V2]   plusargs: +PRE=<prefix> +LAT=<ticks> +EVERY=<k>
//   (main memory accepts one request every k ticks: bandwidth 1/k words/tick)
`timescale 1ns/1ps
`ifndef GRID_N
`define GRID_N 4
`endif
module tb_tile_v1;
    localparam N = `GRID_N, EAW = 20, W8 = N * 8;
    reg clk = 0, rst = 1, start = 0;
    reg cmd_we = 0; reg [3:0] cmd_idx = 0; reg [199:0] cmd_data = 0; reg [4:0] n_cmds = 0;
    wire busy, done, mem_req, mem_we, mem_ready;
    wire [EAW-1:0] mem_addr;
    wire [W8-1:0] mem_wdata;
    reg  mem_rvalid = 0; reg [W8-1:0] mem_rdata = 0;
    wire [31:0] ticks_busy, ticks_engine;

`ifdef TILE_V3
    tile_v3 #(.N(N)) dut (
`elsif TILE_V2
    tile_v2 #(.N(N)) dut (
`else
    tile_v1 #(.N(N)) dut (
`endif
       .clk(clk), .rst(rst), .cmd_we(cmd_we), .cmd_idx(cmd_idx),
        .cmd_data(cmd_data), .n_cmds(n_cmds), .start(start), .busy(busy), .done(done),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_ready(mem_ready), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .ticks_busy(ticks_busy), .ticks_engine(ticks_engine));
    always #5 clk = ~clk;

    // ---- main-memory model --------------------------------------------------
    reg [W8-1:0] mem [0:(1<<EAW)-1];
    integer lat = 20, every = 1, cyc = 0, reads = 0, writes = 0;
    assign mem_ready = (cyc % every) == 0;
    reg [W8-1:0] pipe_d [0:255];
    reg          pipe_v [0:255];
    integer q;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        for (q = 255; q > 0; q = q - 1) begin pipe_d[q] <= pipe_d[q-1]; pipe_v[q] <= pipe_v[q-1]; end
        pipe_v[0] <= 1'b0;
        if (mem_req && mem_ready) begin
            if (mem_we) begin mem[mem_addr] <= mem_wdata; writes = writes + 1; end
            else begin pipe_d[0] <= mem[mem_addr]; pipe_v[0] <= 1'b1; reads = reads + 1; end
        end
        mem_rvalid <= pipe_v[lat - 1];
        mem_rdata  <= pipe_d[lat - 1];
    end
    initial for (q = 0; q < 256; q = q + 1) pipe_v[q] = 0;

    // ---- the test --------------------------------------------------------------
    reg [199:0] cmds [0:15];
    reg [EAW+W8-1:0] expv [0:65535];
    reg [31:0] meta [0:3];
    reg [1023:0] pre;
    integer k, n, nexp, errors = 0, t0;
    initial begin
        if (!$value$plusargs("PRE=%s", pre)) begin $display("need +PRE="); $finish; end
        if (!$value$plusargs("LAT=%d", lat)) lat = 20;
        if (!$value$plusargs("EVERY=%d", every)) every = 1;
        $readmemh({pre, "_meta.hex"}, meta);
        nexp = meta[2];
        $readmemh({pre, "_mem.hex"}, mem, 0, meta[1] - 1);
        $readmemh({pre, "_cmd.hex"}, cmds, 0, meta[0] - 1);
        $readmemh({pre, "_exp.hex"}, expv, 0, nexp - 1);
        repeat (3) @(posedge clk); #1 rst = 0;
        for (k = 0; k < meta[0]; k = k + 1) begin
            cmd_we = 1; cmd_idx = k; cmd_data = cmds[k];
            @(posedge clk); #1;
        end
        cmd_we = 0; n_cmds = meta[0];
        start = 1; t0 = cyc; @(posedge clk); #1 start = 0;
        wait (done); @(posedge clk); #1;
        for (n = 0; n < nexp; n = n + 1)
            if (mem[expv[n][EAW+W8-1:W8]] !== expv[n][W8-1:0]) begin
                errors = errors + 1;
                if (errors < 5) $display("MISMATCH at memory word %h: got %h want %h",
                                         expv[n][EAW+W8-1:W8], mem[expv[n][EAW+W8-1:W8]], expv[n][W8-1:0]);
            end
        $display("TILE %0dx%0d: %0d commands, %0d answer words checked, %0d errors (latency %0d, 1 request per %0d ticks)",
                 N, N, meta[0], nexp, errors, lat, every);
        $display("TILE %0dx%0d: %0d ticks busy, engine fed on %0d (%0d%%); memory: %0d reads, %0d writes",
                 N, N, ticks_busy, ticks_engine, 100 * ticks_engine / ticks_busy, reads, writes);
        if (errors == 0 && ticks_engine == meta[3]) $display("PASS"); else $display("FAIL");
        $finish;
    end
    initial begin #5000000; $display("TIMEOUT (tile stuck)"); $display("FAIL"); $finish; end
endmodule
