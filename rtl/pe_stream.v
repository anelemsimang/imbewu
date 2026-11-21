// pe_stream.v - Processing element for the streaming systolic engine
//
// Plain language: like pe.v, but it never has to stop. Each number from the
// left arrives with two small tags:
//   v ("valid")  - this is real data, multiply it
//   l ("last")   - this is the final pair for the current job
// When the "last" pair arrives, the cell parks its finished total in a result
// register and starts the next job's total from zero on the very next tick.
// So a new job can follow the old one with no gap.
module pe_stream (
    input  wire               clk,
    input  wire               rst,
    input  wire signed [7:0]  a_in,    // from the left neighbour
    input  wire signed [7:0]  b_in,    // from the neighbour above
    input  wire               v_in,    // valid tag (travels with a)
    input  wire               l_in,    // last tag  (travels with a)
    output reg  signed [7:0]  a_out,   // to the right neighbour
    output reg  signed [7:0]  b_out,   // to the neighbour below
    output reg                v_out,
    output reg                l_out,
    output reg  signed [31:0] res      // finished result of the latest job
);
    reg  signed [31:0] acc;            // running total of the current job
    wire signed [15:0] prod = a_in * b_in;

    always @(posedge clk) begin
        a_out <= a_in;
        b_out <= b_in;
        if (rst) begin
            acc   <= 32'sd0;
            res   <= 32'sd0;
            v_out <= 1'b0;
            l_out <= 1'b0;
        end else begin
            v_out <= v_in;
            l_out <= l_in;
            if (v_in) begin
                if (l_in) begin
                    res <= acc + prod;     // job finished: park the answer
                    acc <= 32'sd0;         // and start the next job fresh
                end else begin
                    acc <= acc + prod;
                end
            end
        end
    end
endmodule
