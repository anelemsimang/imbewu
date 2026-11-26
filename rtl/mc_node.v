// mc_node.v - an HBM memory controller as a node of the network (D-029, D-030)
//
// Plain language: requests arrive from the request network (noc_mesh.v)
// and go into this node's HBM controller (hbm_ctrl.v); its answers go back
// to the requesting tile over the answer network, a second mesh, so that
// answers can never be stuck behind requests.
//
// Request flit:  {dst_x, dst_y, we, src_x, src_y, tag, addr, wdata}
// Answer flit:   {dst_x = src_x, dst_y = src_y, we, src_x, src_y, tag, 0, rdata}
// (addr is this channel's own word address; the tile picks the channel.)
// The node keeps a small queue in front of the controller so the router's
// D credits are given back at once and the controller's own queue (Q
// requests, where it picks row hits) can fill up.
module mc_node #(
    parameter XW = 5, YW = 5, TW = 8, AW = 15, DW = 64, D = 4,
    parameter CB = 5, BB = 4, RB = 6, Q = 16
) (
    input  wire          clk,
    input  wire          rst,
    // from the request network (router's local output)
    input  wire          in_v,
    input  wire [FW-1:0] in_flit,
    output reg           in_credit,
    // to the answer network (router's local input)
    output wire          out_v,
    output wire [FW-1:0] out_flit,
    input  wire          out_credit,
    // DRAM side (to the HBM interface; tests/hbm_dram_model.v in simulation)
    output wire          d_act, d_pre, d_ref, d_rd, d_wr,
    output wire [BB-1:0] d_rbank, d_cbank,
    output wire [RB-1:0] d_row,
    output wire [CB-1:0] d_col,
    output wire [DW-1:0] d_wdata,
    input  wire          d_rvalid,
    input  wire [DW-1:0] d_rdata,
    output wire [31:0]   n_col, n_act, n_ref
);
    localparam PW = 1 + XW + YW + TW + AW + DW;
    localparam FW = XW + YW + PW;
    localparam HT = XW + YW + TW;           // controller tag: {src_x, src_y, tag}

    // queue in front of the controller
    reg [FW-1:0] fq [0:D-1];
    reg [$clog2(D)-1:0] fq_r, fq_w;
    reg [$clog2(D):0]   fq_n;
    reg [$clog2(Q):0]   hc;                 // credits for the controller's queue
    wire hc_ret;
    wire [FW-1:0] h = fq[fq_r];
    wire go = (fq_n != 0) && (hc != 0);
    // flit fields
    wire          h_we  = h[PW-1];
    wire [HT-1:0] h_tag = h[PW-2 -: HT];
    wire [AW-1:0] h_adr = h[DW +: AW];
    wire [DW-1:0] h_wd  = h[DW-1:0];

    always @(posedge clk) begin
        if (in_v) fq[fq_w] <= in_flit;
        if (rst) begin
            fq_r <= 0; fq_w <= 0; fq_n <= 0; hc <= Q; in_credit <= 1'b0;
        end else begin
            if (in_v) fq_w <= fq_w + 1'b1;
            if (go)   fq_r <= fq_r + 1'b1;
            fq_n <= fq_n + in_v - go;
            hc <= hc - go + hc_ret;
            in_credit <= go;
        end
    end

    wire          rs_v, rs_we;
    wire [HT-1:0] rs_tag;
    wire [DW-1:0] rs_rdata;
    hbm_ctrl #(.DW(DW), .TW(HT), .CB(CB), .BB(BB), .RB(RB), .Q(Q)) u_hc (
        .clk(clk), .rst(rst),
        .rq_v(go), .rq_we(h_we), .rq_addr(h_adr), .rq_tag(h_tag), .rq_wdata(h_wd), .rq_credit(hc_ret),
        .rs_v(rs_v), .rs_we(rs_we), .rs_tag(rs_tag), .rs_rdata(rs_rdata), .rs_credit(out_credit),
        .d_act(d_act), .d_pre(d_pre), .d_ref(d_ref), .d_rbank(d_rbank), .d_row(d_row),
        .d_rd(d_rd), .d_wr(d_wr), .d_cbank(d_cbank), .d_col(d_col), .d_wdata(d_wdata),
        .d_rvalid(d_rvalid), .d_rdata(d_rdata), .n_hit(n_col), .n_act(n_act), .n_ref(n_ref));

    // answer flit, addressed to the requesting tile
    assign out_v    = rs_v;
    assign out_flit = {rs_tag[HT-1 -: XW + YW], rs_we, rs_tag, {AW{1'b0}}, rs_rdata};
endmodule
