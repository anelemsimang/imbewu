// tb_systolic_v4.v - drives the version 4 engine with vectors from
// tools/gen_v4_vectors.py and checks every FP32 result bit for bit.
// Settings: -DGRID_N=8, and -DV5 [-DGROUP=16] to test version 5 instead
// Plusargs: +PRE=<prefix>  optional +DUMP=<file>
`timescale 1ns/1ps
`ifndef GRID_N
`define GRID_N 4
`endif
module tb_systolic_v4;
    localparam N = `GRID_N, IW = $clog2(N) + 1;
    localparam SW = 7 + 4*N*8, EW = N*32;
    localparam MAXB = 65536, MAXR = 8192;

    reg clk = 0, rst = 1;
    reg in_valid = 0, in_bl = 0, in_jl = 0;
    reg [1:0] in_fa = 0, in_fb = 0;
    reg [N*8-1:0] a_col = 0, b_row = 0, a_sc = 0, b_sc = 0;
    wire out_valid;
    wire [IW-1:0] out_row_idx;
    wire [N*32-1:0] out_row;

`ifdef V5
    // version 5: same interface and answers, shared adders (-DV5 -DGROUP=16)
`ifndef GROUP
`define GROUP 16
`endif
    systolic_v5 #(.N(N), .G(`GROUP)) dut (
`else
    systolic_v4 #(.N(N)) dut (
`endif
        .clk(clk), .rst(rst), .in_valid(in_valid),
        .in_blk_last(in_bl), .in_job_last(in_jl), .in_fa(in_fa), .in_fb(in_fb),
`ifdef V5
        .in_ph(1'b0),
`endif
        .a_col(a_col), .b_row(b_row), .in_a_scale(a_sc), .in_b_scale(b_sc),
        .out_valid(out_valid), .out_row_idx(out_row_idx), .out_row(out_row));
    always #5 clk = ~clk;
`ifdef V5
    localparam VER = "V5";
`else
    localparam VER = "V4";
`endif

    reg [SW-1:0] stim [0:MAXB-1];
    reg [EW-1:0] expv [0:MAXR-1];
    reg [63:0]   meta [0:3];
    reg [1023:0] pre, dump_name;
    integer dump_fd = 0;
    integer nb, nr, macs, b, r_seen, errors, cyc, first_in, last_out;

    always @(posedge clk) cyc <= rst ? 0 : cyc + 1;

    always @(posedge clk) if (!rst && out_valid) begin
        if (r_seen >= nr) begin
            errors = errors + 1; $display("EXTRA output row");
        end else begin
            if (out_row !== expv[r_seen] || out_row_idx !== (r_seen % N)) begin
                errors = errors + 1;
                if (errors < 6)
                    $display("MISMATCH row %0d (job %0d, row %0d): got %h want %h",
                             r_seen, r_seen / N, r_seen % N, out_row, expv[r_seen]);
            end
            if (dump_fd) $fwrite(dump_fd, "%h\n", out_row);
            r_seen = r_seen + 1;
            last_out = cyc;
        end
    end

    initial begin
        if (!$value$plusargs("PRE=%s", pre)) begin $display("need +PRE="); $finish; end
        if ($value$plusargs("DUMP=%s", dump_name)) dump_fd = $fopen(dump_name, "w");
        $readmemh({pre, "_meta.hex"}, meta);
        nb = meta[0]; nr = meta[1]; macs = meta[2];
        $readmemh({pre, "_stim.hex"}, stim, 0, nb - 1);
        $readmemh({pre, "_exp.hex"},  expv, 0, nr - 1);
        errors = 0; r_seen = 0;
        repeat (3) @(posedge clk); #1 rst = 0;
        @(posedge clk); #1;
        first_in = cyc;
        for (b = 0; b < nb; b = b + 1) begin
            {in_valid, in_bl, in_jl, in_fa, in_fb, a_col, b_row, a_sc, b_sc} = stim[b];
            @(posedge clk); #1;
        end
        in_valid = 0; in_bl = 0; in_jl = 0;
        repeat (4*N + 10) @(posedge clk);
        #1;
        if (r_seen != nr) begin
            errors = errors + 1;
            $display("MISSING rows: saw %0d expected %0d", r_seen, nr);
        end
        $display("%0s %0dx%0d %0s: %0d rows, %0d FP32 results checked, %0d errors",
                 VER, N, N, pre, r_seen, r_seen * N, errors);
        $display("%0s %0dx%0d %0s: %0d multiplies on %0d cells in %0d ticks",
                 VER, N, N, pre, macs, N*N, last_out - first_in + 1);
        if (dump_fd) $fclose(dump_fd);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
