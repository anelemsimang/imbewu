// mac.v - Multiply-Accumulate unit (the basic building block of every AI chip)
//
// Plain language: every clock tick, multiply two numbers and add the result
// to a running total. Matrix multiplication - the core of AI - is millions of
// these operations.
//
// a, b : signed 8-bit inputs (INT8, the common number format for AI inference)
// acc  : signed 32-bit running total (wide enough not to overflow)
module mac (
    input  wire               clk,
    input  wire               rst,     // reset: set total to zero
    input  wire               en,      // enable: only accumulate when high
    input  wire signed [7:0]  a,
    input  wire signed [7:0]  b,
    output reg  signed [31:0] acc
);
    always @(posedge clk) begin
        if (rst)
            acc <= 32'sd0;
        else if (en)
            acc <= acc + a * b;
    end
endmodule
