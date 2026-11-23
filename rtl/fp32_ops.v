// fp32_ops.v - IEEE 754 single-precision add and multiply for the vector unit
//
// Both are built on fp32_add_fx (rtl/fp32_add_fx.v), the already verified
// "exact sum, rounded once" adder, so they round exactly as IEEE 754
// requires (to nearest, ties to even, with subnormals):
//   a + b  =  fp32_add_fx(acc = a, x = signed significand of b, e = exponent of b)
//   a * b  =  fp32_add_fx(acc = +0, x = exact 48-bit product, e = sum of exponents)
// Special cases handled here: infinities, zeros' signs, NaN results
// (inf - inf, 0 x inf give the standard quiet NaN 0x7FC00000). NaN inputs
// are not expected (results are then undefined but never hang).
module fp32_unpack (
    input  wire [31:0]        f,
    output wire               s,
    output wire [23:0]        m,       // value = m * 2^e
    output wire signed [10:0] e,
    output wire               inf,
    output wire               zero
);
    assign s    = f[31];
    assign inf  = (f[30:23] == 8'hFF);
    assign zero = (f[30:0] == 31'd0);
    assign m    = (f[30:23] == 8'd0) ? {1'b0, f[22:0]} : {1'b1, f[22:0]};
    assign e    = (f[30:23] == 8'd0) ? -11'sd149 : $signed({3'd0, f[30:23]}) - 11'sd150;
endmodule

module fp32_add (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] y
);
    wire sa, sb, ia, ib, za, zb;
    wire [23:0] ma, mb;
    wire signed [10:0] ea, eb;
    fp32_unpack ua (.f(a), .s(sa), .m(ma), .e(ea), .inf(ia), .zero(za));
    fp32_unpack ub (.f(b), .s(sb), .m(mb), .e(eb), .inf(ib), .zero(zb));
    wire signed [47:0] xb = sb ? -$signed({24'd0, mb}) : $signed({24'd0, mb});
    wire [31:0] sum;
    fp32_add_fx u (.acc(ia ? 32'd0 : a), .x(ib ? 48'sd0 : xb), .e(eb), .sum(sum));
    always @(*) begin
        if (ia && ib)      y = (sa != sb) ? 32'h7FC00000 : a;    // inf - inf = NaN
        else if (ia)       y = a;
        else if (ib)       y = b;
        else if (za && zb) y = {sa & sb, 31'd0};                 // -0 + -0 = -0
        else               y = sum;
    end
endmodule

module fp32_mul (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] y
);
    wire sa, sb, ia, ib, za, zb;
    wire [23:0] ma, mb;
    wire signed [10:0] ea, eb;
    fp32_unpack ua (.f(a), .s(sa), .m(ma), .e(ea), .inf(ia), .zero(za));
    fp32_unpack ub (.f(b), .s(sb), .m(mb), .e(eb), .inf(ib), .zero(zb));
    wire        s  = sa ^ sb;
    wire [47:0] pm = ma * mb;                          // exact, below 2^48
    // fp32_add_fx takes a signed 48-bit number, so a product of 48 bits is
    // halved first; the bit shifted out is kept as a sticky bit in bit 0.
    // That bit lies far below the rounding point (the product has more
    // than 24 significant bits whenever it is non-zero there), so rounding
    // is unchanged.
    wire        big = pm[47];
    wire [46:0] mag = big ? {pm[47:2], pm[1] | pm[0]} : pm[46:0];
    wire signed [10:0] ep = ea + eb + (big ? 11'sd1 : 11'sd0);
    wire signed [47:0] xp = s ? -$signed({1'b0, mag}) : $signed({1'b0, mag});
    wire [31:0] prod;
    fp32_add_fx u (.acc(32'd0), .x(xp), .e(ep), .sum(prod));
    always @(*) begin
        if ((ia && zb) || (ib && za)) y = 32'h7FC00000;           // 0 x inf = NaN
        else if (ia || ib)            y = {s, 8'hFF, 23'd0};
        else if (za || zb)            y = {s, 31'd0};             // signed zero
        else if (prod[30:0] == 31'd0) y = {s, 31'd0};             // rounded to zero
        else                          y = prod;
    end
endmodule
