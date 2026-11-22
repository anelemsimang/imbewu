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
module fp32_add_fx (
    input  wire [31:0]        acc,
    input  wire signed [47:0] x,
    input  wire signed [10:0] e,
    output reg  [31:0]        sum
);
    localparam signed [12:0] LOW = -13'sd2048;

    reg               s_a, s_x, s_r;
    reg        [23:0] m_a;
    reg        [47:0] m_x;
    reg signed [12:0] e_a, e_x, t_a, t_x, t_hi, base, B, lsb, s;
    reg        [82:0] al_a, al_x, R, n_wide;
    reg signed [84:0] S;
    reg        [24:0] n;
    reg               g, st;
    integer           L, k;
    reg signed [12:0] biased;

    // Line up magnitude m (with exponent ee) so that window bit k means
    // 2^(base - 1 + k); bit 0 is the sticky bit.
    function [82:0] align;
        input [47:0]        m;
        input signed [12:0] ee;
        input signed [12:0] bs;
        reg signed [12:0] sh;
        reg        [47:0] lost;
        integer           i;
        begin
            sh = ee - bs;
            if (m == 48'd0) align = 83'd0;
            else if (sh >= 0) align = {35'd0, m} << (sh + 1);
            else if (sh <= -48) align = 83'd1;
            else begin
                lost = 48'd0;
                for (i = 0; i < 48; i = i + 1)
                    if (i < -sh) lost[i] = m[i];
                align = ({35'd0, m >> (-sh)} << 1) | {82'd0, |lost};
            end
        end
    endfunction

    always @(*) begin
        // unpack the FP32 total
        s_a = acc[31];
        m_a = (acc[30:23] == 8'd0) ? {1'b0, acc[22:0]} : {1'b1, acc[22:0]};
        e_a = (acc[30:23] == 8'd0) ? -13'sd149 : $signed({5'd0, acc[30:23]}) - 13'sd150;
        // unpack the block total
        s_x = x[47];
        m_x = x[47] ? -x : x;
        e_x = {{2{e[10]}}, e};
        // top of each number (a zero number never decides the window)
        t_a = (m_a == 24'd0) ? LOW : e_a + 13'sd24;
        t_x = (m_x == 48'd0) ? LOW : e_x + 13'sd48;
        t_hi = (t_a > t_x) ? t_a : t_x;
        base = t_hi - 13'sd81;
        B    = base - 13'sd1;               // value = R * 2^B
        al_a = align(m_a, e_a, base);
        al_x = align(m_x, e_x, base);
        S    = (s_a ? -$signed({2'b00, al_a}) : $signed({2'b00, al_a})) +
               (s_x ? -$signed({2'b00, al_x}) : $signed({2'b00, al_x}));
        s_r  = S[84];
        R    = s_r ? -S[82:0] : S[82:0];

        // leading one
        L = -1;
        for (k = 0; k < 83; k = k + 1) if (R[k]) L = k;

        lsb = B + L - 13'sd23;
        if (lsb < -13'sd149) lsb = -13'sd149;
        s = lsb - B;
        g = 1'b0; st = 1'b0;
        if (s <= 0) n_wide = R << (-s);
        else if (s > 83) begin                  // far below the smallest FP32 step
            n_wide = 83'd0;
            st = (R != 83'd0);
        end else begin
            n_wide = R >> s;
            g = R[s - 1];
            for (k = 0; k < 83; k = k + 1) if (k < s - 1 && R[k]) st = 1'b1;
        end
        n = n_wide[24:0] + ((g && (st || n_wide[0])) ? 25'd1 : 25'd0);
        if (n[24]) begin n = n >> 1; lsb = lsb + 13'sd1; end
        biased = lsb + 13'sd150;

        if (acc[30:23] == 8'hFF)          sum = acc;                       // stays infinite
        else if (L < 0)                   sum = 32'd0;                     // exact zero: +0
        else if (!n[23])                  sum = {s_r, 8'd0, n[22:0]};      // subnormal (or 0)
        else if (biased >= 13'sd255)      sum = {s_r, 8'hFF, 23'd0};       // overflow
        else                              sum = {s_r, biased[7:0], n[22:0]};
    end
endmodule
