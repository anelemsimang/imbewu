// tb_mx_quant.v - rtl/mx_quant.v against the compiler's rounding
// (tools/gen_mx_quant_vectors.py). -DLANES=4; plusargs +PRE= +BLOCKS= +GAPS=1
`timescale 1ns/1ps
`ifndef LANES
`define LANES 4
`endif
module tb_mx_quant;
    localparam N = `LANES, WPB = 32 / N;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg  [1:0]     fmt = 0;
    reg            in_valid = 0;
    reg  [N*32-1:0] in_data = 0;
    wire           out_valid, out_last;
    wire [N*8-1:0] out_codes;
    wire [7:0]     out_scale;
    mx_quant #(.N(N)) dut (.clk(clk), .rst(rst), .fmt(fmt), .in_valid(in_valid), .in_data(in_data),
        .out_valid(out_valid), .out_codes(out_codes), .out_last(out_last), .out_scale(out_scale));

    reg [N*32-1:0] din  [0:65535];
    reg [1:0]      dfmt [0:8191];
    reg [263:0]    dexp [0:8191];
    reg [1023:0]   pre;
    integer nblk, gaps = 0, b, w, ob = 0, ow = 0, errors = 0, shown = 0;
    reg [255:0] got;

    // check the output stream
    always @(posedge clk) if (out_valid) begin
        got[ow * N * 8 +: N * 8] = out_codes;
        if (ow == WPB - 1) begin
            if (!out_last) begin errors = errors + 1; $display("block %0d: last word not marked", ob); end
            if (got !== dexp[ob][263:8] || out_scale !== dexp[ob][7:0]) begin
                errors = errors + 1;
                if (shown < 5) begin
                    shown = shown + 1;
                    $display("block %0d (format %0d): got %h scale %h, expected %h scale %h",
                             ob, dfmt[ob], got, out_scale, dexp[ob][263:8], dexp[ob][7:0]);
                end
            end
            ob = ob + 1; ow = 0;
        end else begin
            if (out_last) begin errors = errors + 1; $display("block %0d: early last", ob); end
            ow = ow + 1;
        end
    end

    initial begin
        if (!$value$plusargs("PRE=%s", pre)) begin $display("need +PRE="); $finish; end
        if (!$value$plusargs("BLOCKS=%d", nblk)) nblk = 100;
        if (!$value$plusargs("GAPS=%d", gaps)) gaps = 0;
        $readmemh({pre, "_in.hex"}, din, 0, nblk * WPB - 1);
        $readmemh({pre, "_fmt.hex"}, dfmt, 0, nblk - 1);
        $readmemh({pre, "_exp.hex"}, dexp, 0, nblk - 1);
        repeat (3) @(posedge clk); #1 rst = 0;
        for (b = 0; b < nblk; b = b + 1)
            for (w = 0; w < WPB; w = w + 1) begin
                while (gaps && ($urandom % 3) == 0) begin in_valid = 0; @(posedge clk); #1; end
                in_valid = 1; in_data = din[b * WPB + w]; fmt = dfmt[b];
                @(posedge clk); #1;
            end
        in_valid = 0;
        repeat (WPB + 5) @(posedge clk);
        $display("MX_QUANT %0d lanes: %0d blocks checked of %0d, %0d errors%s",
                 N, ob, nblk, errors, gaps ? " (random gaps)" : "");
        if (errors == 0 && ob == nblk) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
