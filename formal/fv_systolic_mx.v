// fv_systolic_mx.v - formal (mathematical) checks of the multi-format engine's
// control logic, using Yosys + yosys-smtbmc with the Boolector solver.
//
// Plain language: a simulation test tries chosen inputs. A formal check lets a
// solver try EVERY possible input sequence (any data, any format, any gaps,
// any scales, jobs back to back) and either proves a rule always holds or
// shows a counter-example. Here we prove the rules of the engine's output:
//
//   R1  Every job produces exactly N output rows, rows 0..N-1 in order, row r
//       appearing exactly N+1+r ticks after the job's last input beat.
//   R2  No output row ever appears that does not belong to a job.
//   R3  Each row carries the scales (exponents) of ITS job, never the
//       neighbouring job's, even when jobs follow each other with no gap.
//
// The checker keeps its own record (a plain delay line) of when each job
// ended and which scales it had; that record is independent of the design's
// two-slot scale store.
//
// Assumption (the documented rule): every job has at least N beats.
module fv_systolic_mx #(parameter N = 2) (
    input wire           clk,
    input wire           in_valid,
    input wire           in_last,
    input wire [1:0]     in_fmt,
    input wire [N*8-1:0] a_col,
    input wire [N*8-1:0] b_row,
    input wire [N*8-1:0] in_a_scale,
    input wire [N*8-1:0] in_b_scale
);
    localparam IW = $clog2(N) + 1;
    localparam D  = 2 * N + 1;          // checker delay-line length

    // Reset is high in the first tick only
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst = init;

    wire           out_valid;
    wire [IW-1:0]  out_row_idx;
    wire [N*48-1:0] out_row;
    wire [N*10-1:0] out_exp;

    systolic_mx #(.N(N)) dut (.clk(clk), .rst(rst), .in_valid(in_valid),
        .in_last(in_last), .in_fmt(in_fmt), .a_col(a_col), .b_row(b_row),
        .in_a_scale(in_a_scale), .in_b_scale(in_b_scale), .out_valid(out_valid),
        .out_row_idx(out_row_idx), .out_row(out_row), .out_exp(out_exp),
        .f_last_dly(f_last_dly), .f_wr_slot(f_wr_slot), .f_rd_slot(f_rd_slot),
        .f_cur_slot(f_cur_slot), .f_draining(f_draining), .f_rd_row(f_rd_row),
        .f_sa0(f_sa0), .f_sa1(f_sa1), .f_sb0(f_sb0), .f_sb1(f_sb1));
    wire [N-1:0]   f_last_dly;
    wire           f_wr_slot, f_rd_slot, f_cur_slot, f_draining;
    wire [IW-1:0]  f_rd_row;
    wire [N*8-1:0] f_sa0, f_sa1, f_sb0, f_sb1;

    // ---- assumption: jobs have at least N beats --------------------------
    reg [IW:0] beats = 0;               // beats so far in the current job, capped at N
    always @(posedge clk) begin
        if (rst) beats <= 0;
        else if (in_valid) beats <= in_last ? 0 : (beats < N ? beats + 1 : beats);
    end
    always @(*) if (!rst && in_valid && in_last) assume(beats >= N - 1);

    // ---- checker's own record of jobs ------------------------------------
    wire job_end = !rst && in_valid && in_last;
    reg [D-1:0]   ended = 0;            // ended[k]: a job ended k+1 ticks ago
    reg [N*8-1:0] sa_d [0:D-1];
    reg [N*8-1:0] sb_d [0:D-1];
    integer k;
    always @(posedge clk) begin
        ended   <= {ended[D-2:0], job_end};
        sa_d[0] <= in_a_scale;
        sb_d[0] <= in_b_scale;
        for (k = 1; k < D; k = k + 1) begin
            sa_d[k] <= sa_d[k-1];
            sb_d[k] <= sb_d[k-1];
        end
    end

    // Which row (if any) the checker expects now: row r is due when the job
    // ended N+1+r ticks ago, i.e. ended[N+r].
    reg        due;
    reg [IW-1:0] due_row;
    reg [N*8-1:0] due_sa, due_sb;
    integer r, c;
    always @(*) begin
        due = 1'b0; due_row = 0; due_sa = 0; due_sb = 0;
        for (r = 0; r < N; r = r + 1)
            if (ended[N + r]) begin
                due = 1'b1; due_row = r; due_sa = sa_d[N + r]; due_sb = sb_d[N + r];
            end
    end

    // At most one row can be due at a time (follows from the N-beat rule)
    reg [IW:0] n_due;
    always @(*) begin
        n_due = 0;
        for (r = 0; r < N; r = r + 1) n_due = n_due + ended[N + r];
    end

    reg [N*10-1:0] want_exp;
    always @(*)
        for (c = 0; c < N; c = c + 1)
            want_exp[c*10 +: 10] = {2'b00, due_sa[due_row*8 +: 8]} +
                                   {2'b00, due_sb[c*8 +: 8]} - 10'd272;

    // ---- the rules -------------------------------------------------------
    always @(*) if (!init) begin
        assert(n_due <= 1);
        assert(out_valid == due);                       // R1 timing, R2
        if (due) begin
            assert(out_row_idx == due_row);             // R1 order
            assert(out_exp == want_exp);                // R3
        end
    end

    // ---- helper rules ("invariants") -------------------------------------
    // These describe the design's internal state in terms of the checker's
    // record. They let the solver prove R1-R3 for ALL time (induction), not
    // just for the first few dozen ticks.
    wire [N*8-1:0] rd_sa  = f_rd_slot  ? f_sa1 : f_sa0;
    wire [N*8-1:0] rd_sb  = f_rd_slot  ? f_sb1 : f_sb0;
    wire [N*8-1:0] cur_sa = f_cur_slot ? f_sa1 : f_sa0;
    wire [N*8-1:0] cur_sb = f_cur_slot ? f_sb1 : f_sb0;
    integer p, q;
    reg [IW:0] win;
    always @(*) if (!init) begin
        assert(f_last_dly == ended[N-1:0]);
        assert(f_wr_slot == (f_rd_slot ^ (|ended[N-1:0])));
        assert(f_draining == (|ended[2*N-2:N]));
        for (p = 0; p < N; p = p + 1)
            if (ended[p]) begin
                assert(rd_sa == sa_d[p] && rd_sb == sb_d[p]);
                assert(beats <= p);
            end
        for (p = N; p < 2*N - 1; p = p + 1)
            if (ended[p]) begin
                assert(f_rd_row == p - N + 1);
                assert(cur_sa == sa_d[p] && cur_sb == sb_d[p]);
                assert(f_cur_slot != f_rd_slot);
            end
        // job ends are at least N ticks apart
        for (p = 0; p + N <= D; p = p + 1) begin
            win = 0;
            for (q = p; q < p + N; q = q + 1) win = win + ended[q];
            assert(win <= 1);
        end
        assert(beats <= N);
    end

    // Show that the interesting case is reachable: two jobs back to back,
    // the second's last row coming out.
    reg [7:0] rows_done = 0;
    always @(posedge clk) if (out_valid && out_row_idx == N - 1) rows_done <= rows_done + 1;
    always @(*) cover(rows_done == 2);
endmodule
