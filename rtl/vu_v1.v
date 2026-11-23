// vu_v1.v - the Imbewu vector unit, version 1 (Phase 2; goal G4)
//
// Plain language: besides matrix multiplies, a language model needs smaller
// steps on whole rows of numbers: softmax (in attention), normalisation
// between layers, and activation functions such as SiLU. This unit does
// them in FP32, one lane per engine column, so it can work directly on the
// engine's output rows. It runs a short program of simple vector
// instructions; exp, reciprocal and square root are built from them in
// software (fw/ is not needed: programs come from tools/vu_asm.py).
//
// Memories (written from outside before start):
//   imem: 1,024 instructions    cmem: 64 FP32 constants
//   vmem: 256 vectors of L FP32 lanes (data in and results out)
// Registers: v0..v7, each L lanes.
//
// Instruction (32 bits): op[31:26] vd[25:23] va[22:20] vb[19:17] imm[16:0]
//   0 HALT                     8 RSUM  vd = sum of va's lanes, in every lane
//   1 LD    vd = vmem[imm]     9 RMAX  vd = max of va's lanes, in every lane
//   2 ST    vmem[imm] = va    10 CONST vd = cmem[imm] in every lane
//   3 ADD   vd = va + vb      11 FLOOR vd = floor(va)
//   4 SUB   vd = va - vb      12 POW2I vd = 2^va (va a whole number; -126..127)
//   5 MUL   vd = va * vb      13 RCPS  vd = first guess of 1/va (va > 0)
//   6 MAX   vd = max(va, vb)  14 RSQS  vd = first guess of 1/sqrt(va) (va > 0)
//   7 MIN   vd = min(va, vb)
// Every instruction takes one tick. Lane sums use a fixed pairwise tree
// (lanes 0+1, 2+3, ... then pairs of those), so results are repeatable.
module vu_v1 #(
    parameter L = 4                 // lanes (a power of two)
) (
    input  wire          clk,
    input  wire          rst,
    // loading programs, constants and data
    input  wire          imem_we,
    input  wire [9:0]    imem_addr,
    input  wire [31:0]   imem_data,
    input  wire          cmem_we,
    input  wire [5:0]    cmem_addr,
    input  wire [31:0]   cmem_data,
    input  wire          vmem_we,
    input  wire [7:0]    vmem_addr,
    input  wire [L*32-1:0] vmem_wdata,
    output wire [L*32-1:0] vmem_rdata,
    input  wire          start,
    output reg           busy,
    output reg  [15:0]   ticks
);
    reg [31:0]     imem [0:1023];
    reg [31:0]     cmem [0:63];
    reg [L*32-1:0] vmem [0:255];
    reg [L*32-1:0] vr   [0:7];
    reg [9:0]      pc;

    wire [31:0] ins = imem[pc];
    wire [5:0]  op  = ins[31:26];
    wire [2:0]  vd  = ins[25:23], va = ins[22:20], vb = ins[19:17];
    wire [16:0] imm = ins[16:0];
    wire [L*32-1:0] A = vr[va], B = vr[vb];

    assign vmem_rdata = vmem[vmem_addr];

    // ---- per-lane arithmetic ------------------------------------------------
    wire [L*32-1:0] r_add, r_sub, r_mul, r_max, r_min, r_floor, r_pow2, r_rcp, r_rsq;
    genvar l;
    generate
        for (l = 0; l < L; l = l + 1) begin : lane
            wire [31:0] a = A[l*32 +: 32], b = B[l*32 +: 32];
            fp32_add u_add (.a(a), .b(b), .y(r_add[l*32 +: 32]));
            fp32_add u_sub (.a(a), .b({~b[31], b[30:0]}), .y(r_sub[l*32 +: 32]));
            fp32_mul u_mul (.a(a), .b(b), .y(r_mul[l*32 +: 32]));
            // max / min of two FP32 numbers (no NaNs expected)
            wire a_lt_b = (a[31] != b[31]) ? (a[31] && !(a[30:0] == 0 && b[30:0] == 0))
                                           : (a[31] ? (a[30:0] > b[30:0]) : (a[30:0] < b[30:0]));
            assign r_max[l*32 +: 32] = a_lt_b ? b : a;
            assign r_min[l*32 +: 32] = a_lt_b ? a : b;
            // floor: drop the fraction bits (towards zero), then subtract 1
            // if the number was negative and had a fraction
            wire [7:0]  ex = a[30:23];
            wire [31:0] fmask = (ex >= 8'd150) ? 32'hFFFFFFFF :
                                (ex < 8'd127)  ? 32'h80000000 :
                                ~((32'h007FFFFF) >> (ex - 8'd127));
            wire [31:0] tr = a & fmask;                       // truncated
            wire        frac = (tr != a);
            wire [31:0] tr_m1;
            fp32_add u_fl (.a(tr), .b(32'hBF800000), .y(tr_m1));   // tr - 1
            assign r_floor[l*32 +: 32] = (a[31] && frac) ? tr_m1 : tr;
            // 2^n for a whole number n held as FP32, clamped to -126..127
            wire [23:0] mm = {1'b1, a[22:0]};
            wire [7:0]  k  = (ex < 8'd127) ? 8'd0 :
                             (ex > 8'd133) ? 8'd200 : mm[23:16] >> (8'd134 - ex);
            wire signed [9:0] n = a[31] ? -$signed({2'b0, k}) : $signed({2'b0, k});
            wire signed [9:0] nc = (n > 10'sd127) ? 10'sd127 : (n < -10'sd126) ? -10'sd126 : n;
            wire [9:0] be = nc + 10'sd127;
            assign r_pow2[l*32 +: 32] = {1'b0, be[7:0], 23'd0};
            // first guesses for 1/x and 1/sqrt(x) (well-known integer tricks)
            assign r_rcp[l*32 +: 32] = 32'h7EF311C3 - {1'b0, a[30:0]};
            assign r_rsq[l*32 +: 32] = 32'h5F3759DF - {2'b0, a[30:1]};
        end
    endgenerate

    // ---- lane sums and maxima: fixed pairwise trees ---------------------------
    localparam LV = $clog2(L);
    wire [31:0] st [0:LV][0:L-1];
    wire [31:0] mt [0:LV][0:L-1];
    genvar t, q;
    generate
        for (q = 0; q < L; q = q + 1) begin : leaf
            assign st[0][q] = A[q*32 +: 32];
            assign mt[0][q] = A[q*32 +: 32];
        end
        for (t = 1; t <= LV; t = t + 1) begin : lev
            for (q = 0; q < (L >> t); q = q + 1) begin : node
                fp32_add u_s (.a(st[t-1][2*q]), .b(st[t-1][2*q+1]), .y(st[t][q]));
                wire [31:0] x = mt[t-1][2*q], y = mt[t-1][2*q+1];
                wire x_lt_y = (x[31] != y[31]) ? (x[31] && !(x[30:0] == 0 && y[30:0] == 0))
                                               : (x[31] ? (x[30:0] > y[30:0]) : (x[30:0] < y[30:0]));
                assign mt[t][q] = x_lt_y ? y : x;
            end
        end
    endgenerate

    // ---- the sequencer ------------------------------------------------------------
    integer z;
    always @(posedge clk) begin
        if (imem_we) imem[imem_addr] <= imem_data;
        if (cmem_we) cmem[cmem_addr] <= cmem_data;
        if (vmem_we && !busy) vmem[vmem_addr] <= vmem_wdata;
        if (rst) begin
            busy <= 1'b0; pc <= 10'd0; ticks <= 16'd0;
        end else if (start && !busy) begin
            busy <= 1'b1; pc <= 10'd0; ticks <= 16'd0;
        end else if (busy) begin
            ticks <= ticks + 1'b1;
            pc <= pc + 1'b1;
            case (op)
                6'd0: busy <= 1'b0;                              // HALT
                6'd1: vr[vd] <= vmem[imm[7:0]];
                6'd2: vmem[imm[7:0]] <= A;
                6'd3: vr[vd] <= r_add;
                6'd4: vr[vd] <= r_sub;
                6'd5: vr[vd] <= r_mul;
                6'd6: vr[vd] <= r_max;
                6'd7: vr[vd] <= r_min;
                6'd8: vr[vd] <= {L{st[LV][0]}};
                6'd9: vr[vd] <= {L{mt[LV][0]}};
                6'd10: vr[vd] <= {L{cmem[imm[5:0]]}};
                6'd11: vr[vd] <= r_floor;
                6'd12: vr[vd] <= r_pow2;
                6'd13: vr[vd] <= r_rcp;
                6'd14: vr[vd] <= r_rsq;
                default: ;
            endcase
        end
    end
endmodule
