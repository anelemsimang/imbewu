// tb_systolic_array.v - tests the NxN systolic engine against a reference model
//
// Runs hand-picked cases (identity, all-max, all-min) plus random matrix
// pairs, and records a waveform of the first run to build/systolic_N<N>.vcd.
// Grid size and trial count are set from the command line:
//   iverilog -DGRID_N=8 -DTRIALS=1000 ...
`timescale 1ns/1ps
`ifndef GRID_N
`define GRID_N 4
`endif
`ifndef TRIALS
`define TRIALS 1000
`endif
module tb_systolic_array;
    localparam N = `GRID_N, TRIALS = `TRIALS;
    reg clk = 0, rst = 1, start = 0;
    reg  [N*N*8-1:0]  a_flat, b_flat;
    wire [N*N*32-1:0] c_flat;
    wire busy, done;
    integer r, c, k, trial, errors = 0, cycles;
    reg signed [31:0] ref_c, got;

    systolic_array #(.N(N)) dut (.clk(clk), .rst(rst), .start(start),
        .a_flat(a_flat), .b_flat(b_flat), .c_flat(c_flat), .busy(busy), .done(done));
    always #5 clk = ~clk;

    function signed [7:0] A; input integer r, c; A = a_flat[(r*N+c)*8 +: 8]; endfunction
    function signed [7:0] B; input integer r, c; B = b_flat[(r*N+c)*8 +: 8]; endfunction

    task run_and_check;
        begin
            @(posedge clk); #1 start = 1;
            @(posedge clk); #1 start = 0;
            cycles = 1;
            while (!done) begin @(posedge clk); #1 cycles = cycles + 1; end
            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1) begin
                    ref_c = 0;
                    for (k = 0; k < N; k = k + 1) ref_c = ref_c + A(r,k) * B(k,c);
                    got = c_flat[(r*N+c)*32 +: 32];
                    if (got !== ref_c) begin
                        errors = errors + 1;
                        if (errors < 10)
                            $display("MISMATCH trial %0d C[%0d][%0d]: got %0d expected %0d",
                                     trial, r, c, got, ref_c);
                    end
                end
        end
    endtask

    initial begin
        $dumpfile($sformatf("build/systolic_N%0d.vcd", N));
        $dumpvars(0, tb_systolic_array);
        a_flat = 0; b_flat = 0;
        repeat (2) @(posedge clk); #1 rst = 0;

        // Case 1: A = identity, B = 1, 2, 3, ...  ->  C must equal B
        trial = -3;
        for (r = 0; r < N; r = r + 1) for (c = 0; c < N; c = c + 1) begin
            a_flat[(r*N+c)*8 +: 8] = (r == c) ? 8'd1 : 8'd0;
            b_flat[(r*N+c)*8 +: 8] = r*N + c + 1;
        end
        run_and_check;
        $dumpoff;
        $display("SYSTOLIC %0dx%0d latency: %0d cycles for %0d multiply-adds on %0d cells",
                 N, N, cycles, N*N*N, N*N);

        // Case 2: all +127 (largest INT8)
        trial = -2; a_flat = {N*N{8'sd127}}; b_flat = {N*N{8'sd127}}; run_and_check;
        // Case 3: all -128 (smallest INT8)
        trial = -1; a_flat = {N*N{8'h80}};   b_flat = {N*N{8'h80}};   run_and_check;

        // Random cases
        for (trial = 0; trial < TRIALS; trial = trial + 1) begin
            for (r = 0; r < N*N; r = r + 1) begin
                a_flat[r*8 +: 8] = $random;
                b_flat[r*8 +: 8] = $random;
            end
            run_and_check;
        end

        $display("SYSTOLIC %0dx%0d: %0d matrix multiplications (%0d results checked), %0d errors",
                 N, N, TRIALS + 3, (TRIALS + 3) * N * N, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
