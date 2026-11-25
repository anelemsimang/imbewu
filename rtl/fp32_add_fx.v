// fp32_add_fx.v - add an exact block total into an FP32 running total
//
// sum = round( acc + x * 2^e )   rounded ONCE, to the nearest FP32 value,
//                                ties to even (IEEE 754 default rounding)
//   acc : FP32 running total (IEEE 754 single precision, subnormals supported)
//   x   : signed 48-bit exact block total from the multipliers
//   e   : its power-of-two exponent (from the two MX block scales)
//
// Plain language: inside one MX block the cell adds exactly (no rounding).
// At the end of each block, that exact total is scaled by the block's two
// shared scales and added into a normal 32-bit floating-point total. This
// is the only place rounding happens, and it happens once per block.
//
// Overflow gives +/-infinity, and an infinite total stays infinite. NaN
// cannot arise (inputs are finite; infinity minus infinity is impossible).
// An exact zero result is +0.
//
// Method: both numbers are placed into an 83-bit window lined up on the
// larger one; bits of the smaller one that fall below the window are kept
// as a single "sticky" bit, which is enough for correct rounding because
// they lie far below the rounding point.
// The adder is written as four steps (S1-S4) so a chip can give each step
// its own tick (systolic_v5.v); the one-tick adder simply joins them.

// ---- S1a: unpack both numbers, choose the window -------------------------
module fp32_s1a_unpack (
    input  wire [31:0]        acc,
    input  wire signed [47:0] x,
    input  wire signed [10:0] e,
    output reg                inf,      // acc is infinite: it stays as it is
    output reg                s_a,
    output reg                s_x,
    output reg  [23:0]        m_a,
    output reg  [47:0]        m_x,
    output reg  signed [12:0] sh_a,     // shift of each number into the window
    output reg  signed [12:0] sh_x,
    output reg  signed [12:0] B         // window bit k means 2^(B + k)
);
    reg signed [12:0] e_a, e_x, d;
    reg               az, xz, x_top;
    // lo[k] = 1 if any bit of x below bit k is 1, built as a tree (6 levels,
    // Kogge-Stone style). It gives both the magnitude (-x keeps x's bits up
    // to its lowest 1 and flips the rest: m_x[k] = x[k] ^ lo[k]) and the zero
    // check (x = 0 when no bit is 1). Written as "x[47] ? -x : x" and
    // "x == 0", synthesis built it as a chain of 48 one-after-another ORs,
    // the slowest step of the first layout (docs/RESULTS.md, 2026-11-25).
    reg        [47:0] lo, lo_n;
    integer           k, w;
    always @(*) begin
        lo = {x[46:0], 1'b0};
        for (w = 1; w < 48; w = w * 2) begin
            lo_n = lo;
            for (k = w; k < 48; k = k + 1) lo_n[k] = lo[k] | lo[k - w];
            lo = lo_n;
        end
    end
    always @(*) begin
        inf = (acc[30:23] == 8'hFF);
        s_a = acc[31];
        m_a = (acc[30:23] == 8'd0) ? {1'b0, acc[22:0]} : {1'b1, acc[22:0]};
        e_a = (acc[30:23] == 8'd0) ? -13'sd149 : $signed({5'd0, acc[30:23]}) - 13'sd150;
        s_x = x[47];
        m_x = x ^ ({48{x[47]}} & lo);    // = x[47] ? -x : x
        e_x = {{2{e[10]}}, e};
        // The window is lined up on whichever number reaches higher: x spans
        // 48 bits above 2^e_x, acc 24 bits above 2^e_a. A zero never decides.
        // (Written with one subtraction, d, so the exponent maths is short.)
        az = (acc[30:0] == 31'd0);
        xz = !(lo[47] | x[47]);         // = (x == 0)
        d  = e_x - e_a;
        x_top = az || (!xz && (d >= -13'sd24));
        sh_x = x_top ? 13'sd33 : d + 13'sd57;
        sh_a = x_top ? 13'sd33 - d : 13'sd57;
        B    = x_top ? e_x - 13'sd34 : e_a - 13'sd58;
    end
endmodule

// ---- S1b: line both numbers up in the window -----------------------------
module fp32_s1b_align (
    input  wire [23:0]        m_a,
    input  wire [47:0]        m_x,
    input  wire signed [12:0] sh_a,
    input  wire signed [12:0] sh_x,
    output wire [82:0]        al_a,
    output wire [82:0]        al_x
);
    // window bit 0 is the sticky bit: any bits shifted out below the window
    function [82:0] align;
        input [47:0]        m;
        input signed [12:0] sh;
        reg        [47:0] lost;
        begin
            if (m == 48'd0) align = 83'd0;
            else if (sh >= 0) align = {35'd0, m} << (sh + 1);
            else if (sh <= -48) align = 83'd1;
            else begin
                // bits shifted out: m AND a mask of the low (-sh) bits
                lost = m & ~({48{1'b1}} << (-sh));
                align = ({35'd0, m >> (-sh)} << 1) | {82'd0, |lost};
            end
        end
    endfunction
    assign al_a = align({24'd0, m_a}, sh_a);
    assign al_x = align(m_x, sh_x);
endmodule

// S1 = S1a then S1b (used by the one-tick adder)
module fp32_s1_align (
    input  wire [31:0]        acc,
    input  wire signed [47:0] x,
    input  wire signed [10:0] e,
    output wire               inf,
    output wire               s_a,
    output wire               s_x,
    output wire [82:0]        al_a,
    output wire [82:0]        al_x,
    output wire signed [12:0] B
);
    wire [23:0] m_a; wire [47:0] m_x; wire signed [12:0] sh_a, sh_x;
    fp32_s1a_unpack ua (.acc(acc), .x(x), .e(e), .inf(inf), .s_a(s_a), .s_x(s_x),
                        .m_a(m_a), .m_x(m_x), .sh_a(sh_a), .sh_x(sh_x), .B(B));
    fp32_s1b_align  ub (.m_a(m_a), .m_x(m_x), .sh_a(sh_a), .sh_x(sh_x), .al_a(al_a), .al_x(al_x));
endmodule

// ---- S2: add or subtract the lined-up magnitudes -------------------------
module fp32_s2_add (
    input  wire        s_a,
    input  wire        s_x,
    input  wire [82:0] al_a,
    input  wire [82:0] al_x,
    output reg         s_r,             // sign of the sum
    output reg  [82:0] R                // magnitude of the sum: value = R * 2^B
);
    always @(*) begin
        if (s_a == s_x) begin
            R = al_a + al_x;            // cannot overflow: both are below 2^82
            s_r = s_a;
        end else if (al_a >= al_x) begin
            R = al_a - al_x;            // larger minus smaller: no negation needed
            s_r = s_a;
        end else begin
            R = al_x - al_a;
            s_r = s_x;
        end
    end
endmodule

// ---- S3: find the leading one and how far to shift -----------------------
module fp32_s3_norm (
    input  wire [82:0]        R,
    input  wire signed [12:0] B,
    output reg  signed [7:0]  L,        // position of the highest 1 bit, -1 if none
    output reg  signed [12:0] lsb,      // exponent of the result's last bit
    output reg  signed [12:0] s         // right shift that puts it in place
);
    // Highest 1 bit: "smear" every 1 downwards, keep only the top one, then
    // read off its position with fixed OR trees (short, fast circuit)
    function signed [7:0] lead1;
        input [82:0] r;
        reg   [82:0] f, h;
        integer b, k;
        reg   [6:0] pos;
        begin
            f = r;
            f = f | (f >> 1);  f = f | (f >> 2);  f = f | (f >> 4);
            f = f | (f >> 8);  f = f | (f >> 16); f = f | (f >> 32); f = f | (f >> 64);
            h = f & ~(f >> 1);                     // only the highest 1 remains
            pos = 7'd0;
            for (b = 0; b < 7; b = b + 1)
                for (k = 0; k < 83; k = k + 1)
                    if ((k >> b) & 1) pos[b] = pos[b] | h[k];
            lead1 = (r == 83'd0) ? -8'sd1 : {1'b0, pos};
        end
    endfunction

    reg signed [12:0] lsb_n, s_n, s_min;
    reg               clamp;
    always @(*) begin
        L     = lead1(R);
        // normal case: the result's last bit is 23 below its leading one;
        // but never below 2^-149 (FP32 subnormals). Both options are worked
        // out side by side and one is picked, to keep the path short.
        lsb_n = B + L - 13'sd23;
        s_n   = L - 13'sd23;
        s_min = -13'sd149 - B;
        clamp = (s_n < s_min);
        lsb   = clamp ? -13'sd149 : lsb_n;
        s     = clamp ? s_min : s_n;
    end
endmodule

// ---- S4: shift, round to nearest even, pack -----------------------------
module fp32_s4_round (
    input  wire               inf,
    input  wire               inf_sign,
    input  wire               s_r,
    input  wire [82:0]        R,
    input  wire signed [7:0]  L,
    input  wire signed [12:0] lsb_in,
    input  wire signed [12:0] s,
    output reg  [31:0]        sum
);
    reg signed [12:0] lsb, biased;
    reg        [82:0] n_wide;
    reg        [24:0] n;
    reg               g, st;
    always @(*) begin
        lsb = lsb_in;
        g = 1'b0; st = 1'b0;
        if (s <= 0) n_wide = R << (-s);
        else if (s > 83) begin                  // far below the smallest FP32 step
            n_wide = 83'd0;
            st = (R != 83'd0);
        end else begin
            n_wide = R >> s;
            g = R[s - 1];
            st = |(R & ~({83{1'b1}} << (s - 1)));      // any bit below the guard bit
        end
        n = n_wide[24:0] + ((g && (st || n_wide[0])) ? 25'd1 : 25'd0);
        if (n[24]) begin n = n >> 1; lsb = lsb + 13'sd1; end
        biased = lsb + 13'sd150;

        if (inf)                          sum = {inf_sign, 8'hFF, 23'd0};  // stays infinite
        else if (L < 0)                   sum = 32'd0;                     // exact zero: +0
        else if (!n[23])                  sum = {s_r, 8'd0, n[22:0]};      // subnormal (or 0)
        else if (biased >= 13'sd255)      sum = {s_r, 8'hFF, 23'd0};       // overflow
        else                              sum = {s_r, biased[7:0], n[22:0]};
    end
endmodule

// ---- The whole adder in one tick: the four steps joined ------------------
module fp32_add_fx (
    input  wire [31:0]        acc,
    input  wire signed [47:0] x,
    input  wire signed [10:0] e,
    output wire [31:0]        sum
);
    wire               inf, s_a, s_x, s_r;
    wire        [82:0] al_a, al_x, R;
    wire signed [12:0] B, lsb, s;
    wire signed [7:0]  L;
    fp32_s1_align u1 (.acc(acc), .x(x), .e(e), .inf(inf), .s_a(s_a), .s_x(s_x),
                      .al_a(al_a), .al_x(al_x), .B(B));
    fp32_s2_add   u2 (.s_a(s_a), .s_x(s_x), .al_a(al_a), .al_x(al_x), .s_r(s_r), .R(R));
    fp32_s3_norm  u3 (.R(R), .B(B), .L(L), .lsb(lsb), .s(s));
    fp32_s4_round u4 (.inf(inf), .inf_sign(acc[31]), .s_r(s_r), .R(R), .L(L),
                      .lsb_in(lsb), .s(s), .sum(sum));
endmodule
