// systolic_stream.v - Streaming NxN systolic matrix engine (version 2)
//
// Computes C = A x B, where A is N x K, B is K x N and C is N x N, for a
// continuous stream of jobs. K (the shared dimension) can differ per job and
// can be longer than N, so long matrix products need no extra hardware.
//
// Plain language: version 1 (systolic_array.v) took a whole job, filled the
// grid, emptied it, then took the next job, so cells sat idle about two-thirds
// of the time. Version 2 works like a factory line: the next job enters right
// behind the current one, and finished answers leave from the other side
// while new work is still flowing in.
//
// Input, one "beat" per clock tick while in_valid is high:
//   a_col  - one column of A  (element i at bits [i*8 +: 8])
//   b_row  - the matching row of B (element j at bits [j*8 +: 8])
//   in_last- high on the final beat of a job
// Output, one row of C per tick, for N ticks after each job:
//   out_valid, out_row_idx (which row), out_row (element j at [j*32 +: 32])
//
// Rule: every job must have at least N beats (K >= N). Gaps between beats
// (in_valid low) are allowed anywhere.
//
// Numbers: A and B are signed INT8, C is signed INT32.
module systolic_stream #(
    parameter N = 4
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 in_valid,
    input  wire                 in_last,
    input  wire [N*8-1:0]       a_col,
    input  wire [N*8-1:0]       b_row,
    output reg                  out_valid,
    output reg  [IW-1:0]        out_row_idx,
    output reg  [N*32-1:0]      out_row
);
    localparam IW = $clog2(N) + 1;          // bits needed for a row number

    // Wires between neighbouring cells
    wire signed [7:0] a_bus [0:N-1][0:N];   // into cell (row, col) from the left
    wire              v_bus [0:N-1][0:N];
    wire              l_bus [0:N-1][0:N];
    wire signed [7:0] b_bus [0:N][0:N-1];   // into cell (row, col) from above
    wire [N*N*32-1:0] res_flat;             // every cell's finished result

    wire beat_last = in_valid & in_last;

    genvar i, j;
    generate
        // Skew: row i of A (with its tags) is delayed i ticks, column j of B
        // is delayed j ticks, so matching pairs meet in the right cell.
        for (i = 0; i < N; i = i + 1) begin : skew
            if (i == 0) begin : direct
                assign a_bus[0][0] = a_col[7:0];
                assign v_bus[0][0] = in_valid;
                assign l_bus[0][0] = beat_last;
                assign b_bus[0][0] = b_row[7:0];
            end else begin : delayed
                reg [7:0] ad [0:i-1];
                reg [7:0] bd [0:i-1];
                reg       vd [0:i-1];
                reg       ld [0:i-1];
                integer m;
                always @(posedge clk) begin
                    ad[0] <= a_col[i*8 +: 8];
                    bd[0] <= b_row[i*8 +: 8];
                    vd[0] <= rst ? 1'b0 : in_valid;
                    ld[0] <= rst ? 1'b0 : beat_last;
                    for (m = 1; m < i; m = m + 1) begin
                        ad[m] <= ad[m-1];
                        bd[m] <= bd[m-1];
                        vd[m] <= rst ? 1'b0 : vd[m-1];
                        ld[m] <= rst ? 1'b0 : ld[m-1];
                    end
                end
                assign a_bus[i][0] = ad[i-1];
                assign v_bus[i][0] = vd[i-1];
                assign l_bus[i][0] = ld[i-1];
                assign b_bus[0][i] = bd[i-1];
            end
        end

        // The grid
        for (i = 0; i < N; i = i + 1) begin : row
            for (j = 0; j < N; j = j + 1) begin : col
                wire signed [31:0] res;
                pe_stream u_pe (
                    .clk  (clk),
                    .rst  (rst),
                    .a_in (a_bus[i][j]),
                    .b_in (b_bus[i][j]),
                    .v_in (v_bus[i][j]),
                    .l_in (l_bus[i][j]),
                    .a_out(a_bus[i][j+1]),
                    .b_out(b_bus[i+1][j]),
                    .v_out(v_bus[i][j+1]),
                    .l_out(l_bus[i][j+1]),
                    .res  (res)
                );
                assign res_flat[(i*N+j)*32 +: 32] = res;
            end
        end
    endgenerate

    // Read-out. Row i of a job is complete in every cell N+i ticks after the
    // job's last beat entered, and stays there until the next job's last beat
    // arrives (at least N ticks later). So we read row 0 at N ticks, row 1 at
    // N+1, and so on: one row per tick, never colliding with the next job.
    reg [N-1:0]  last_dly;                  // the "last" tag, delayed 1..N ticks
    reg [IW-1:0] rd_row;
    reg          draining;

    always @(posedge clk) begin
        if (rst) begin
            last_dly  <= {N{1'b0}};
            draining  <= 1'b0;
            rd_row    <= {IW{1'b0}};
            out_valid <= 1'b0;
        end else begin
            last_dly <= {last_dly[N-2:0], beat_last};
            if (last_dly[N-1]) begin
                out_row     <= res_flat[0 +: N*32];
                out_row_idx <= {IW{1'b0}};
                out_valid   <= 1'b1;
                rd_row      <= 1;
                draining    <= (N > 1);
            end else if (draining) begin
                out_row     <= res_flat[rd_row*N*32 +: N*32];
                out_row_idx <= rd_row;
                out_valid   <= 1'b1;
                rd_row      <= rd_row + 1'b1;
                draining    <= (rd_row != N-1);
            end else begin
                out_valid   <= 1'b0;
            end
        end
    end
endmodule
