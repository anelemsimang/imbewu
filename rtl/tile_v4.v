// tile_v4.v - the Imbewu tile, version 4: the vector unit inside the tile
//
// As tile_v3.v, plus a post-processing stage between the engine and main
// memory, so a layer's answers can come out ready to be the next layer's
// input, without a round trip through software:
//   pmode 0: store the FP32 answers C (as tile_v3)
//   pmode 1: round C into MX blocks (format pfmt) and store them in the
//            engine's input layout (A, then A scales), ready for the next
//            command to read
//   pmode 2: first run the vector unit's program on every row of C (SiLU,
//            softmax, RMSNorm, ...), then round and store as in pmode 1
// For each token row the stage copies the row's C words into the vector
// unit, runs its program (results at vector address 64 onwards), sends the
// results through the FP32 -> MX converter (mx_quant.v, block of 32 along
// the row), and a transpose buffer collects N tokens and writes them in
// the input layout: word k = the N tokens' codes for column k.
// A command with dep = 1 fetches its activations only after every earlier
// command has been stored, so it can read what they wrote (layer chaining).
//
// Command: 224 bits = tile_v3's 200 bits (cmd[199:0]) plus
//   [223:222] pmode, [221:220] pfmt (0 INT8, 1 FP8, 2 FP4), [219] dep.
// In pmodes 1 and 2 the output (at out_addr) is mt x (nt*N + nt*N/32)
// words: nt*N must be a multiple of 32, and nt at most 64.
// The vector unit is version 2 (vu_v2.v: one-instruction 2^x and 1/x;
// version 1 programs also run unchanged). Its program, constants and fixed data (e.g. RMSNorm's
// gamma at vector address 32) are loaded through the vu_* ports before
// start; one program serves every command of the run.
// ---------------------------------------------------------------------------
// tile_v3.v - the Imbewu tile, version 3: weights fetched well ahead
//
// As tile_v2.v, but a command's weights (B and its scales) are fetched by
// their own transfer, which may start as soon as the weight slot is free
// (every earlier command using that slot has been computed), however far
// ahead that is. Activations (A and its scales) are fetched one command
// ahead as before. Main-memory layout per command: A, A scales, then (if
// it brings weights) B, B scales.
// ---------------------------------------------------------------------------
// tile_v2.v - the Imbewu tile, version 2: weights stay in the tile
//
// Same as tile_v1.v, plus: B (the model's weights) and its scales live in
// two "weight slots" that are NOT swapped every command. Each command names
// its slot (b_slot). A command that brings new weights (n_b > 0) loads them
// into its slot; a command with n_b = 0 reuses what is already there. So a
// model layer's weights are fetched once and reused by many batches of
// activations (A), which is how language models are actually run. A slot is
// only overwritten once every earlier command using it has been computed.
//
// Command field added: b_slot = bit 19 (inside the 20 unused bits).
// tile_v3 adds: pk = bit 18: the FP4 side is packed two per lane (D-020).
// and w_at = bits 17:0: if not zero, the command's weights (B, then B
// scales) are read from main-memory address 4 x w_at instead of straight
// after A and its scales. So several commands, on one tile or several, can
// share one copy of their activations (needed for broadcast, cluster.v).
// ---------------------------------------------------------------------------
// (Description of version 1 follows.)
// tile_v1.v - the Imbewu tile, first version (Phase 2; goals G1, G3, G4)
//
// Plain language: main memory (HBM) is big but far away: every request takes
// many ticks to answer, and it delivers a limited amount per tick. The tile
// hides that wait. It holds a list of matrix multiplies ("commands"). While
// the engine works on command k from one half of the tile's own memory
// (SRAM), a data mover fetches command k+1 into the other half, and sends
// the finished results of command k-1 back to main memory. If fetching is
// quicker than computing, the engine never waits.
//
// Parts: SRAM blocks for A, B, their scales and C, each in two halves;
// matmul_unit (tiling controller + version 5 engine); a data mover with
// one main-memory port; a scheduler.
//
// Main-memory port (one word of N bytes per request; reads answered in
// order, any number of ticks later):
//   mem_req, mem_we, mem_addr, mem_wdata, mem_ready (request accepted)
//   mem_rvalid, mem_rdata                          (read answers)
//
// Command list (written before start): for each command, its inputs lie
// one after another in main memory from in_addr: A (n_a words), B (n_b),
// A scales (n_sa), B scales (n_sb), in the layout of matmul_unit.v. Its
// answer C (n_c words of N x FP32) is written from out_addr, each C word
// as 4 main-memory words (lowest lanes first).
module tile_v4 #(
    parameter N   = 4,
    parameter G   = 16,
    parameter SAW = 10,          // SRAM address width per half
    parameter EAW = 20,          // main-memory address width
    parameter NCMD = 16
) (
    input  wire              clk,
    input  wire              rst,
    // command list
    input  wire              cmd_we,
    input  wire [3:0]        cmd_idx,
    input  wire [223:0]      cmd_data,
    input  wire [4:0]        n_cmds,
    input  wire              start,
    output reg               busy,
    output reg               done,
    // main memory
    output reg               mem_req,
    output reg               mem_we,
    output reg  [EAW-1:0]    mem_addr,
    output reg  [N*8-1:0]    mem_wdata,
    input  wire              mem_ready,
    input  wire              mem_rvalid,
    input  wire [N*8-1:0]    mem_rdata,
    // vector unit: program, constants, fixed data (loaded before start)
    input  wire              vu_imem_we,
    input  wire [9:0]        vu_imem_addr,
    input  wire [31:0]       vu_imem_data,
    input  wire              vu_cmem_we,
    input  wire [5:0]        vu_cmem_addr,
    input  wire [31:0]       vu_cmem_data,
    input  wire              vu_vmem_we,
    input  wire [7:0]        vu_vmem_addr,
    input  wire [N*32-1:0]   vu_vmem_wdata,
    // counters for measurement
    output reg  [31:0]       ticks_busy,
    output reg  [31:0]       ticks_engine,
    output reg  [31:0]       ticks_post
);
    localparam W8 = N * 8, W32 = N * 32;

    // ---- command list -----------------------------------------------------
    // fields (from bit 199 down): in_addr 20, n_a 16, n_b 16, n_sa 12, n_sb 12,
    // out_addr 20, n_c 16, mt 8, nt 8, beats 16, bb 16, nb 16, fa 2, fb 2, unused 20
    reg [223:0] cmds [0:NCMD-1];
    always @(posedge clk) if (cmd_we) cmds[cmd_idx] <= cmd_data;
    function [19:0] f_in;   input [223:0] c; f_in   = c[199:180]; endfunction
    function [15:0] f_na;   input [223:0] c; f_na   = c[179:164]; endfunction
    function [15:0] f_nb;   input [223:0] c; f_nb   = c[163:148]; endfunction
    function [11:0] f_nsa;  input [223:0] c; f_nsa  = c[147:136]; endfunction
    function [11:0] f_nsb;  input [223:0] c; f_nsb  = c[135:124]; endfunction
    function [19:0] f_out;  input [223:0] c; f_out  = c[123:104]; endfunction
    function [15:0] f_nc;   input [223:0] c; f_nc   = c[103:88];  endfunction

    // ---- SRAM (two halves each: the top address bit picks the half) --------
    wire [SAW-1:0] mm_a_addr, mm_b_addr, mm_sa_addr, mm_sb_addr, mm_c_addr;
    wire [W8-1:0]  a_rd, b_rd, sa_rd, sb_rd;
    wire [W32-1:0] c_rd, mm_c_data;
    wire           mm_c_we;
    reg            comp_half;                // half the engine is using (A, scales, C)
    reg            comp_slot;                // weight slot the engine is using (B)
    reg  [SAW:0]   ld_baddr;                 // write address in the weight slots
    reg            ld_we_a, ld_we_b, ld_we_sa, ld_we_sb;
    reg  [SAW:0]   ld_waddr;
    reg  [W8-1:0]  ld_wdata;
    reg  [SAW:0]   st_raddr;

    sram_1r1w #(W8, SAW+1) u_a  (clk, {comp_half, mm_a_addr},  a_rd,  ld_we_a,  ld_waddr, ld_wdata);
    sram_1r1w #(W8, SAW+1) u_b  (clk, {comp_slot, mm_b_addr},  b_rd,  ld_we_b,  ld_baddr, ld_wdata);
    sram_1r1w #(W8, SAW+1) u_sa (clk, {comp_half, mm_sa_addr}, sa_rd, ld_we_sa, ld_waddr, ld_wdata);
    sram_1r1w #(W8, SAW+1) u_sb (clk, {comp_slot, mm_sb_addr}, sb_rd, ld_we_sb, ld_baddr, ld_wdata);
    sram_1r1w #(W32, SAW+1) u_c (clk, st_raddr, c_rd, mm_c_we, {comp_half, mm_c_addr}, mm_c_data);

    // ---- the engine and its tiling controller -----------------------------
    reg  [223:0] ccmd;                       // command being computed
    reg          mm_start;
    wire         mm_busy, mm_done, mm_feed;
    wire [15:0]  a16, b16, sa16, sb16, c16;
    matmul_unit #(.N(N), .G(G), .AW(16)) u_mm (
        .clk(clk), .rst(rst), .start(mm_start),
        .cfg_mt(ccmd[87:80]), .cfg_nt(ccmd[79:72]), .cfg_beats(ccmd[71:56]),
        .cfg_bb(ccmd[55:40]), .cfg_nb(ccmd[39:24]), .cfg_fa(ccmd[23:22]), .cfg_fb(ccmd[21:20]), .cfg_pk(ccmd[18]),
        .busy(mm_busy), .done(mm_done), .feed(mm_feed),
        .a_addr(a16), .a_data(a_rd), .b_addr(b16), .b_data(b_rd),
        .sa_addr(sa16), .sa_data(sa_rd), .sb_addr(sb16), .sb_data(sb_rd),
        .c_we(mm_c_we), .c_addr(c16), .c_data(mm_c_data));
    assign mm_a_addr = a16[SAW-1:0];  assign mm_b_addr = b16[SAW-1:0];
    assign mm_sa_addr = sa16[SAW-1:0]; assign mm_sb_addr = sb16[SAW-1:0];
    assign mm_c_addr = c16[SAW-1:0];

    // ---- scheduler state ----------------------------------------------------
    reg [4:0] nld, ncomp, nst;               // commands loaded / computed / stored
    reg [4:0] npost;                         // commands post-processed
    reg       computing;
    // last command (so far loaded) that uses each weight slot
    reg [4:0] lu [0:1];
    reg       lu_v [0:1];
    function f_slot; input [223:0] c; f_slot = c[19]; endfunction
    function [17:0] f_wat; input [223:0] c; f_wat = c[17:0]; endfunction
    function [1:0]  f_pmode; input [223:0] c; f_pmode = c[223:222]; endfunction
    function [1:0]  f_pfmt;  input [223:0] c; f_pfmt  = c[221:220]; endfunction
    function        f_dep;   input [223:0] c; f_dep   = c[219];     endfunction
    function [7:0]  f_mt;    input [223:0] c; f_mt    = c[87:80];   endfunction
    function [7:0]  f_nt;    input [223:0] c; f_nt    = c[79:72];   endfunction

    // ---- data mover ---------------------------------------------------------
    localparam D_IDLE = 0, D_LOAD = 1, D_ST_RD = 2, D_ST_WAIT = 3, D_ST_CAP = 4, D_ST_SEND = 5;
    reg [2:0]     dstate;
    reg [223:0]   dcmd;                      // command being moved
    reg           dhalf;
    reg [16:0]    iss, rcv, total;           // load: words requested / received / total
    reg [EAW-1:0] dbase;                     // load: main-memory address of the first word
    reg [15:0]    na, nab, nabs;             // load: region boundaries
    reg [15:0]    cw;                        // store: C word index
    reg [1:0]     part;
    reg [W32-1:0] cbuf;

    // Loads are split in two: the request side sends a command's read
    // requests and moves on at once; the answer side files the answers
    // as they arrive, using a small queue that says which command (and
    // which halves / slot) the next answers belong to. So the memory delay
    // of one transfer overlaps the next.
    reg [4:0]  nli;                          // activation loads whose requests are sent
    reg [4:0]  kw;                           // next command whose weights may be fetched
    reg [15:0] wready;                       // weights of command k have arrived
    reg [15:0] q_na [0:3], q_nab [0:3], q_nabs [0:3];
    reg [16:0] q_tot [0:3];
    reg        q_half [0:3], q_slot [0:3], q_w [0:3];
    reg [3:0]  q_cmd [0:3];
    reg [1:0]  qw, qr;
    reg  [2:0] qn;                           // transfers waiting for answers
    wire [223:0] ncmd_ld = cmds[nli[3:0]];
    wire [223:0] wcmd    = cmds[kw[3:0]];
    wire wslot = f_slot(wcmd);
    // a slot may be refilled once no uncomputed earlier command still uses it
    reg slot_busy;
    integer j;
    always @(*) begin
        slot_busy = 1'b0;
        for (j = 0; j < NCMD; j = j + 1)
            if (j < kw && j >= ncomp && f_slot(cmds[j]) == wslot) slot_busy = 1'b1;
    end
    wire w_needed  = (kw < n_cmds) && (f_nb(wcmd) != 16'd0);
    wire can_wload = w_needed && !slot_busy && qn < 3;
    wire can_load  = (nli < n_cmds) && (nli < ncomp + 2) && qn < 3 &&
                     (!f_dep(ncmd_ld) || nst >= nli);     // dep: earlier results stored first
    // order of the data mover's choices: weights the engine is waiting for
    // now; activations for the next command; weights needed soon; results
    // (which free a C half); weights for later
    wire w_now = can_wload && kw <= ncomp;
    wire a_go  = can_load && !w_now;
    wire w_go  = can_wload && (w_now || !can_store || kw <= ncomp + 1);
    reg  dslot;
    wire can_store = (nst < npost);          // stored after post-processing

    // ---- post-processing: vector unit, FP32 -> MX converter, transpose ----------
    localparam CMAX = 64 * N;                // longest row: 64 words of N numbers
    localparam D_PST = 6;                    // data mover: storing post-processed words
    reg          posting;                    // the post stage owns the vector unit's ports
    reg          vu_start;
    wire         vu_busy;
    reg          p_vwe;
    reg  [7:0]   p_vaddr;
    reg  [W32-1:0] p_vwdata;
    wire [W32-1:0] vu_rdata;
    vu_v2 #(.L(N)) u_vu (
        .clk(clk), .rst(rst),
        .imem_we(vu_imem_we), .imem_addr(vu_imem_addr), .imem_data(vu_imem_data),
        .cmem_we(vu_cmem_we), .cmem_addr(vu_cmem_addr), .cmem_data(vu_cmem_data),
        .vmem_we(posting ? p_vwe : vu_vmem_we), .vmem_addr(posting ? p_vaddr : vu_vmem_addr),
        .vmem_wdata(posting ? p_vwdata : vu_vmem_wdata), .vmem_rdata(vu_rdata),
        .start(vu_start), .busy(vu_busy), .ticks());

    reg            q_iv;
    reg  [W32-1:0] q_id;
    reg  [1:0]     q_fmt;
    wire           q_ov, q_olast;
    wire [W8-1:0]  q_codes;
    wire [7:0]     q_scale;
    mx_quant #(.N(N)) u_q (.clk(clk), .rst(rst), .fmt(q_fmt), .in_valid(q_iv), .in_data(q_id),
        .out_valid(q_ov), .out_codes(q_codes), .out_last(q_olast), .out_scale(q_scale));

    // transpose buffer: codes and block scales of N tokens (lane = token)
    reg [7:0]  tq [0:N*CMAX-1];              // token i, column c at i*CMAX + c
    reg [7:0]  ts [0:N*(CMAX/32)-1];         // token i, block b at i*(CMAX/32) + b
    // post-processed output, in the engine's input layout (A, then A scales)
    reg [W8-1:0] pmem [0:2*(1<<SAW)+63];

    localparam PS_IDLE = 0, PS_RD = 1, PS_WT = 2, PS_CAP = 3, PS_VU = 4, PS_VUW1 = 5,
               PS_VUW = 6, PS_FEED = 7, PS_ROWEND = 8, PS_DRAIN = 9, PS_EMIT = 10;
    reg [3:0]   pstate;
    reg [223:0] pcmd;
    reg         phalf;
    reg [15:0]  pr, pw, fi, pe;              // row, word in row, word fed, word emitted
    reg         fv;                          // a word is being fed to the converter
    reg [15:0]  qrow, qword, qblk;           // converter output position
    reg [15:0]  pi;                          // data mover: post-processed words stored
    wire [7:0]  p_nt  = f_nt(pcmd);
    wire [15:0] p_kc  = f_nt(pcmd) * N;      // columns per row (next layer's K)
    wire [15:0] p_kb  = p_kc / 32;           // blocks per row
    wire [15:0] p_rows = f_mt(pcmd) * N;
    wire [15:0] p_tile = (pr - 1) / N;       // token tile just finished (in PS_EMIT)
    wire [15:0] n_p   = f_mt(dcmd) * (f_nt(dcmd) * N + f_nt(dcmd) * N / 32);
    integer li;

    always @(posedge clk) begin
        ld_we_a <= 1'b0; ld_we_b <= 1'b0; ld_we_sa <= 1'b0; ld_we_sb <= 1'b0;
        mm_start <= 1'b0;
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0; dstate <= D_IDLE; mem_req <= 1'b0; mem_we <= 1'b0;
            nld <= 0; ncomp <= 0; nst <= 0; computing <= 1'b0; comp_half <= 1'b0;
            nli <= 0; qw <= 0; qr <= 0; qn <= 0; rcv <= 0; kw <= 0; wready <= 0;
            comp_slot <= 1'b0;
            ticks_busy <= 0; ticks_engine <= 0;
            npost <= 0; posting <= 1'b0; pstate <= PS_IDLE; vu_start <= 1'b0; p_vwe <= 1'b0;
            q_iv <= 1'b0; fv <= 1'b0; ticks_post <= 0;
            // counters of the post stage start defined (found by gate-level
            // simulation: an unset counter there never settles)
            pr <= 0; pw <= 0; fi <= 0; pe <= 0; qrow <= 0; qword <= 0; qblk <= 0; pi <= 0;
        end else begin
            if (start && !busy) begin
                busy <= 1'b1; nld <= 0; ncomp <= 0; nst <= 0; computing <= 1'b0;
                nli <= 0; qw <= 0; qr <= 0; qn <= 0; rcv <= 0; kw <= 0; wready <= 0;
                ticks_busy <= 0; ticks_engine <= 0;
                npost <= 0; ticks_post <= 0;
            end
            if (busy) begin
                ticks_busy <= ticks_busy + 1;
                if (mm_feed) ticks_engine <= ticks_engine + 1;     // engine fed a beat
            end

            // compute: next command when its inputs are in, the engine is free,
            // and its C half has been emptied
            if (busy && !computing && ncomp < nld && ncomp < nst + 2 && !mm_busy &&
                (f_nb(cmds[ncomp[3:0]]) == 16'd0 || wready[ncomp[3:0]])) begin
                ccmd      <= cmds[ncomp[3:0]];
                comp_half <= ncomp[0];
                comp_slot <= f_slot(cmds[ncomp[3:0]]);
                mm_start  <= 1'b1;
                computing <= 1'b1;
            end
            if (computing && mm_done) begin
                computing <= 1'b0;
                ncomp     <= ncomp + 1;
            end

            // ---- post-processing (one command at a time, after earlier ones are stored)
            vu_start <= 1'b0; p_vwe <= 1'b0;
            q_iv <= fv; q_id <= vu_rdata; fv <= 1'b0;   // word addressed last tick -> converter
            if (posting) ticks_post <= ticks_post + 1;
            case (pstate)
            PS_IDLE:
                if (busy && npost < ncomp) begin
                    if (f_pmode(cmds[npost[3:0]]) == 2'd0) npost <= npost + 1;    // nothing to do
                    else if (nst == npost) begin
`ifndef SYNTHESIS
                        // the stated limits (header): checked in simulation, so a
                        // command that breaks them stops the run instead of
                        // silently losing data
                        if (f_nt(cmds[npost[3:0]]) > 64 || (f_nt(cmds[npost[3:0]]) * N) % 32 != 0 ||
                            f_mt(cmds[npost[3:0]]) * (f_nt(cmds[npost[3:0]]) * N + f_nt(cmds[npost[3:0]]) * N / 32)
                                > 2 * (1 << SAW) + 64) begin
                            $display("tile_v4 ERROR: command %0d breaks the post-processing limits (nt %0d, mt %0d)",
                                     npost, f_nt(cmds[npost[3:0]]), f_mt(cmds[npost[3:0]]));
                            $finish;
                        end
`endif
                        pcmd    <= cmds[npost[3:0]];
                        phalf   <= npost[0];
                        q_fmt   <= f_pfmt(cmds[npost[3:0]]);
                        pr <= 0; pw <= 0;
                        qrow <= 0; qword <= 0; qblk <= 0;
                        posting <= 1'b1;
                        pstate  <= PS_RD;
                    end
                end
            PS_RD: begin                         // ask the C SRAM for word pw of row pr
                st_raddr <= {phalf, pr[SAW-1:0] * p_nt + pw[SAW-1:0]};
                pstate   <= PS_WT;
            end
            PS_WT: pstate <= PS_CAP;
            PS_CAP: begin                        // copy it into the vector unit at pw
                p_vwe <= 1'b1; p_vaddr <= pw[7:0]; p_vwdata <= c_rd;
                if (pw + 1 == p_nt) begin
                    pw <= 0; fi <= 0;
                    pstate <= (f_pmode(pcmd) == 2'd2) ? PS_VU : PS_FEED;
                end else begin
                    pw <= pw + 1; pstate <= PS_RD;
                end
            end
            PS_VU:   begin vu_start <= 1'b1; pstate <= PS_VUW1; end
            PS_VUW1: pstate <= PS_VUW;
            PS_VUW:  if (!vu_busy) pstate <= PS_FEED;
            PS_FEED: begin                       // results (or the copied row) to the converter
                p_vaddr <= ((f_pmode(pcmd) == 2'd2) ? 8'd64 : 8'd0) + fi[7:0];
                fv <= 1'b1;
                if (fi + 1 == p_nt) pstate <= PS_ROWEND; else fi <= fi + 1;
            end
            PS_ROWEND: begin
                pr <= pr + 1;
                pstate <= ((pr + 1) % N == 0) ? PS_DRAIN : PS_RD;
            end
            PS_DRAIN:                            // wait for the converter to finish these rows
                if (qrow == pr && !fv && !q_iv) begin pe <= 0; pstate <= PS_EMIT; end
            PS_EMIT: begin                       // transposed words: A columns, then scales
                if (pe < p_kc) begin
                    for (li = 0; li < N; li = li + 1)
                        pmem[p_tile * p_kc + pe][8*li +: 8] <= tq[li * CMAX + pe];
                end else begin
                    for (li = 0; li < N; li = li + 1)
                        pmem[f_mt(pcmd) * p_kc + p_tile * p_kb + (pe - p_kc)][8*li +: 8] <= ts[li * (CMAX/32) + pe - p_kc];
                end
                if (pe + 1 == p_kc + p_kb) begin
                    if (pr == p_rows) begin
                        posting <= 1'b0; npost <= npost + 1; pstate <= PS_IDLE;
                    end else pstate <= PS_RD;
                end else pe <= pe + 1;
            end
            default: pstate <= PS_IDLE;
            endcase
            // converter output -> transpose buffer
            if (q_ov) begin
                for (li = 0; li < N; li = li + 1)
                    tq[(qrow % N) * CMAX + qword * N + li] <= q_codes[8*li +: 8];
                if (q_olast) begin
                    ts[(qrow % N) * (CMAX/32) + qblk] <= q_scale;
                    qblk <= qblk + 1;
                end
                if (qword + 1 == p_nt) begin qword <= 0; qblk <= 0; qrow <= qrow + 1; end
                else qword <= qword + 1;
            end

            // answer side: put each answer into the right SRAM
            if (mem_rvalid) begin
                ld_wdata <= mem_rdata;
                if (rcv < q_na[qr]) begin
                    ld_we_a <= 1'b1; ld_waddr <= {q_half[qr], rcv[SAW-1:0]};
                end else if (rcv < q_nab[qr]) begin
                    ld_we_b <= 1'b1; ld_baddr <= {q_slot[qr], rcv[SAW-1:0] - q_na[qr][SAW-1:0]};
                end else if (rcv < q_nabs[qr]) begin
                    ld_we_sa <= 1'b1; ld_waddr <= {q_half[qr], rcv[SAW-1:0] - q_nab[qr][SAW-1:0]};
                end else begin
                    ld_we_sb <= 1'b1; ld_baddr <= {q_slot[qr], rcv[SAW-1:0] - q_nabs[qr][SAW-1:0]};
                end
                if (rcv + 1 == q_tot[qr]) begin
                    rcv <= 0; qr <= qr + 1;
                    if (q_w[qr]) wready[q_cmd[qr]] <= 1'b1;
                    else nld <= nld + 1;
                end else rcv <= rcv + 1;
            end
            // transfers in flight: +1 when one is started, -1 when its last answer arrives
            qn <= qn + ((dstate == D_IDLE && busy && (a_go || w_go)) ? 3'd1 : 3'd0)
                     - ((mem_rvalid && rcv + 1 == q_tot[qr]) ? 3'd1 : 3'd0);
            // skip commands that bring no weights
            if (kw < n_cmds && f_nb(wcmd) == 16'd0) kw <= kw + 1;

            // data mover (request side)
            case (dstate)
            D_IDLE: begin
                mem_req <= 1'b0; mem_we <= 1'b0;
                if (busy && a_go) begin               // activations, one command ahead
                    dcmd  <= ncmd_ld;
                    total <= f_na(ncmd_ld) + f_nsa(ncmd_ld);
                    q_na[qw]   <= f_na(ncmd_ld);
                    q_nab[qw]  <= f_na(ncmd_ld);           // no B in this transfer
                    q_nabs[qw] <= f_na(ncmd_ld) + f_nsa(ncmd_ld);
                    q_tot[qw]  <= f_na(ncmd_ld) + f_nsa(ncmd_ld);
                    q_half[qw] <= nli[0];
                    q_slot[qw] <= 1'b0;
                    q_w[qw]    <= 1'b0;
                    q_cmd[qw]  <= nli[3:0];
                    qw  <= qw + 1;
                    nli <= nli + 1;
                    iss <= 0; dbase <= f_in(ncmd_ld);
                    dstate <= D_LOAD;
                end else if (busy && w_go) begin       // weights, as early as the slot allows
                    dcmd  <= wcmd;
                    total <= f_nb(wcmd) + f_nsb(wcmd);
                    q_na[qw]   <= 16'd0;
                    q_nab[qw]  <= f_nb(wcmd);
                    q_nabs[qw] <= f_nb(wcmd);              // no A scales in this transfer
                    q_tot[qw]  <= f_nb(wcmd) + f_nsb(wcmd);
                    q_half[qw] <= 1'b0;
                    q_slot[qw] <= wslot;
                    q_w[qw]    <= 1'b1;
                    q_cmd[qw]  <= kw[3:0];
                    qw  <= qw + 1;
                    kw  <= kw + 1;
                    iss <= 0;                              // weights at w_at, else after A and its scales
                    dbase <= (f_wat(wcmd) != 18'd0) ? {f_wat(wcmd), 2'b00} : f_in(wcmd) + f_na(wcmd) + f_nsa(wcmd);
                    dstate <= D_LOAD;
                end else if (busy && can_store) begin
                    dcmd  <= cmds[nst[3:0]];
                    dhalf <= nst[0];
                    cw    <= 0;
                    pi    <= 0;
                    dstate <= (f_pmode(cmds[nst[3:0]]) != 2'd0) ? D_PST : D_ST_RD;
                end else if (busy && nst == n_cmds) begin
                    busy <= 1'b0; done <= 1'b1;
                end
            end
            D_LOAD: begin
                // ask for the next word whenever main memory accepts one,
                // then move on without waiting for the answers
                if (mem_req && mem_ready) iss <= iss + 1;
                mem_req  <= (iss + (mem_req && mem_ready) < total);
                mem_we   <= 1'b0;
                mem_addr <= dbase + iss + (mem_req && mem_ready);
                if (iss + (mem_req && mem_ready) == total) begin
                    mem_req <= 1'b0;
                    dstate  <= D_IDLE;
                end
            end
            D_ST_RD: begin                       // ask SRAM for one C word
                mem_req  <= 1'b0;
                st_raddr <= {dhalf, cw[SAW-1:0]};
                dstate   <= D_ST_WAIT;
            end
            D_ST_WAIT: dstate <= D_ST_CAP;       // SRAM answers one tick later
            D_ST_CAP: begin                      // keep the word, send quarter 0
                cbuf      <= c_rd;
                part      <= 2'd0;
                mem_req   <= 1'b1;
                mem_we    <= 1'b1;
                mem_addr  <= f_out(dcmd) + {cw, 2'b00};
                mem_wdata <= c_rd[W8-1:0];
                dstate    <= D_ST_SEND;
            end
            D_ST_SEND: begin                     // send quarters 1-3 as each is accepted
                if (mem_ready) begin
                    if (part == 2'd1)            // meanwhile, fetch the next C word
                        st_raddr <= {dhalf, cw[SAW-1:0] + 1'b1};
                    if (part == 2'd3) begin
                        cw <= cw + 1;
                        if (cw + 1 == f_nc(dcmd)) begin
                            mem_req <= 1'b0; mem_we <= 1'b0;
                            nst <= nst + 1;
                            dstate <= D_IDLE;
                        end else begin           // next word is already here: no gap
                            cbuf      <= c_rd;
                            part      <= 2'd0;
                            mem_addr  <= f_out(dcmd) + {cw + 1'b1, 2'b00};
                            mem_wdata <= c_rd[W8-1:0];
                        end
                    end else begin
                        part      <= part + 1;
                        mem_addr  <= f_out(dcmd) + {cw, 2'b00} + part + 1;
                        mem_wdata <= cbuf >> (W8 * (part + 1));
                    end
                end
            end
            D_PST: begin                         // post-processed words, one per request
                if (mem_req && mem_ready) pi <= pi + 1;
                mem_req   <= (pi + (mem_req && mem_ready) < n_p);
                mem_we    <= 1'b1;
                mem_addr  <= f_out(dcmd) + pi + (mem_req && mem_ready);
                mem_wdata <= pmem[pi + (mem_req && mem_ready)];
                if (pi + (mem_req && mem_ready) == n_p) begin
                    mem_req <= 1'b0; mem_we <= 1'b0;
                    nst <= nst + 1;
                    dstate <= D_IDLE;
                end
            end
            default: dstate <= D_IDLE;
            endcase
        end
    end
endmodule
