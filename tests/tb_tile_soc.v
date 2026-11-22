// tb_tile_soc.v - the tile run by its own RISC-V core and driver program.
// The testbench only loads the program and main memory, then waits for the
// program to report. It checks (1) that the commands the program wrote into
// the tile equal the ones the Python test generator made, and (2) every
// answer in main memory.
// Settings: -DGRID_N=4   plusargs: +PRE=<vectors prefix> +FW=<program hex>
`timescale 1ns/1ps
`ifndef GRID_N
`define GRID_N 4
`endif
module tb_tile_soc;
    localparam N = `GRID_N, EAW = 20, W8 = N * 8;
    reg clk = 0, rst = 1;
    wire mem_req, mem_we, mem_ready, exit_valid;
    wire [EAW-1:0] mem_addr;
    wire [W8-1:0] mem_wdata;
    reg  mem_rvalid = 0; reg [W8-1:0] mem_rdata = 0;
    wire [31:0] exit_code;

    tile_soc #(.N(N), .EAW(EAW)) dut (.clk(clk), .rst(rst),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_ready(mem_ready), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .exit_valid(exit_valid), .exit_code(exit_code));
    always #5 clk = ~clk;

    // main memory: answers reads 40 ticks later, one request per tick
    reg [W8-1:0] mem [0:(1<<EAW)-1];
    reg [W8-1:0] pipe_d [0:63];
    reg          pipe_v [0:63];
    integer q, cyc = 0;
    assign mem_ready = 1'b1;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        for (q = 63; q > 0; q = q - 1) begin pipe_d[q] <= pipe_d[q-1]; pipe_v[q] <= pipe_v[q-1]; end
        pipe_v[0] <= 1'b0;
        if (mem_req && mem_ready) begin
            if (mem_we) mem[mem_addr] <= mem_wdata;
            else begin pipe_d[0] <= mem[mem_addr]; pipe_v[0] <= 1'b1; end
        end
        mem_rvalid <= pipe_v[39];
        mem_rdata  <= pipe_d[39];
    end
    initial for (q = 0; q < 64; q = q + 1) pipe_v[q] = 0;

    reg [199:0] cmds_exp [0:15];
    reg [EAW+W8-1:0] expv [0:65535];
    reg [31:0] meta [0:3];
    reg [1023:0] pre, fw;
    integer k, n, errors = 0, cmd_errors = 0, t_start;
    initial begin
        if (!$value$plusargs("PRE=%s", pre) || !$value$plusargs("FW=%s", fw)) begin
            $display("need +PRE= +FW="); $finish;
        end
        $readmemh(fw, dut.ram);
        $readmemh({pre, "_meta.hex"}, meta);
        $readmemh({pre, "_mem.hex"}, mem, 0, meta[1] - 1);
        $readmemh({pre, "_cmd.hex"}, cmds_exp, 0, meta[0] - 1);
        $readmemh({pre, "_exp.hex"}, expv, 0, meta[2] - 1);
        repeat (3) @(posedge clk); #1 rst = 0; t_start = cyc;
        wait (exit_valid);
        @(posedge clk); #1;
        for (k = 0; k < meta[0]; k = k + 1)
            if (dut.u_tile.cmds[k] !== cmds_exp[k]) begin
                cmd_errors = cmd_errors + 1;
                if (cmd_errors < 4) $display("COMMAND %0d differs: program %h, generator %h",
                                             k, dut.u_tile.cmds[k], cmds_exp[k]);
            end
        for (n = 0; n < meta[2]; n = n + 1)
            if (mem[expv[n][EAW+W8-1:W8]] !== expv[n][W8-1:0]) errors = errors + 1;
        $display("SOC %0dx%0d: program returned %h after %0d ticks (tile busy %0d, engine fed %0d)",
                 N, N, exit_code, cyc - t_start, dut.u_tile.ticks_busy, dut.u_tile.ticks_engine);
        $display("SOC %0dx%0d: %0d commands written by the program, %0d differ from the generator; %0d answer words checked, %0d errors",
                 N, N, meta[0], cmd_errors, meta[2], errors);
        if (errors == 0 && cmd_errors == 0 && exit_code == (32'h600D0000 | meta[0])) $display("PASS");
        else $display("FAIL");
        $finish;
    end
    initial begin #20000000; $display("TIMEOUT"); $display("FAIL"); $finish; end
endmodule
