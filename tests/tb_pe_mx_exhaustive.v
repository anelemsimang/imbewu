// tb_pe_mx_exhaustive.v - checks ONE multi-format cell on every possible input:
// 4 formats x 256 x 256 = 262,144 cases. Because the input space of a single
// multiply is small, testing all of it is a complete proof that the cell's
// decoding, multiplication and shifting are right (except the FP8 NaN codes,
// which are marked as skipped). Expected values: tools/gen_cell_exhaustive.py
// Plusarg: +EXP=<hex file>
`timescale 1ns/1ps
module tb_pe_mx_exhaustive;
    reg clk = 0, rst = 1;
    reg [7:0] a = 0, b = 0;
    reg [1:0] f = 0;
    reg v = 0, l = 0;
    wire [7:0] ao, bo; wire vo, lo; wire [1:0] fo;
    wire signed [47:0] res;
    pe_mx dut (.clk(clk), .rst(rst), .a_in(a), .b_in(b), .v_in(v), .l_in(l), .f_in(f),
               .a_out(ao), .b_out(bo), .v_out(vo), .l_out(lo), .f_out(fo), .res(res));
    always #5 clk = ~clk;

    reg [48:0] expv [0:262143];
    reg [1023:0] fname;
    integer n, errors = 0, skipped = 0, checked = 0;

    initial begin
        if (!$value$plusargs("EXP=%s", fname)) begin $display("need +EXP="); $finish; end
        $readmemh(fname, expv);
        repeat (2) @(posedge clk); #1 rst = 0;
        v = 1; l = 1;                          // every beat is a one-multiply job
        for (n = 0; n < 262144; n = n + 1) begin
            {f, a, b} = n[17:0];
            @(posedge clk); #1;                // res now holds 0 + product
            if (expv[n][48]) skipped = skipped + 1;
            else begin
                checked = checked + 1;
                if (res !== expv[n][47:0]) begin
                    errors = errors + 1;
                    if (errors < 6) $display("MISMATCH fmt %0d a %h b %h: got %0d", f, a, b, res);
                end
            end
        end
        $display("cell exhaustive: %0d cases checked, %0d skipped (FP8 NaN), %0d errors",
                 checked, skipped, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
