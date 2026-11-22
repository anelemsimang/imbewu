// w2_kogge_stone.v - map Yosys carry chains ($lcu) to a Kogge-Stone parallel
// prefix adder (a textbook design, 1973), as real chip flows do, instead of
// the default ripple-carry chain. Only used for the W2 timing estimate.
(* techmap_celltype = "$lcu" *)
module _80_lcu_kogge_stone (P, G, CI, CO);
    parameter WIDTH = 2;
    (* force_downto *) input  [WIDTH-1:0] P, G;
    input CI;
    (* force_downto *) output [WIDTH-1:0] CO;
    integer i, j;
    (* force_downto *) reg [WIDTH-1:0] p, g;
    always @* begin
        p = P;
        g = G;
        g[0] = g[0] | (p[0] & CI);
        for (i = 0; i < $clog2(WIDTH); i = i + 1)
            for (j = WIDTH - 1; j >= 2**i; j = j - 1) begin
                g[j] = g[j] | (p[j] & g[j - 2**i]);
                p[j] = p[j] & p[j - 2**i];
            end
    end
    assign CO = g;
endmodule
