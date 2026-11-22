// systolic_mx.v - Streaming multi-format systolic engine (version 3, goal G1)
//
// Same factory-line design as systolic_stream.v (version 2), plus:
//  * Precision flexibility: each job chooses INT8, FP8 (E4M3) or FP4 (E2M1)
//    with in_fmt. The format travels with the data as a tag, so jobs of
//    different formats can follow each other with no gap.
//  * FP4 packs two numbers per 8-bit lane, so FP4 jobs do twice the work
//    per tick.
//  * OCP MX block scales: every row of A and every column of B carries one
//    shared 8-bit power-of-two scale (E8M0) per job. They are given on the
//    job's last beat and applied as an exponent on the way out.
//
// Output for element C[i][j]:  value = out_row[j] * 2^out_exp[j]   (exact)
//   out_row[j] : signed 48 bits,  bits [j*48 +: 48]
//   out_exp[j] : signed 10 bits,  bits [j*10 +: 10]
//                = a_scale[i] + b_scale[j] - 254 - 18
//
// Input per beat: a_col (column of A), b_row (row of B), one 8-bit lane per
// row/column. In FP4 mode each lane holds two consecutive K elements
// (low nibble first). On the last beat also give in_a_scale / in_b_scale
// (8 bits per row / column, E8M0: scale = 2^(x - 127)).
//
// Rule (as version 2): every job must have at least N beats.
module systolic_mx #(
    parameter N = 4
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 in_valid,
    input  wire                 in_last,
    input  wire [1:0]           in_fmt,
    input  wire [N*8-1:0]       a_col,
    input  wire [N*8-1:0]       b_row,
    input  wire [N*8-1:0]       in_a_scale,
    input  wire [N*8-1:0]       in_b_scale,
    output reg                  out_valid,
    output reg  [IW-1:0]        out_row_idx,
    output reg  [N*48-1:0]      out_row,
    output reg  [N*10-1:0]      out_exp
);
    localparam IW = $clog2(N) + 1;

    wire [7:0]  a_bus [0:N-1][0:N];
    wire        v_bus [0:N-1][0:N];
    wire        l_bus [0:N-1][0:N];
    wire [1:0]  f_bus [0:N-1][0:N];
    wire [7:0]  b_bus [0:N][0:N-1];
    wire [N*N*48-1:0] res_flat;

    wire beat_last = in_valid & in_last;

    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : skew
            if (i == 0) begin : direct
                assign a_bus[0][0] = a_col[7:0];
                assign v_bus[0][0] = in_valid;
                assign l_bus[0][0] = beat_last;
                assign f_bus[0][0] = in_fmt;
                assign b_bus[0][0] = b_row[7:0];
            end else begin : delayed
                reg [7:0] ad [0:i-1];
                reg [7:0] bd [0:i-1];
                reg       vd [0:i-1];
                reg       ld [0:i-1];
                reg [1:0] fd [0:i-1];
                integer m;
                always @(posedge clk) begin
                    ad[0] <= a_col[i*8 +: 8];
                    bd[0] <= b_row[i*8 +: 8];
                    fd[0] <= in_fmt;
                    vd[0] <= rst ? 1'b0 : in_valid;
                    ld[0] <= rst ? 1'b0 : beat_last;
                    for (m = 1; m < i; m = m + 1) begin
                        ad[m] <= ad[m-1];
                        bd[m] <= bd[m-1];
                        fd[m] <= fd[m-1];
                        vd[m] <= rst ? 1'b0 : vd[m-1];
                        ld[m] <= rst ? 1'b0 : ld[m-1];
                    end
                end
                assign a_bus[i][0] = ad[i-1];
                assign v_bus[i][0] = vd[i-1];
                assign l_bus[i][0] = ld[i-1];
                assign f_bus[i][0] = fd[i-1];
                assign b_bus[0][i] = bd[i-1];
            end
        end

        for (i = 0; i < N; i = i + 1) begin : row
            for (j = 0; j < N; j = j + 1) begin : col
                wire signed [47:0] res;
                pe_mx u_pe (
                    .clk  (clk),
                    .rst  (rst),
                    .a_in (a_bus[i][j]),
                    .b_in (b_bus[i][j]),
                    .v_in (v_bus[i][j]),
                    .l_in (l_bus[i][j]),
                    .f_in (f_bus[i][j]),
                    .a_out(a_bus[i][j+1]),
                    .b_out(b_bus[i+1][j]),
                    .v_out(v_bus[i][j+1]),
                    .l_out(l_bus[i][j+1]),
                    .f_out(f_bus[i][j+1]),
                    .res  (res)
                );
                assign res_flat[(i*N+j)*48 +: 48] = res;
            end
        end
    endgenerate

    // Block scales: at most two jobs are in flight between "last beat in" and
    // "last row out", so two slots are enough (job k uses slot k mod 2).
    reg [N*8-1:0] sa_slot [0:1];
    reg [N*8-1:0] sb_slot [0:1];
    reg           wr_slot, rd_slot, cur_slot;

    reg [N-1:0]  last_dly;
    reg [IW-1:0] rd_row;
    reg          draining;

    // Output exponent for every element of row r, from the slot's scales
    function [N*10-1:0] row_exp;
        input [N*8-1:0] sa;
        input [N*8-1:0] sb;
        input integer   r;
        integer c;
        begin
            for (c = 0; c < N; c = c + 1)
                row_exp[c*10 +: 10] = {2'b00, sa[r*8 +: 8]} + {2'b00, sb[c*8 +: 8]} - 10'd272;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            last_dly  <= {N{1'b0}};
            draining  <= 1'b0;
            rd_row    <= {IW{1'b0}};
            out_valid <= 1'b0;
            wr_slot   <= 1'b0;
            rd_slot   <= 1'b0;
            cur_slot  <= 1'b0;
        end else begin
            if (beat_last) begin
                sa_slot[wr_slot] <= in_a_scale;
                sb_slot[wr_slot] <= in_b_scale;
                wr_slot          <= ~wr_slot;
            end
            last_dly <= {last_dly[N-2:0], beat_last};
            if (last_dly[N-1]) begin
                out_row     <= res_flat[0 +: N*48];
                out_exp     <= row_exp(sa_slot[rd_slot], sb_slot[rd_slot], 0);
                out_row_idx <= {IW{1'b0}};
                out_valid   <= 1'b1;
                cur_slot    <= rd_slot;
                rd_slot     <= ~rd_slot;
                rd_row      <= 1;
                draining    <= (N > 1);
            end else if (draining) begin
                out_row     <= res_flat[rd_row*N*48 +: N*48];
                out_exp     <= row_exp(sa_slot[cur_slot], sb_slot[cur_slot], rd_row);
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
