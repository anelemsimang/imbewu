// systolic_v4.v - Streaming multi-format engine, version 4 (goals G1, G5)
//
// Same factory-line design as versions 2 and 3, with the version 4 cell
// (pe_v4.v): mixed formats, and many MX blocks summed inside each cell into
// an FP32 total. One job computes an N x N block of C = A x B for any K.
//
// Input per beat (one column of A and one row of B):
//   in_valid      this beat carries data
//   in_blk_last   last beat of an MX block
//   in_job_last   last beat of the job (also ends the block)
//   in_fa, in_fb  formats of the A side and B side (0 INT8, 1 FP8 E4M3,
//                 2 FP4 E2M1). If both are FP4, each lane holds two numbers.
//   a_col, b_row  one 8-bit lane per row of A / column of B
//   in_a_scale, in_b_scale  E8M0 block scales, one per row / column,
//                 read on block-last beats
// Output: N rows per job, row i on out_row (N x FP32, element j at
//   bits [j*32 +: 32]) with out_row_idx = i.
//
// Rule (as before): every job must have at least N beats.
module systolic_v4 #(
    parameter N = 4
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              in_valid,
    input  wire              in_blk_last,
    input  wire              in_job_last,
    input  wire [1:0]        in_fa,
    input  wire [1:0]        in_fb,
    input  wire [N*8-1:0]    a_col,
    input  wire [N*8-1:0]    b_row,
    input  wire [N*8-1:0]    in_a_scale,
    input  wire [N*8-1:0]    in_b_scale,
    output reg               out_valid,
    output reg  [IW-1:0]     out_row_idx,
    output reg  [N*32-1:0]   out_row
`ifdef FORMAL
    , output wire [N-1:0]    f_last_dly,
    output wire              f_draining,
    output wire [IW-1:0]     f_rd_row
`endif
);
    localparam IW = $clog2(N) + 1;
    localparam AW = 8 + 2 + 8 + 3;      // a-side bundle: a, fa, sa, {v, bl, jl}
    localparam BW = 8 + 2 + 8;          // b-side bundle: b, fb, sb

    wire job_last = in_valid & in_job_last;

    // Bundles entering each row (a side) and column (b side)
    wire [AW-1:0] a_bus [0:N-1][0:N];
    wire [BW-1:0] b_bus [0:N][0:N-1];
    wire [N*N*32-1:0] res_flat;

    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : skew
            wire [AW-1:0] a_new = {a_col[i*8 +: 8], in_fa, in_a_scale[i*8 +: 8],
                                   in_valid, in_valid & in_blk_last, job_last};
            wire [BW-1:0] b_new = {b_row[i*8 +: 8], in_fb, in_b_scale[i*8 +: 8]};
            if (i == 0) begin : direct
                assign a_bus[0][0] = a_new;
                assign b_bus[0][0] = b_new;
            end else begin : delayed
                reg [AW-1:0] ad [0:i-1];
                reg [BW-1:0] bd [0:i-1];
                integer m;
                always @(posedge clk) begin
                    ad[0] <= rst ? {AW{1'b0}} : a_new;
                    bd[0] <= b_new;
                    for (m = 1; m < i; m = m + 1) begin
                        ad[m] <= rst ? {AW{1'b0}} : ad[m-1];
                        bd[m] <= bd[m-1];
                    end
                end
                assign a_bus[i][0] = ad[i-1];
                assign b_bus[0][i] = bd[i-1];
            end
        end

        for (i = 0; i < N; i = i + 1) begin : row
            for (j = 0; j < N; j = j + 1) begin : col
                wire [AW-1:0] ai = a_bus[i][j];
                wire [BW-1:0] bi = b_bus[i][j];
                wire [31:0] res;
                wire [7:0] ao, bo, sao, sbo;
                wire [1:0] fao, fbo;
                wire vo, blo, jlo;
                pe_v4 u_pe (
                    .clk(clk), .rst(rst),
                    .a_in(ai[20:13]), .fa_in(ai[12:11]), .sa_in(ai[10:3]),
                    .v_in(ai[2]), .bl_in(ai[1]), .jl_in(ai[0]),
                    .b_in(bi[17:10]), .fb_in(bi[9:8]), .sb_in(bi[7:0]),
                    .a_out(ao), .fa_out(fao), .sa_out(sao), .v_out(vo), .bl_out(blo), .jl_out(jlo),
                    .b_out(bo), .fb_out(fbo), .sb_out(sbo),
                    .res(res));
                assign a_bus[i][j+1] = {ao, fao, sao, vo, blo, jlo};
                assign b_bus[i+1][j] = {bo, fbo, sbo};
                assign res_flat[(i*N+j)*32 +: 32] = res;
            end
        end
    endgenerate

    // Read-out, as in version 2: row 0 leaves N+1 ticks after the job's last
    // beat, then one row per tick.
    reg [N-1:0]  last_dly;
    reg [IW-1:0] rd_row;
    reg          draining;
`ifdef FORMAL
    assign f_last_dly = last_dly;
    assign f_draining = draining;
    assign f_rd_row   = rd_row;
`endif

    always @(posedge clk) begin
        if (rst) begin
            last_dly  <= {N{1'b0}};
            draining  <= 1'b0;
            rd_row    <= {IW{1'b0}};
            out_valid <= 1'b0;
        end else begin
            last_dly <= {last_dly[N-2:0], job_last};
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
