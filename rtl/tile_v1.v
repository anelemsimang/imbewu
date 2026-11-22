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
module tile_v1 #(
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
    input  wire [199:0]      cmd_data,
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
    // counters for measurement
    output reg  [31:0]       ticks_busy,
    output reg  [31:0]       ticks_engine
);
    localparam W8 = N * 8, W32 = N * 32;

    // ---- command list -----------------------------------------------------
    // fields (from bit 199 down): in_addr 20, n_a 16, n_b 16, n_sa 12, n_sb 12,
    // out_addr 20, n_c 16, mt 8, nt 8, beats 16, bb 16, nb 16, fa 2, fb 2, unused 20
    reg [199:0] cmds [0:NCMD-1];
    always @(posedge clk) if (cmd_we) cmds[cmd_idx] <= cmd_data;
    function [19:0] f_in;   input [199:0] c; f_in   = c[199:180]; endfunction
    function [15:0] f_na;   input [199:0] c; f_na   = c[179:164]; endfunction
    function [15:0] f_nb;   input [199:0] c; f_nb   = c[163:148]; endfunction
    function [11:0] f_nsa;  input [199:0] c; f_nsa  = c[147:136]; endfunction
    function [11:0] f_nsb;  input [199:0] c; f_nsb  = c[135:124]; endfunction
    function [19:0] f_out;  input [199:0] c; f_out  = c[123:104]; endfunction
    function [15:0] f_nc;   input [199:0] c; f_nc   = c[103:88];  endfunction

    // ---- SRAM (two halves each: the top address bit picks the half) --------
    wire [SAW-1:0] mm_a_addr, mm_b_addr, mm_sa_addr, mm_sb_addr, mm_c_addr;
    wire [W8-1:0]  a_rd, b_rd, sa_rd, sb_rd;
    wire [W32-1:0] c_rd, mm_c_data;
    wire           mm_c_we;
    reg            comp_half;                // half the engine is using
    reg            ld_we_a, ld_we_b, ld_we_sa, ld_we_sb;
    reg  [SAW:0]   ld_waddr;
    reg  [W8-1:0]  ld_wdata;
    reg  [SAW:0]   st_raddr;

    sram_1r1w #(W8, SAW+1) u_a  (clk, {comp_half, mm_a_addr},  a_rd,  ld_we_a,  ld_waddr, ld_wdata);
    sram_1r1w #(W8, SAW+1) u_b  (clk, {comp_half, mm_b_addr},  b_rd,  ld_we_b,  ld_waddr, ld_wdata);
    sram_1r1w #(W8, SAW+1) u_sa (clk, {comp_half, mm_sa_addr}, sa_rd, ld_we_sa, ld_waddr, ld_wdata);
    sram_1r1w #(W8, SAW+1) u_sb (clk, {comp_half, mm_sb_addr}, sb_rd, ld_we_sb, ld_waddr, ld_wdata);
    sram_1r1w #(W32, SAW+1) u_c (clk, st_raddr, c_rd, mm_c_we, {comp_half, mm_c_addr}, mm_c_data);

    // ---- the engine and its tiling controller -----------------------------
    reg  [199:0] ccmd;                       // command being computed
    reg          mm_start;
    wire         mm_busy, mm_done, mm_feed;
    wire [15:0]  a16, b16, sa16, sb16, c16;
    matmul_unit #(.N(N), .G(G), .AW(16)) u_mm (
        .clk(clk), .rst(rst), .start(mm_start),
        .cfg_mt(ccmd[87:80]), .cfg_nt(ccmd[79:72]), .cfg_beats(ccmd[71:56]),
        .cfg_bb(ccmd[55:40]), .cfg_nb(ccmd[39:24]), .cfg_fa(ccmd[23:22]), .cfg_fb(ccmd[21:20]),
        .busy(mm_busy), .done(mm_done), .feed(mm_feed),
        .a_addr(a16), .a_data(a_rd), .b_addr(b16), .b_data(b_rd),
        .sa_addr(sa16), .sa_data(sa_rd), .sb_addr(sb16), .sb_data(sb_rd),
        .c_we(mm_c_we), .c_addr(c16), .c_data(mm_c_data));
    assign mm_a_addr = a16[SAW-1:0];  assign mm_b_addr = b16[SAW-1:0];
    assign mm_sa_addr = sa16[SAW-1:0]; assign mm_sb_addr = sb16[SAW-1:0];
    assign mm_c_addr = c16[SAW-1:0];

    // ---- scheduler state ----------------------------------------------------
    reg [4:0] nld, ncomp, nst;               // commands loaded / computed / stored
    reg       computing;

    // ---- data mover ---------------------------------------------------------
    localparam D_IDLE = 0, D_LOAD = 1, D_ST_RD = 2, D_ST_WAIT = 3, D_ST_CAP = 4, D_ST_SEND = 5;
    reg [2:0]     dstate;
    reg [199:0]   dcmd;                      // command being moved
    reg           dhalf;
    reg [16:0]    iss, rcv, total;           // load: words requested / received / total
    reg [15:0]    na, nab, nabs;             // load: region boundaries
    reg [15:0]    cw;                        // store: C word index
    reg [1:0]     part;
    reg [W32-1:0] cbuf;

    wire can_load  = (nld < n_cmds) && (nld < ncomp + 2);
    wire can_store = (nst < ncomp);

    always @(posedge clk) begin
        ld_we_a <= 1'b0; ld_we_b <= 1'b0; ld_we_sa <= 1'b0; ld_we_sb <= 1'b0;
        mm_start <= 1'b0;
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0; dstate <= D_IDLE; mem_req <= 1'b0; mem_we <= 1'b0;
            nld <= 0; ncomp <= 0; nst <= 0; computing <= 1'b0; comp_half <= 1'b0;
            ticks_busy <= 0; ticks_engine <= 0;
        end else begin
            if (start && !busy) begin
                busy <= 1'b1; nld <= 0; ncomp <= 0; nst <= 0; computing <= 1'b0;
                ticks_busy <= 0; ticks_engine <= 0;
            end
            if (busy) begin
                ticks_busy <= ticks_busy + 1;
                if (mm_feed) ticks_engine <= ticks_engine + 1;     // engine fed a beat
            end

            // compute: next command when its inputs are in, the engine is free,
            // and its C half has been emptied
            if (busy && !computing && ncomp < nld && ncomp < nst + 2 && !mm_busy) begin
                ccmd      <= cmds[ncomp[3:0]];
                comp_half <= ncomp[0];
                mm_start  <= 1'b1;
                computing <= 1'b1;
            end
            if (computing && mm_done) begin
                computing <= 1'b0;
                ncomp     <= ncomp + 1;
            end

            // data mover
            case (dstate)
            D_IDLE: begin
                mem_req <= 1'b0; mem_we <= 1'b0;
                if (busy && can_load) begin
                    dcmd  <= cmds[nld[3:0]];
                    dhalf <= nld[0];
                    na    <= f_na(cmds[nld[3:0]]);
                    nab   <= f_na(cmds[nld[3:0]]) + f_nb(cmds[nld[3:0]]);
                    nabs  <= f_na(cmds[nld[3:0]]) + f_nb(cmds[nld[3:0]]) + f_nsa(cmds[nld[3:0]]);
                    total <= f_na(cmds[nld[3:0]]) + f_nb(cmds[nld[3:0]]) +
                             f_nsa(cmds[nld[3:0]]) + f_nsb(cmds[nld[3:0]]);
                    iss <= 0; rcv <= 0;
                    dstate <= D_LOAD;
                end else if (busy && can_store) begin
                    dcmd  <= cmds[nst[3:0]];
                    dhalf <= nst[0];
                    cw    <= 0;
                    dstate <= D_ST_RD;
                end else if (busy && nst == n_cmds) begin
                    busy <= 1'b0; done <= 1'b1;
                end
            end
            D_LOAD: begin
                // ask for the next word whenever main memory accepts one
                if (mem_req && mem_ready) iss <= iss + 1;
                mem_req  <= (iss + (mem_req && mem_ready) < total);
                mem_we   <= 1'b0;
                mem_addr <= f_in(dcmd) + iss + (mem_req && mem_ready);
                // put each answer into the right SRAM, in the free half
                if (mem_rvalid) begin
                    ld_wdata <= mem_rdata;
                    if (rcv < na) begin
                        ld_we_a <= 1'b1; ld_waddr <= {dhalf, rcv[SAW-1:0]};
                    end else if (rcv < nab) begin
                        ld_we_b <= 1'b1; ld_waddr <= {dhalf, rcv[SAW-1:0] - na[SAW-1:0]};
                    end else if (rcv < nabs) begin
                        ld_we_sa <= 1'b1; ld_waddr <= {dhalf, rcv[SAW-1:0] - nab[SAW-1:0]};
                    end else begin
                        ld_we_sb <= 1'b1; ld_waddr <= {dhalf, rcv[SAW-1:0] - nabs[SAW-1:0]};
                    end
                    rcv <= rcv + 1;
                    if (rcv + 1 == total) begin
                        nld <= nld + 1;
                        mem_req <= 1'b0;
                        dstate <= D_IDLE;
                    end
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
            default: dstate <= D_IDLE;
            endcase
        end
    end
endmodule
