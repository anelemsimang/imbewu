// tb_mx_mul_exhaustive.v - checks rtl/mx_mul.v on every possible input
// (2 halves x 16 format pairs x 256 x 256). Expected: tools/gen_mul_exhaustive.py
// Plusarg: +EXP=<hex file>
`timescale 1ns/1ps
module tb_mx_mul_exhaustive;
    reg  [1:0] fa, fb;
    reg  [7:0] a, b;
    reg        ph;
    wire signed [47:0] p;
    mx_mul dut (.fa(fa), .fb(fb), .a(a), .b(b), .ph(ph), .p(p));
    reg [48:0] expv [0:2097151];
    reg [1023:0] fname;
    integer n, errors = 0, skipped = 0, checked = 0;
    initial begin
        if (!$value$plusargs("EXP=%s", fname)) begin $display("need +EXP="); $finish; end
        $readmemh(fname, expv);
        for (n = 0; n < 2097152; n = n + 1) begin
            {ph, fa, fb, a, b} = n[20:0];
            #1;
            if (expv[n][48]) skipped = skipped + 1;
            else begin
                checked = checked + 1;
                if (p !== expv[n][47:0]) begin
                    errors = errors + 1;
                    if (errors < 6) $display("MISMATCH fa %0d fb %0d a %h b %h: got %0d", fa, fb, a, b, p);
                end
            end
        end
        $display("multiplier exhaustive: %0d cases checked, %0d skipped (FP8 NaN), %0d errors",
                 checked, skipped, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
