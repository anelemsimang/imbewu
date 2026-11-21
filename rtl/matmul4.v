// matmul4.v - 4x4 systolic matrix-multiply engine: C = A x B
//
// Plain language: a 4x4 grid of processing elements (PEs). Rows of A flow in
// from the left, columns of B flow in from the top, staggered in time so the
// right numbers meet in the right cell. This is the same idea Google uses in
// its TPU chips, shrunk to 16 cells. Imbewu's compute tile will be a much
// larger version of this grid.
//
// Numbers: A and B are signed INT8, C is signed INT32.
// Packing: element [r][c] of A or B lives at bits [(r*4+c)*8 +: 8];
//          element [r][c] of C lives at bits [(r*4+c)*32 +: 32].
// Usage:   load a_flat/b_flat, pulse start for one cycle, wait for done.
//          Latency: 1 clear cycle + 3N-2 = 11 compute cycles.
module matmul4 #(
    parameter N = 4
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 start,
    input  wire [N*N*8-1:0]     a_flat,
    input  wire [N*N*8-1:0]     b_flat,
    output wire [N*N*32-1:0]    c_flat,
    output reg                  busy,
    output reg                  done
);
    localparam STEPS = 3*N - 2;          // cycles for data to cross the grid

    reg  [7:0] t;                        // time step while busy
    reg        clear;

    // Wires between neighbouring PEs
    wire signed [7:0] a_bus [0:N-1][0:N];   // a_bus[row][col]: into PE(row,col)
    wire signed [7:0] b_bus [0:N][0:N-1];   // b_bus[row][col]: into PE(row,col)

    // Control: start -> one clear cycle -> STEPS compute cycles -> done
    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; done <= 1'b0; clear <= 1'b0; t <= 8'd0;
        end else if (start && !busy) begin
            busy <= 1'b1; done <= 1'b0; clear <= 1'b1; t <= 8'd0;
        end else if (busy) begin
            if (clear)
                clear <= 1'b0;
            else if (t == STEPS-1) begin
                busy <= 1'b0; done <= 1'b1;
            end else
                t <= t + 8'd1;
        end
    end

    wire feeding = busy && !clear;

    genvar i, j;
    generate
        // Edge feeders: row i of A is delayed by i steps, column j of B by j
        // steps (the "skew" that makes the right pairs meet).
        for (i = 0; i < N; i = i + 1) begin : feed
            wire [7:0] ka = t - i;                       // which A column for row i
            wire [7:0] kb = t - i;                       // which B row for column i
            assign a_bus[i][0] = (feeding && t >= i && ka < N) ? a_flat[(i*N+ka)*8 +: 8] : 8'sd0;
            assign b_bus[0][i] = (feeding && t >= i && kb < N) ? b_flat[(kb*N+i)*8 +: 8] : 8'sd0;
        end

        // The grid
        for (i = 0; i < N; i = i + 1) begin : row
            for (j = 0; j < N; j = j + 1) begin : col
                wire signed [31:0] acc;
                pe u_pe (
                    .clk  (clk),
                    .clear(clear || rst),
                    .a_in (a_bus[i][j]),
                    .b_in (b_bus[i][j]),
                    .a_out(a_bus[i][j+1]),
                    .b_out(b_bus[i+1][j]),
                    .acc  (acc)
                );
                assign c_flat[(i*N+j)*32 +: 32] = acc;
            end
        end
    endgenerate
endmodule
