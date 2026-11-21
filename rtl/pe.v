// pe.v - Processing Element: one cell of the systolic array
//
// Plain language: a MAC unit that also passes its inputs along. Numbers from
// the left (a) move one step right each tick; numbers from above (b) move one
// step down. Each cell keeps its own running total, which ends up being one
// entry of the result matrix.
module pe (
    input  wire               clk,
    input  wire               clear,   // start a new calculation
    input  wire signed [7:0]  a_in,    // from the left neighbour
    input  wire signed [7:0]  b_in,    // from the neighbour above
    output reg  signed [7:0]  a_out,   // to the right neighbour
    output reg  signed [7:0]  b_out,   // to the neighbour below
    output reg  signed [31:0] acc      // this cell's result
);
    always @(posedge clk) begin
        if (clear) begin
            acc   <= 32'sd0;
            a_out <= 8'sd0;
            b_out <= 8'sd0;
        end else begin
            acc   <= acc + a_in * b_in;
            a_out <= a_in;
            b_out <= b_in;
        end
    end
endmodule
