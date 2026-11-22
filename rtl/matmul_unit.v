// matmul_unit.v - tiling controller + version 5 engine: one big matrix multiply
//
// Plain language: the engine (systolic_v5.v) computes one N x N piece of an
// answer at a time. This unit computes a whole C = A x B of any size that is
// a multiple of N, by splitting C into N x N tiles and feeding the engine one
// job per tile, back to back with no gaps, then writing the answers to memory.
//
// Memories are outside this unit (on a real chip: SRAM blocks), one read per
// tick each, with the answer one tick later. Data is laid out by the
// compiler so that each read gives the engine a full set of lanes:
//   A memory, word = N lanes of 8 bits:  addr = mt*BEATS + beat
//       lane i = element (row mt*N+i, beat) of A    (two FP4 numbers if both FP4)
//   B memory, word = N lanes:            addr = nt*BEATS + beat
//       lane j = element (beat, column nt*N+j) of B
//   A scales, word = N lanes:            addr = mt*NB + block   (row scales)
//   B scales, word = N lanes:            addr = nt*NB + block   (column scales)
//   C memory, word = N x FP32:           addr = (mt*N + i)*NT + nt  (row mt*N+i, tile nt)
//
// Configuration (held while busy): cfg_mt, cfg_nt = tiles down / across;
// cfg_beats = beats per job (whole K); cfg_bb = beats per MX block;
// cfg_nb = blocks per job; cfg_fa, cfg_fb = formats.
// Rules: cfg_beats >= N; cfg_bb >= min(16, N); cfg_beats = cfg_nb * cfg_bb.
module matmul_unit #(
    parameter N  = 4,
    parameter G  = 16,
    parameter AW = 16
) (
    input  wire            clk,
    input  wire            rst,
    input  wire            start,
    input  wire [7:0]      cfg_mt,
    input  wire [7:0]      cfg_nt,
    input  wire [AW-1:0]   cfg_beats,
    input  wire [AW-1:0]   cfg_bb,
    input  wire [AW-1:0]   cfg_nb,
    input  wire [1:0]      cfg_fa,
    input  wire [1:0]      cfg_fb,
    output reg             busy,
    output reg             done,          // one-tick pulse when C is complete
    output wire            feed,          // high on every tick the engine is fed a beat
    // memory read ports (data returns one tick after the address)
    output wire [AW-1:0]   a_addr,
    input  wire [N*8-1:0]  a_data,
    output wire [AW-1:0]   b_addr,
    input  wire [N*8-1:0]  b_data,
    output wire [AW-1:0]   sa_addr,
    input  wire [N*8-1:0]  sa_data,
    output wire [AW-1:0]   sb_addr,
    input  wire [N*8-1:0]  sb_data,
    // C memory write port
    output reg             c_we,
    output reg  [AW-1:0]   c_addr,
    output reg  [N*32-1:0] c_data
`ifdef FORMAL
    , output wire          f_v, f_bl, f_jl, f_run,
    output wire [AW-1:0]   f_beat, f_bib, f_blk,
    output wire [7:0]      f_mt, f_nt
`endif
);
    localparam IW = $clog2(N) + 1;

    // ---- issue side: walk tiles (mt, nt), beats and blocks -----------------
    reg            run;
    reg [7:0]      mt, nt;
    reg [AW-1:0]   beat, bib, blk;          // beat in job, beat in block, block in job
    wire last_beat  = (beat == cfg_beats - 1);
    wire last_inblk = (bib == cfg_bb - 1);
    wire last_tile  = (mt == cfg_mt - 1) && (nt == cfg_nt - 1);

    assign a_addr  = mt * cfg_beats + beat;
    assign b_addr  = nt * cfg_beats + beat;
    assign sa_addr = mt * cfg_nb + blk;
    assign sb_addr = nt * cfg_nb + blk;

    // tags that go with this tick's reads; they meet the data one tick later
    reg t_v, t_bl, t_jl;
    always @(posedge clk) begin
        if (rst) begin
            run <= 1'b0; mt <= 0; nt <= 0; beat <= 0; bib <= 0; blk <= 0;
            t_v <= 1'b0; t_bl <= 1'b0; t_jl <= 1'b0;
        end else begin
            t_v  <= run;
            t_bl <= run & last_inblk;
            t_jl <= run & last_beat;
            if (start && !busy && !run) begin   // never restart mid-run
                run <= 1'b1; mt <= 0; nt <= 0; beat <= 0; bib <= 0; blk <= 0;
            end else if (run) begin
                if (last_beat) begin
                    beat <= 0; bib <= 0; blk <= 0;
                    if (last_tile) run <= 1'b0;
                    else if (nt == cfg_nt - 1) begin nt <= 0; mt <= mt + 1'b1; end
                    else nt <= nt + 1'b1;
                end else begin
                    beat <= beat + 1'b1;
                    if (last_inblk) begin bib <= 0; blk <= blk + 1'b1; end
                    else bib <= bib + 1'b1;
                end
            end
        end
    end

`ifdef FORMAL
    assign f_v = t_v; assign f_bl = t_bl; assign f_jl = t_jl; assign f_run = run;
    assign f_beat = beat; assign f_bib = bib; assign f_blk = blk; assign f_mt = mt; assign f_nt = nt;
`endif

    assign feed = t_v;

    // ---- the engine --------------------------------------------------------
    wire            o_valid;
    wire [IW-1:0]   o_idx;
    wire [N*32-1:0] o_row;
    systolic_v5 #(.N(N), .G(G)) u_eng (
        .clk(clk), .rst(rst), .in_valid(t_v), .in_blk_last(t_bl), .in_job_last(t_jl),
        .in_fa(cfg_fa), .in_fb(cfg_fb), .a_col(a_data), .b_row(b_data),
        .in_a_scale(sa_data), .in_b_scale(sb_data),
        .out_valid(o_valid), .out_row_idx(o_idx), .out_row(o_row));

    // ---- collect side: answers come out in job order -----------------------
    reg [7:0] omt, ont;
    always @(posedge clk) begin
        c_we <= 1'b0;
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0; omt <= 0; ont <= 0;
        end else begin
            if (start && !busy) begin busy <= 1'b1; omt <= 0; ont <= 0; end
            if (o_valid) begin
                c_we   <= 1'b1;
                c_addr <= (omt * N + o_idx) * cfg_nt + ont;
                c_data <= o_row;
                if (o_idx == N - 1) begin
                    if (omt == cfg_mt - 1 && ont == cfg_nt - 1) begin
                        busy <= 1'b0; done <= 1'b1;
                    end else if (ont == cfg_nt - 1) begin ont <= 0; omt <= omt + 1'b1; end
                    else ont <= ont + 1'b1;
                end
            end
        end
    end
endmodule
