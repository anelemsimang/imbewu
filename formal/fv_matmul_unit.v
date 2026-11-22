// fv_matmul_unit.v - formal proof that the tiling controller always obeys
// the engine's rules, for every allowed configuration, for all time:
//   C1  every job it sends has at least N beats
//   C2  every MX block it sends has at least max(min(G, N), 6) beats
//   C3  every job ends with a block end, and there are no gaps inside a job
//   C4  after a start it sends exactly MT x NT jobs, then stops
// Configurations are free (the solver tries all of them, up to 7 x 7 tiles,
// 7 blocks of up to 31 beats) within the rules:
// cfg_beats = cfg_nb x cfg_bb, cfg_bb >= max(min(G, N), 6), cfg_beats >= N.
module fv_matmul_unit #(parameter N = 4, parameter G = 2) (
    input wire clk,
    input wire start,
    input wire [7:0] cfg_mt, cfg_nt,
    input wire [7:0] cfg_beats, cfg_bb, cfg_nb,
    input wire [1:0] cfg_fa, cfg_fb,
    input wire [N*8-1:0] a_data, b_data, sa_data, sb_data
);
    localparam GE = (N < G) ? N : G;
    localparam GB = (GE > 6) ? GE : 6;   // shortest block the engine allows
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst = init;

    wire busy, done, c_we, f_v, f_bl, f_jl, f_run;
    wire [7:0] a_addr, b_addr, sa_addr, sb_addr, c_addr;
    wire [7:0] f_beat, f_bib, f_blk, f_mt, f_nt;
    wire [N*32-1:0] c_data;
    matmul_unit #(.N(N), .G(G), .AW(8)) dut (.clk(clk), .rst(rst), .start(start),
        .cfg_mt(cfg_mt), .cfg_nt(cfg_nt), .cfg_beats(cfg_beats), .cfg_bb(cfg_bb),
        .cfg_nb(cfg_nb), .cfg_fa(cfg_fa), .cfg_fb(cfg_fb), .busy(busy), .done(done),
        .a_addr(a_addr), .a_data(a_data), .b_addr(b_addr), .b_data(b_data),
        .sa_addr(sa_addr), .sa_data(sa_data), .sb_addr(sb_addr), .sb_data(sb_data),
        .c_we(c_we), .c_addr(c_addr), .c_data(c_data),
        .f_v(f_v), .f_bl(f_bl), .f_jl(f_jl), .f_run(f_run),
        .f_beat(f_beat), .f_bib(f_bib), .f_blk(f_blk), .f_mt(f_mt), .f_nt(f_nt));

    // configuration: fixed, and within the rules
    (* anyconst *) reg [2:0] k_mt, k_nt, k_nb;
    (* anyconst *) reg [4:0] k_bb;
    wire [7:0] beats = k_nb * k_bb;
    always @(*) begin
        assume(k_mt >= 1 && k_nt >= 1 && k_nb >= 1 && k_bb >= GB);
        assume(cfg_mt == k_mt && cfg_nt == k_nt && cfg_nb == k_nb && cfg_bb == k_bb);
        assume(cfg_beats == beats && beats >= N);
        assume(!(start && busy));         // start is only given when idle
    end

    // what the controller issues this tick (the engine receives it next tick)
    wire iv  = f_run;
    wire ibl = f_run && (f_bib == k_bb - 1);
    wire ijl = f_run && (f_beat == beats - 1);

    // checker's counts of what has been issued
    reg [7:0] jb = 0, bb = 0, jobs = 0;
    reg       started = 0;
    reg       p_iv = 0, p_ibl = 0, p_ijl = 0;
    always @(posedge clk) begin
        p_iv <= rst ? 1'b0 : iv; p_ibl <= rst ? 1'b0 : ibl; p_ijl <= rst ? 1'b0 : ijl;
        if (rst) begin jb <= 0; bb <= 0; jobs <= 0; started <= 0; end
        else begin
            if (iv) begin
                jb <= ijl ? 0 : jb + 1;
                bb <= (ibl || ijl) ? 0 : bb + 1;
                if (ijl) jobs <= jobs + 1;
            end
            if (start && !busy && !f_run) begin started <= 1; jobs <= 0; end
        end
    end

    always @(*) if (!init) begin
        // the engine receives exactly what was issued one tick earlier
        assert(f_v == p_iv && f_bl == p_ibl && f_jl == p_ijl);
        // the rules
        if (ijl) assert(jb >= N - 1);                       // C1
        if (ibl || ijl) assert(bb >= GB - 1);               // C2
        if (ijl) assert(ibl);                               // C3: a job ends a block
        if (started) assert(jobs <= k_mt * k_nt);           // C4
        if (started && jobs == k_mt * k_nt) assert(!f_run);
        if (started && !f_run) assert(jobs == k_mt * k_nt);
        if (!started) assert(!f_run);
        // helper rules (invariants)
        if (f_run) begin
            assert(f_beat < beats && f_bib < k_bb && f_blk < k_nb);
            assert(f_beat == f_blk * k_bb + f_bib);
            assert(jb == f_beat && bb == f_bib);
            assert(f_mt < k_mt && f_nt < k_nt);
            assert(jobs == f_mt * k_nt + f_nt);
        end else begin
            assert(jb == 0 && bb == 0);
        end
    end
    // C3 (no gaps): while running, a beat is issued every tick
    always @(*) if (!init && f_run) assert(iv);
    always @(*) cover(started && jobs == k_mt * k_nt && k_mt * k_nt >= 2 && k_nb >= 2);
endmodule
