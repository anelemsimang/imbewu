// tb_systolic_stream.v - tests the streaming engine against a reference model
//
// Sends a continuous stream of jobs C = A(N x K) x B(K x N), with K varying
// per job between N and 3N, and checks every output row. Runs twice:
//   pass 1 - beats back to back, no gaps (measures utilisation)
//   pass 2 - random gaps between beats (checks the tags handle stalls)
// Settings from the command line: -DGRID_N=8 -DJOBS=300
`timescale 1ns/1ps
`ifndef GRID_N
`define GRID_N 4
`endif
`ifndef JOBS
`define JOBS 300
`endif
module tb_systolic_stream;
    localparam N = `GRID_N, JOBS = `JOBS, KMAX = 3*N;
    localparam IW = $clog2(N) + 1;

    reg clk = 0, rst = 1;
    reg in_valid = 0, in_last = 0;
    reg  [N*8-1:0]  a_col = 0, b_row = 0;
    wire            out_valid;
    wire [IW-1:0]   out_row_idx;
    wire [N*32-1:0] out_row;

    systolic_stream #(.N(N)) dut (.clk(clk), .rst(rst), .in_valid(in_valid),
        .in_last(in_last), .a_col(a_col), .b_row(b_row), .out_valid(out_valid),
        .out_row_idx(out_row_idx), .out_row(out_row));
    always #5 clk = ~clk;

    // Test data: A[job][i][k] and B[job][k][j]
    reg signed [7:0] Am [0:JOBS*N*KMAX-1];
    reg signed [7:0] Bm [0:JOBS*KMAX*N-1];
    integer K [0:JOBS-1];
    function integer ai; input integer jb, i, k; ai = (jb*N + i)*KMAX + k; endfunction
    function integer bi; input integer jb, k, j; bi = (jb*KMAX + k)*N + j; endfunction

    integer mj, mk;                 // checker's own loop counters
    integer jb, i, j, k, errors, rows_seen, out_job, out_r, sumK, total_macs;
    integer cyc, first_in, last_out, pass, gap_pct;
    reg signed [31:0] ref_v, got;
    reg done_all;

    always @(posedge clk) cyc <= rst ? 0 : cyc + 1;

    // Monitor: check every row that comes out
    always @(posedge clk) if (!rst && out_valid) begin
        if (out_job >= JOBS) begin
            errors = errors + 1; $display("EXTRA output row");
        end else begin
            if (out_row_idx !== out_r[IW-1:0]) begin
                errors = errors + 1;
                if (errors < 10) $display("ROW ORDER job %0d: got row %0d expected %0d", out_job, out_row_idx, out_r);
            end
            for (mj = 0; mj < N; mj = mj + 1) begin
                ref_v = 0;
                for (mk = 0; mk < K[out_job]; mk = mk + 1)
                    ref_v = ref_v + Am[ai(out_job, out_r, mk)] * Bm[bi(out_job, mk, mj)];
                got = out_row[mj*32 +: 32];
                if (got !== ref_v) begin
                    errors = errors + 1;
                    if (errors < 10)
                        $display("MISMATCH job %0d C[%0d][%0d]: got %0d expected %0d",
                                 out_job, out_r, mj, got, ref_v);
                end
            end
            rows_seen = rows_seen + 1;
            last_out  = cyc;
            if (out_r == N-1) begin out_r = 0; out_job = out_job + 1; end
            else out_r = out_r + 1;
        end
    end

    task make_data;
        begin
            sumK = 0;
            for (jb = 0; jb < JOBS; jb = jb + 1) begin
                // job 0: identity x counting; job 1: all +127, K=N;
                // job 2: all -128 with the longest K; then a mix of K=N and random K
                if (jb < 2) K[jb] = N;
                else if (jb == 2) K[jb] = KMAX;
                else if (jb % 2) K[jb] = N;
                else K[jb] = N + ({$random} % (2*N + 1));
                sumK = sumK + K[jb];
                for (i = 0; i < N; i = i + 1)
                    for (k = 0; k < KMAX; k = k + 1) begin
                        case (jb)
                            0: begin Am[ai(jb,i,k)] = (i == k); Bm[bi(jb,k,i)] = k*N + i + 1; end
                            1: begin Am[ai(jb,i,k)] = 127;      Bm[bi(jb,k,i)] = 127;  end
                            2: begin Am[ai(jb,i,k)] = -128;     Bm[bi(jb,k,i)] = -128; end
                            default: begin Am[ai(jb,i,k)] = $random; Bm[bi(jb,k,i)] = $random; end
                        endcase
                    end
            end
        end
    endtask

    task run_stream;
        begin
            errors = 0; rows_seen = 0; out_job = 0; out_r = 0;
            rst = 1; repeat (3) @(posedge clk); #1 rst = 0;
            @(posedge clk); #1;
            first_in = cyc;
            for (jb = 0; jb < JOBS; jb = jb + 1)
                for (k = 0; k < K[jb]; k = k + 1) begin
                    while (({$random} % 100) < gap_pct) begin   // a gap: garbage data, not valid
                        in_valid = 0; in_last = $random; a_col = {N{$random}}; b_row = {N{$random}};
                        @(posedge clk); #1;
                    end
                    in_valid = 1;
                    in_last  = (k == K[jb] - 1);
                    for (i = 0; i < N; i = i + 1) begin
                        a_col[i*8 +: 8] = Am[ai(jb, i, k)];
                        b_row[i*8 +: 8] = Bm[bi(jb, k, i)];
                    end
                    @(posedge clk); #1;
                end
            in_valid = 0; in_last = 0;
            repeat (4*N + 10) @(posedge clk);
            #1;
            if (rows_seen != JOBS*N) begin
                errors = errors + 1;
                $display("MISSING rows: saw %0d expected %0d", rows_seen, JOBS*N);
            end
        end
    endtask

    initial begin
        make_data;
        total_macs = sumK * N * N;

        gap_pct = 0;  run_stream;
        $display("STREAM %0dx%0d no gaps: %0d jobs, %0d rows, %0d results checked, %0d errors",
                 N, N, JOBS, rows_seen, rows_seen*N, errors);
        $display("STREAM %0dx%0d utilisation: %0d multiply-adds on %0d cells in %0d cycles = %0d.%0d%%",
                 N, N, total_macs, N*N, last_out - first_in + 1,
                 (1000*sumK/(last_out - first_in + 1))/10, (1000*sumK/(last_out - first_in + 1))%10);
        pass = (errors == 0);

        gap_pct = 30; run_stream;
        $display("STREAM %0dx%0d random gaps: %0d jobs, %0d rows, %0d results checked, %0d errors",
                 N, N, JOBS, rows_seen, rows_seen*N, errors);
        pass = pass && (errors == 0);

        if (pass) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
