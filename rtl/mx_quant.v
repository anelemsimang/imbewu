// mx_quant.v - FP32 numbers -> OCP MX blocks (the vector unit's results
// turned back into the engine's input formats; goals G1, G4)
//
// Plain language: the engine multiplies 8-bit (or 4-bit) numbers that share
// one power-of-two scale per block of 32. After the vector unit has worked
// in FP32 (softmax, SiLU, ...), its results must be rounded back into that
// form before the next matrix multiply. For each block of 32 numbers this
// unit (1) finds the largest one and picks the block's scale from it, then
// (2) rounds every number, divided by that scale, to the nearest value the
// format can hold (ties to even), capping at the format's largest value.
// The rule is the one the compiler and the numerics model use
// (tools/real_model_on_chip.py, block_codes):
//   e = floor(log2(max |x|, at least 2^-127)) - EMAX   (EMAX: INT8 0, FP8 8, FP4 2)
//   e clamped to -127..127; scale byte = e + 127
//   FP8 (E4M3): round(x / 2^e), largest 448     FP4 (E2M1): largest 6
//   INT8: round(64 x / 2^e), clamped to -128..127
// Infinities and NaNs are not expected as inputs.
//
// Stream: N numbers per tick (in_valid), a block every 32/N ticks. While
// one block's codes are sent out (N per tick, same order, with the scale
// beside the block's last word) the next block is collected, so one word
// in and one word out per tick. Output lag: 32/N + 1 ticks.
// fmt: 0 INT8, 1 FP8, 2 FP4 (FP4 codes in the low 4 bits of each byte).
module mx_quant #(
    parameter N = 4                 // lanes; 32 / N words per block
) (
    input  wire            clk,
    input  wire            rst,
    input  wire [1:0]      fmt,     // keep steady for a whole block
    input  wire            in_valid,
    input  wire [N*32-1:0] in_data,
    output reg             out_valid,
    output reg  [N*8-1:0]  out_codes,
    output reg             out_last,     // last word of a block: out_scale is valid
    output reg  [7:0]      out_scale
);
    localparam WPB = 32 / N;                  // words per block
    localparam CW  = (WPB > 1) ? $clog2(WPB) : 1;

    // ---- the exponent of a number: floor(log2 |x|), or "none" for zero ------
    function signed [9:0] ilog2;
        input [31:0] x;
        integer b;
        begin
            ilog2 = -10'sd300;                     // zero: below everything
            if (x[30:23] != 0) ilog2 = $signed({2'b00, x[30:23]}) - 10'sd127;
            else for (b = 0; b < 23; b = b + 1) if (x[b]) ilog2 = b - 149;
        end
    endfunction

    // ---- one number -> one code, given the block exponent e ----------------
    function [7:0] encode;
        input [31:0]       x;
        input signed [9:0] e;
        input [1:0]        f;
        reg [23:0]        M;
        reg signed [10:0] P, q, s, sh;
        reg [24:0]        R0, R;
        reg               g, st, neg;
        reg [3:0]         mb, bias;
        reg signed [10:0] emin;
        reg [4:0]         ef;
        reg [3:0]         mant;
        reg signed [9:0]  sv;
        integer b;
        begin
            neg = x[31];
            M   = (x[30:23] == 0) ? {1'b0, x[22:0]} : {1'b1, x[22:0]};
            P   = ((x[30:23] == 0) ? -11'sd149 : $signed({3'b000, x[30:23]}) - 11'sd150) - e;  // value = M * 2^P
            q   = ilog2(x) - e;                    // exponent of the scaled value
            if (f == 2'd0) begin                   // INT8: steps of 2^-6
                s = -11'sd6;
            end else begin
                mb   = (f == 2'd1) ? 4'd3 : 4'd1;  // mantissa bits
                bias = (f == 2'd1) ? 4'd7 : 4'd1;
                emin = (f == 2'd1) ? -11'sd6 : 11'sd0;
                s = (q > emin) ? q - mb : emin - mb;   // step size 2^s
            end
            // R = M * 2^(P - s), rounded to nearest, ties to even
            sh = s - P;
            if (M == 0) begin
                R = 0;
            end else if (sh <= 0) begin
                R = M << (-sh);                    // exact (only tiny inputs)
            end else if (sh > 24) begin             // below half a step: rounds to 0
                R = 0;
            end else begin
                R0 = M >> sh;
                g  = M[sh - 1];
                st = 1'b0;
                for (b = 0; b < 24; b = b + 1) if (b < sh - 1 && M[b]) st = 1'b1;
                R = R0 + (g && (st || R0[0]));
            end
            if (f == 2'd0) begin                   // INT8: clamp, two's complement
                if (!neg) sv = (R > 127) ? 10'sd127 : R[9:0];
                else      sv = (R > 128) ? -10'sd128 : -$signed({1'b0, R[8:0]});
                encode = sv[7:0];
            end else begin
                // carry into the next exponent
                if (R == (25'd2 << mb)) begin R = 25'd1 << mb; s = s + 1; end
                if (R >= (25'd1 << mb)) begin      // normal
                    ef   = s + mb + bias;
                    mant = R - (25'd1 << mb);
                end else begin                     // subnormal (or zero)
                    ef   = 0;
                    mant = R[3:0];
                end
                if (f == 2'd1) begin               // E4M3: largest 448 = exponent 15, mantissa 6
                    if (ef > 15 || (ef == 15 && mant > 6)) begin ef = 15; mant = 6; end
                    encode = {neg, ef[3:0], mant[2:0]};
                end else begin                     // E2M1: largest 6 = exponent 3, mantissa 1
                    if (ef > 3 || (ef == 3 && mant > 1)) begin ef = 3; mant = 1; end
                    encode = {4'b0000, neg, ef[1:0], mant[0]};
                end
            end
        end
    endfunction

    // ---- collect: two block buffers, the running largest exponent ----------
    reg [N*32-1:0]   buf0 [0:WPB-1];
    reg [N*32-1:0]   buf1 [0:WPB-1];
    reg              wsel;                     // buffer being filled
    reg [CW-1:0]     wcnt;
    reg signed [9:0] lmax;                     // largest exponent so far in this block
    reg signed [9:0] eblk [0:1];               // finished blocks' exponents
    reg [1:0]        full;                     // finished blocks waiting to be sent
    reg [1:0]        fmt_b [0:1];

    // largest exponent among this word's lanes
    reg signed [9:0] lw, lt;
    integer l;
    always @(*) begin
        lw = -10'sd300;
        for (l = 0; l < N; l = l + 1) begin
            lt = ilog2(in_data[32*l +: 32]);
            if (lt > lw) lw = lt;
        end
    end
    wire signed [9:0] lnew = (wcnt == 0) ? lw : ((lw > lmax) ? lw : lmax);
    function [3:0] emax_of; input [1:0] f; emax_of = (f == 2'd1) ? 4'd8 : (f == 2'd2) ? 4'd2 : 4'd0; endfunction
    // e = max(L, -127) - EMAX, then at least -127
    function signed [9:0] block_e; input signed [9:0] L; input [1:0] f; reg signed [9:0] t; begin
        t = ((L < -10'sd127) ? -10'sd127 : L) - $signed({6'b0, emax_of(f)});
        block_e = (t < -10'sd127) ? -10'sd127 : t;
    end endfunction

    // ---- send: one word of codes per tick from the oldest finished block ----
    reg              rsel;                     // buffer being sent
    reg [CW-1:0]     rcnt;
    wire [N*32-1:0]  rword = rsel ? buf1[rcnt] : buf0[rcnt];
    reg  [N*8-1:0]   codes;
    always @(*)
        for (l = 0; l < N; l = l + 1)
            codes[8*l +: 8] = encode(rword[32*l +: 32], eblk[rsel], fmt_b[rsel]);

    always @(posedge clk) begin
        out_valid <= 1'b0; out_last <= 1'b0;
        if (rst) begin
            wsel <= 0; wcnt <= 0; rsel <= 0; rcnt <= 0; full <= 0; lmax <= -10'sd300;
        end else begin
            // collect
            if (in_valid) begin
                if (wsel) buf1[wcnt] <= in_data; else buf0[wcnt] <= in_data;
                if (wcnt == WPB - 1) begin
                    wcnt <= 0;
                    eblk[wsel]  <= block_e(lnew, fmt);
                    fmt_b[wsel] <= fmt;
                    wsel <= ~wsel;
                end else begin
                    wcnt <= wcnt + 1;
                    lmax <= lnew;
                end
            end
            // send (a block becomes sendable the tick after its last word)
            if (full[rsel]) begin
                out_valid <= 1'b1;
                out_codes <= codes;
                if (rcnt == WPB - 1) begin
                    out_last  <= 1'b1;
                    out_scale <= eblk[rsel] + 8'd127;
                    rcnt <= 0;
                    rsel <= ~rsel;
                end else rcnt <= rcnt + 1;
            end
            // which buffers hold a finished block
            full <= (full | ((in_valid && wcnt == WPB - 1) ? (2'b01 << wsel) : 2'b00))
                         & ~((full[rsel] && rcnt == WPB - 1) ? (2'b01 << rsel) : 2'b00);
        end
    end
endmodule
