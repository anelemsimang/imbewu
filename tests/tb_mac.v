// tb_mac.v - 1,000 random tests of the MAC unit against a reference model
`timescale 1ns/1ps
module tb_mac;
    reg clk = 0, rst = 1, en = 0;
    reg  signed [7:0]  a, b;
    wire signed [31:0] acc;
    reg  signed [31:0] expected;
    integer i, errors = 0;

    mac dut (.clk(clk), .rst(rst), .en(en), .a(a), .b(b), .acc(acc));
    always #5 clk = ~clk;

    initial begin
        a = 0; b = 0; expected = 0;
        @(posedge clk); #1 rst = 0; en = 1;
        for (i = 0; i < 1000; i = i + 1) begin
            a = $random; b = $random;
            expected = expected + a * b;
            @(posedge clk); #1;
            if (acc !== expected) begin
                errors = errors + 1;
                $display("MISMATCH test %0d: got %0d expected %0d", i, acc, expected);
            end
        end
        $display("MAC: 1000 tests, %0d errors", errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
