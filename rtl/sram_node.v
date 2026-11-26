// sram_node.v - a block of shared on-chip memory as a node of the network
// (D-030)
//
// Plain language: besides each tile's own memory, the chip has shared
// on-chip memory spread over the network (like the "L2" memory of a GPU),
// much closer and faster than HBM. This node holds one such block: 2^AW
// words, one read or write per tick, answer L ticks later. The memory
// array is a stand-in (behavioural): ASAP7 has no memory generator, so its
// size and speed come from published figures (docs/RESULTS.md, D-030).
// Flit formats as mc_node.v. An access is only started when the answer
// network has room for its answer (credits minus answers still on the way).
module sram_node #(
    parameter XW = 5, YW = 5, TW = 8, AW = 15, DW = 64, D = 4,
    parameter SAW = 12,           // words in this block: 2^SAW
    parameter L   = 2             // ticks from access to answer
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          in_v,
    input  wire [FW-1:0] in_flit,
    output reg           in_credit,
    output reg           out_v,
    output reg  [FW-1:0] out_flit,
    input  wire          out_credit,
    output reg  [31:0]   n_acc
);
    localparam PW = 1 + XW + YW + TW + AW + DW;
    localparam FW = XW + YW + PW;
    localparam HT = XW + YW + TW;

    reg [DW-1:0] mem [0:(1 << SAW) - 1];
    reg [FW-1:0] fq [0:D-1];
    reg [$clog2(D)-1:0] fq_r, fq_w;
    reg [$clog2(D):0]   fq_n;
    reg [$clog2(D):0]   oc;            // answer credits
    reg [$clog2(L+1):0] infl;          // answers on the way
    // answer pipeline (L stages)
    reg          pv [0:L-1];
    reg [FW-1:0] pf [0:L-1];

    wire [FW-1:0] h = fq[fq_r];
    wire go = (fq_n != 0) && (oc > infl);
    wire          h_we  = h[PW-1];
    wire [HT-1:0] h_tag = h[PW-2 -: HT];
    wire [SAW-1:0] h_adr = h[DW +: SAW];
    wire [DW-1:0] h_wd  = h[DW-1:0];
    integer k;
    initial for (k = 0; k < (1 << SAW); k = k + 1) mem[k] = k;   // as the DRAM model

    always @(posedge clk) begin
        if (in_v) fq[fq_w] <= in_flit;
        if (go && h_we) mem[h_adr] <= h_wd;
        pf[0] <= {h_tag[HT-1 -: XW + YW], h_we, h_tag, {AW{1'b0}}, h_we ? {DW{1'b0}} : mem[h_adr]};
        for (k = 1; k < L; k = k + 1) pf[k] <= pf[k-1];
        out_flit <= pf[L-1];
        if (rst) begin
            fq_r <= 0; fq_w <= 0; fq_n <= 0; oc <= D; infl <= 0; in_credit <= 1'b0;
            out_v <= 1'b0; n_acc <= 0;
            for (k = 0; k < L; k = k + 1) pv[k] <= 1'b0;
        end else begin
            if (in_v) fq_w <= fq_w + 1'b1;
            if (go)   fq_r <= fq_r + 1'b1;
            fq_n <= fq_n + in_v - go;
            in_credit <= go;
            pv[0] <= go;
            for (k = 1; k < L; k = k + 1) pv[k] <= pv[k-1];
            out_v <= pv[L-1];
            // an answer leaves the node when out_v is set: credit spent then
            infl <= infl + go - pv[L-1];
            oc <= oc - pv[L-1] + out_credit;
            n_acc <= n_acc + go;
        end
    end
endmodule
