// tb_fp32_ops.v - checks FP32 add and multiply (rtl/fp32_ops.v) against
// NumPy float32 (tools/gen_fp32_ops_vectors.py). Plusargs: +PRE= +COUNT=
`timescale 1ns/1ps
module tb_fp32_ops;
    reg  [31:0] a, b;
    wire [31:0] s, p;
    fp32_add uadd (.a(a), .b(b), .y(s));
    fp32_mul umul (.a(a), .b(b), .y(p));
    reg [63:0] stim [0:999999], expv [0:999999];
    reg [1023:0] pre;
    integer n, count, ea = 0, em = 0;
    initial begin
        if (!$value$plusargs("PRE=%s", pre) || !$value$plusargs("COUNT=%d", count)) begin
            $display("need +PRE= +COUNT="); $finish;
        end
        $readmemh({pre, "_stim.hex"}, stim, 0, count - 1);
        $readmemh({pre, "_exp.hex"}, expv, 0, count - 1);
        for (n = 0; n < count; n = n + 1) begin
            {a, b} = stim[n]; #1;
            if (s !== expv[n][63:32]) begin
                ea = ea + 1;
                if (ea < 5) $display("ADD MISMATCH %h + %h: got %h want %h", a, b, s, expv[n][63:32]);
            end
            if (p !== expv[n][31:0]) begin
                em = em + 1;
                if (em < 5) $display("MUL MISMATCH %h * %h: got %h want %h", a, b, p, expv[n][31:0]);
            end
        end
        $display("fp32 ops: %0d cases, add errors %0d, multiply errors %0d", count, ea, em);
        if (ea == 0 && em == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
