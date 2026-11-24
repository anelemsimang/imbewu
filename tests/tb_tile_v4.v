// tb_tile_v4.v - checks tile_v4 (vector unit inside the tile) on a chain of
// layers (tools/gen_tile_v4_vectors.py): loads the vector unit's program,
// constants and fixed data, runs the command list, then checks every word
// of the intermediate results and the final answers in main memory.
// Settings: -DGRID_N=4   plusargs: +PRE=<prefix> +LAT=<ticks> +EVERY=<k>
`timescale 1ns/1ps
`ifndef GRID_N
`define GRID_N 4
`endif
module tb_tile_v4;
    localparam N = `GRID_N, EAW = 20, W8 = N * 8;
    reg clk = 0, rst = 1, start = 0;
    reg cmd_we = 0; reg [3:0] cmd_idx = 0; reg [223:0] cmd_data = 0; reg [4:0] n_cmds = 0;
    wire busy, done, mem_req, mem_we, mem_ready;
    wire [EAW-1:0] mem_addr;
    wire [W8-1:0] mem_wdata;
    reg  mem_rvalid = 0; reg [W8-1:0] mem_rdata = 0;
    wire [31:0] ticks_busy, ticks_engine, ticks_post;
    reg vi_we = 0, vc_we = 0, vv_we = 0;
    reg [9:0] vi_a = 0; reg [5:0] vc_a = 0; reg [7:0] vv_a = 0;
    reg [31:0] vi_d = 0, vc_d = 0; reg [N*32-1:0] vv_d = 0;

`ifdef GATE
    tile_v4 dut (                     // gate-level netlist: settings fixed at synthesis
`else
    tile_v4 #(.N(N)) dut (
`endif
       
       .clk(clk), .rst(rst), .cmd_we(cmd_we), .cmd_idx(cmd_idx),
        .cmd_data(cmd_data), .n_cmds(n_cmds), .start(start), .busy(busy), .done(done),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_ready(mem_ready), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .vu_imem_we(vi_we), .vu_imem_addr(vi_a), .vu_imem_data(vi_d),
        .vu_cmem_we(vc_we), .vu_cmem_addr(vc_a), .vu_cmem_data(vc_d),
        .vu_vmem_we(vv_we), .vu_vmem_addr(vv_a), .vu_vmem_wdata(vv_d),
        .ticks_busy(ticks_busy), .ticks_engine(ticks_engine), .ticks_post(ticks_post));
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
    reg [223:0] cmds [0:15];
    reg [31:0] vui [0:1023], vuc [0:63];
    reg [8+N*32-1:0] vuv [0:255];
    reg [EAW+W8-1:0] expv [0:65535];
    reg [31:0] meta [0:6];
    reg [1023:0] pre;
    integer k, n, nexp, errors = 0, t0, dfd;
    reg [1023:0] dname;
    initial begin
        if (!$value$plusargs("PRE=%s", pre)) begin $display("need +PRE="); $finish; end
        if (!$value$plusargs("LAT=%d", lat)) lat = 20;
        if (!$value$plusargs("EVERY=%d", every)) every = 1;
        $readmemh({pre, "_meta.hex"}, meta);
        nexp = meta[2];
        $readmemh({pre, "_mem.hex"}, mem, 0, meta[1] - 1);
        $readmemh({pre, "_cmd.hex"}, cmds, 0, meta[0] - 1);
        $readmemh({pre, "_exp.hex"}, expv, 0, nexp - 1);
        $readmemh({pre, "_vui.hex"}, vui, 0, meta[4] - 1);
        $readmemh({pre, "_vuc.hex"}, vuc, 0, meta[5] - 1);
        if (meta[6] > 0) $readmemh({pre, "_vuv.hex"}, vuv, 0, meta[6] - 1);
        repeat (3) @(posedge clk); #1 rst = 0;
        for (k = 0; k < meta[4]; k = k + 1) begin vi_we = 1; vi_a = k; vi_d = vui[k]; @(posedge clk); #1; end
        vi_we = 0;
        for (k = 0; k < meta[5]; k = k + 1) begin vc_we = 1; vc_a = k; vc_d = vuc[k]; @(posedge clk); #1; end
        vc_we = 0;
        for (k = 0; k < meta[6]; k = k + 1) begin
            vv_we = 1; vv_a = vuv[k][8+N*32-1:N*32]; vv_d = vuv[k][N*32-1:0]; @(posedge clk); #1;
        end
        vv_we = 0;
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
        $display("TILE_V4 %0dx%0d: %0d commands, %0d words checked (intermediate and final), %0d errors (latency %0d, 1 request per %0d ticks)",
                 N, N, meta[0], nexp, errors, lat, every);
        $display("TILE_V4 %0dx%0d: %0d ticks busy, engine fed on %0d (%0d%%), post-processing %0d; memory: %0d reads, %0d writes",
                 N, N, ticks_busy, ticks_engine, 100 * ticks_engine / ticks_busy, ticks_post, reads, writes);
        // optional: write every answer word, in the order of the _exp file
        if ($value$plusargs("DUMP=%s", dname)) begin
            dfd = $fopen(dname, "w");
            for (n = 0; n < nexp; n = n + 1) $fwrite(dfd, "%h\n", mem[expv[n][EAW+W8-1:W8]]);
            $fclose(dfd);
        end
        if (errors == 0 && ticks_engine == meta[3]) $display("PASS"); else $display("FAIL");
        $finish;
    end
    initial begin #5000000; $display("TIMEOUT (tile stuck)"); $display("FAIL"); $finish; end
endmodule
