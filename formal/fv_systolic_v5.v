// fv_systolic_v5.v - formal checks of the version 5 engine.
//
//   R1  Every job produces exactly N output rows, rows 0..N-1 in order, row r
//       appearing exactly N+3+r ticks after the job's last input beat.
//   R2  No output row ever appears that does not belong to a job.
//   R4  Shared adders are never double-booked: in each group of cells that
//       shares an FP32 adder, at most one cell asks for it in any tick, and
//       no cell asks twice in a row (its previous answer is still on the way).
//
// Assumptions (the documented rules): every job has at least N beats and
// every MX block has at least min(G, N) beats.
module fv_systolic_v5 #(parameter N = 4, parameter G = 2) (
    input wire           clk,
    input wire           in_valid,
    input wire           in_blk_last,
    input wire           in_job_last,
    input wire [1:0]     in_fa,
    input wire [1:0]     in_fb,
    input wire [N*8-1:0] a_col,
    input wire [N*8-1:0] b_row,
    input wire [N*8-1:0] in_a_scale,
    input wire [N*8-1:0] in_b_scale
);
    localparam IW  = $clog2(N) + 1;
    localparam LAT = 2;
    localparam D   = 2 * N + LAT + 1;
    localparam GE  = (N < G) ? N : G;

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst = init;

    wire            out_valid;
    wire [IW-1:0]   out_row_idx;
    wire [N*32-1:0] out_row;
    wire [N+1:0]    f_last_dly;
    wire            f_draining;
    wire [IW-1:0]   f_rd_row;
    wire [N*N-1:0]  f_req;

    systolic_v5 #(.N(N), .G(G)) dut (.clk(clk), .rst(rst), .in_valid(in_valid),
        .in_blk_last(in_blk_last), .in_job_last(in_job_last), .in_fa(in_fa), .in_fb(in_fb),
        .a_col(a_col), .b_row(b_row), .in_a_scale(in_a_scale), .in_b_scale(in_b_scale),
        .out_valid(out_valid), .out_row_idx(out_row_idx), .out_row(out_row),
        .f_last_dly(f_last_dly), .f_draining(f_draining), .f_rd_row(f_rd_row), .f_req(f_req));

    // ---- assumptions ------------------------------------------------------
    reg [IW:0] beats = 0;               // beats in the current job, capped at N
    reg [IW:0] bbeats = 0;              // beats in the current block, capped at GE
    wire blk_end = in_valid && (in_blk_last || in_job_last);
    always @(posedge clk) begin
        if (rst) begin beats <= 0; bbeats <= 0; end
        else if (in_valid) begin
            beats  <= in_job_last ? 0 : (beats < N ? beats + 1 : beats);
            bbeats <= blk_end ? 0 : (bbeats < GE ? bbeats + 1 : bbeats);
        end
    end
    always @(*) if (!rst && in_valid && in_job_last) assume(beats >= N - 1);
    always @(*) if (!rst && blk_end) assume(bbeats >= GE - 1);

    // ---- checker's record of job ends -----------------------------------
    wire job_end = !rst && in_valid && in_job_last;
    reg [D-1:0] ended = 0;
    always @(posedge clk) ended <= {ended[D-2:0], job_end};

    reg          due;
    reg [IW-1:0] due_row;
    reg [IW:0]   n_due, win, nreq;
    reg [N*N-1:0] req_prev = 0;
    always @(posedge clk) req_prev <= f_req;
    integer r, p, q, i, j0, j;
    always @(*) begin
        due = 1'b0; due_row = 0; n_due = 0;
        for (r = 0; r < N; r = r + 1) begin
            n_due = n_due + ended[N + LAT + r];
            if (ended[N + LAT + r]) begin due = 1'b1; due_row = r; end
        end
    end

    always @(*) if (!init) begin
        // R1, R2
        assert(n_due <= 1);
        assert(out_valid == due);
        if (due) assert(out_row_idx == due_row);
        // R4
        for (i = 0; i < N; i = i + 1)
            for (j0 = 0; j0 < N; j0 = j0 + GE) begin
                nreq = 0;
                for (j = j0; j < j0 + GE && j < N; j = j + 1) nreq = nreq + f_req[i*N + j];
                assert(nreq <= 1);
            end
        assert((f_req & req_prev) == 0);
        // helper rules (invariants) for the induction proof
        assert(f_last_dly == ended[N+LAT-1:0]);
        assert(f_draining == (|ended[2*N+LAT-2:N+LAT]));
        for (p = N + LAT; p < 2*N + LAT - 1; p = p + 1)
            if (ended[p]) assert(f_rd_row == p - N - LAT + 1);
        for (p = 0; p < N; p = p + 1)
            if (ended[p]) assert(beats <= p);
        for (p = 0; p + N <= D; p = p + 1) begin
            win = 0;
            for (q = p; q < p + N; q = q + 1) win = win + ended[q];
            assert(win <= 1);
        end
        assert(beats <= N);
        assert(bbeats <= GE);
    end

    reg [7:0] rows_done = 0;
    always @(posedge clk) if (out_valid && out_row_idx == N - 1) rows_done <= rows_done + 1;
    always @(*) cover(rows_done == 2);
endmodule
