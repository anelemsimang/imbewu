// tb_vu.v - runs one vector-unit program (rtl/vu_v1.v, or vu_v2.v with -DVU_V2) and dumps memory.
// Settings: -DLANES=4   plusargs: +PRE=<prefix>  (reads _imem.hex, _cmem.hex,
// _vmem.hex; writes _out.hex with all 256 vectors after the program)
`timescale 1ns/1ps
`ifndef LANES
`define LANES 4
`endif
module tb_vu;
    localparam L = `LANES;
    reg clk = 0, rst = 1, start = 0;
    reg imem_we = 0, cmem_we = 0, vmem_we = 0;
    reg [9:0] imem_addr = 0; reg [5:0] cmem_addr = 0; reg [7:0] vmem_addr = 0;
    reg [31:0] imem_data = 0, cmem_data = 0; reg [L*32-1:0] vmem_wdata = 0;
    wire [L*32-1:0] vmem_rdata;
    wire busy; wire [15:0] ticks;
`ifdef VU_V2
    vu_v2 #(.L(L)) dut (
`else
    vu_v1 #(.L(L)) dut (
`endif.clk(clk), .rst(rst), .imem_we(imem_we), .imem_addr(imem_addr),
        .imem_data(imem_data), .cmem_we(cmem_we), .cmem_addr(cmem_addr), .cmem_data(cmem_data),
        .vmem_we(vmem_we), .vmem_addr(vmem_addr), .vmem_wdata(vmem_wdata), .vmem_rdata(vmem_rdata),
        .start(start), .busy(busy), .ticks(ticks));
    always #5 clk = ~clk;
    reg [31:0] im [0:1023], cm [0:63];
    reg [L*32-1:0] vm [0:255];
    reg [1023:0] pre;
    integer n, fd;
    initial begin
        if (!$value$plusargs("PRE=%s", pre)) begin $display("need +PRE="); $finish; end
        for (n = 0; n < 1024; n = n + 1) im[n] = 0;
        for (n = 0; n < 64; n = n + 1) cm[n] = 0;
        $readmemh({pre, "_imem.hex"}, im);
        $readmemh({pre, "_cmem.hex"}, cm);
        $readmemh({pre, "_vmem.hex"}, vm);
        repeat (2) @(posedge clk); #1 rst = 0;
        for (n = 0; n < 1024; n = n + 1) begin imem_we = 1; imem_addr = n; imem_data = im[n]; @(posedge clk); #1; end
        imem_we = 0;
        for (n = 0; n < 64; n = n + 1) begin cmem_we = 1; cmem_addr = n; cmem_data = cm[n]; @(posedge clk); #1; end
        cmem_we = 0;
        for (n = 0; n < 256; n = n + 1) begin vmem_we = 1; vmem_addr = n; vmem_wdata = vm[n]; @(posedge clk); #1; end
        vmem_we = 0;
        start = 1; @(posedge clk); #1 start = 0;
        wait (!busy); @(posedge clk); #1;
        fd = $fopen({pre, "_out.hex"}, "w");
        for (n = 0; n < 256; n = n + 1) begin vmem_addr = n; #1 $fwrite(fd, "%h\n", vmem_rdata); end
        $fclose(fd);
        $display("VU %0d lanes: program finished in %0d ticks", L, ticks);
        $finish;
    end
    initial begin #50000000; $display("TIMEOUT"); $finish; end
endmodule
