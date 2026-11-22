// tb_fp32_add.v - checks rtl/fp32_add_fx.v against tools/fp32_ref.py
// (exact-fraction reference). Plusargs: +PRE=<prefix> +COUNT=<n>
`timescale 1ns/1ps
module tb_fp32_add;
    reg  [31:0]        acc;
    reg  signed [47:0] x;
    reg  signed [10:0] e;
    wire [31:0]        sum;
    fp32_add_fx dut (.acc(acc), .x(x), .e(e), .sum(sum));

    reg [91:0] stim [0:999999];
    reg [31:0] expv [0:999999];
    reg [1023:0] pre;
    integer n, count, errors = 0;
    initial begin
        if (!$value$plusargs("PRE=%s", pre) || !$value$plusargs("COUNT=%d", count)) begin
            $display("need +PRE= +COUNT="); $finish;
        end
        $readmemh({pre, "_stim.hex"}, stim, 0, count - 1);
        $readmemh({pre, "_exp.hex"},  expv, 0, count - 1);
        for (n = 0; n < count; n = n + 1) begin
            {acc, x} = stim[n][91:12];
            e = stim[n][10:0];
            #1;
            if (sum !== expv[n]) begin
                errors = errors + 1;
                if (errors < 8)
                    $display("MISMATCH acc %h x %0d e %0d: got %h want %h", acc, x, e, sum, expv[n]);
            end
        end
        $display("fp32 adder: %0d cases, %0d errors", count, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
