// tb_matmul_unit.v - checks the tiling controller + engine on a whole matrix
// multiply. Memories here are simple models of on-chip SRAM: one read per
// tick, answer one tick later. Expected C from tools/gen_tile_vectors.py.
// Settings: -DGRID_N=8   plusarg: +PRE=<prefix>
`timescale 1ns/1ps
`ifndef GRID_N
`define GRID_N 4
`endif
module tb_matmul_unit;
    localparam N = `GRID_N, AW = 16, DEPTH = 65536;
    reg clk = 0, rst = 1, start = 0;
    reg [7:0] cfg_mt, cfg_nt;
    reg [AW-1:0] cfg_beats, cfg_bb, cfg_nb;
    reg [1:0] cfg_fa, cfg_fb;
    wire busy, done;
    wire [AW-1:0] a_addr, b_addr, sa_addr, sb_addr;
    reg  [N*8-1:0] a_data, b_data, sa_data, sb_data;
    wire c_we;
    wire [AW-1:0] c_addr;
    wire [N*32-1:0] c_data;

`ifdef GATE
    matmul_unit dut (                 // gate-level netlist: settings fixed at synthesis
`else
    matmul_unit #(.N(N), .AW(AW)) dut (
`endif
       .clk(clk), .rst(rst), .start(start),
        .cfg_mt(cfg_mt), .cfg_nt(cfg_nt), .cfg_beats(cfg_beats), .cfg_bb(cfg_bb),
        .cfg_nb(cfg_nb), .cfg_fa(cfg_fa), .cfg_fb(cfg_fb), .cfg_pk(1'b0), .busy(busy), .done(done),
        .a_addr(a_addr), .a_data(a_data), .b_addr(b_addr), .b_data(b_data),
        .sa_addr(sa_addr), .sa_data(sa_data), .sb_addr(sb_addr), .sb_data(sb_data),
        .c_we(c_we), .c_addr(c_addr), .c_data(c_data));
    always #5 clk = ~clk;

    // SRAM models
    reg [N*8-1:0]  amem [0:DEPTH-1], bmem [0:DEPTH-1], samem [0:4095], sbmem [0:4095];
    reg [N*32-1:0] cmem [0:16383], cexp [0:16383];
    reg [31:0]     cfg [0:6];
    always @(posedge clk) begin
        a_data  <= amem[a_addr];
        b_data  <= bmem[b_addr];
        sa_data <= samem[sa_addr];
        sb_data <= sbmem[sb_addr];
        if (c_we) cmem[c_addr] <= c_data;
    end

    reg [1023:0] pre;
    integer cyc = 0, t0, t1, n, rows, errors = 0, writes = 0;
    // count the engine's answer writes once reset is over (during reset its
    // outputs may hold any start-up value, as on real silicon)
    always @(posedge clk) begin cyc <= cyc + 1; if (c_we && !rst) writes = writes + 1; end
    initial begin
        if (!$value$plusargs("PRE=%s", pre)) begin $display("need +PRE="); $finish; end
        $readmemh({pre, "_cfg.hex"}, cfg);
        cfg_mt = cfg[0]; cfg_nt = cfg[1]; cfg_beats = cfg[2]; cfg_bb = cfg[3];
        cfg_nb = cfg[4]; cfg_fa = cfg[5]; cfg_fb = cfg[6];
        rows = cfg_mt * N * cfg_nt;
        $readmemh({pre, "_a.hex"},  amem, 0, cfg_mt * cfg_beats - 1);
        $readmemh({pre, "_b.hex"},  bmem, 0, cfg_nt * cfg_beats - 1);
        $readmemh({pre, "_sa.hex"}, samem, 0, cfg_mt * cfg_nb - 1);
        $readmemh({pre, "_sb.hex"}, sbmem, 0, cfg_nt * cfg_nb - 1);
        $readmemh({pre, "_c.hex"},  cexp, 0, rows - 1);
        for (n = 0; n < rows; n = n + 1) cmem[n] = {N*32{1'bx}};
        repeat (3) @(posedge clk); #1 rst = 0;
        @(posedge clk); #1 start = 1; t0 = cyc;
        @(posedge clk); #1 start = 0;
        wait (done); t1 = cyc;
        @(posedge clk); #1;
        for (n = 0; n < rows; n = n + 1)
            if (cmem[n] !== cexp[n]) begin
                errors = errors + 1;
                if (errors < 5) $display("MISMATCH C word %0d: got %h want %h", n, cmem[n], cexp[n]);
            end
        if (writes != rows) begin errors = errors + 1; $display("WRITES %0d expected %0d", writes, rows); end
        $display("MATMUL %0dx%0d engine, %0d x %0d tiles, %0d beats per job: %0d C words checked, %0d errors",
                 N, N, cfg_mt, cfg_nt, cfg_beats, rows, errors);
        $display("MATMUL %0dx%0d: %0d ticks from start to done, %0d of them feeding the engine (%0d%%)",
                 N, N, t1 - t0, cfg_mt * cfg_nt * cfg_beats,
                 100 * cfg_mt * cfg_nt * cfg_beats / (t1 - t0));
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
    initial begin #50000000; $display("TIMEOUT"); $display("FAIL"); $finish; end
endmodule
