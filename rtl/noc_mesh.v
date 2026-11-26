// noc_mesh.v - X x Y grid of noc_router.v (Phase 3, D-028)
//
// Router (x, y) is wired to its four neighbours; the links on the edge of
// the grid are tied off (nothing arrives, no credits, so nothing is sent
// there; XY routing never routes off the grid for a destination inside it).
// Each router's local port is the tile side: loc_* flattened, node
// n = y * X + x. A tile gives a credit (loc_out_credit) each time it takes a
// flit, and must not send without credit for the router's local queue: it
// starts with D credits and gets one back on each loc_in_credit.
module noc_mesh #(
    parameter X  = 4,
    parameter Y  = 4,
    parameter XW = 5,
    parameter YW = 5,
    parameter PW = 64,
    parameter D  = 4
) (
    input  wire                 clk,
    input  wire                 rst,
    // tile -> network
    input  wire [X*Y-1:0]       loc_in_v,
    input  wire [X*Y*FW-1:0]    loc_in_flit,
    output wire [X*Y-1:0]       loc_in_credit,
    // network -> tile
    output wire [X*Y-1:0]       loc_out_v,
    output wire [X*Y*FW-1:0]    loc_out_flit,
    input  wire [X*Y-1:0]       loc_out_credit
);
    localparam FW = XW + YW + PW;
    localparam NN = X * Y;

    // per router, per port (0 L, 1 N, 2 E, 3 S, 4 W)
    wire [4:0]      r_in_v   [0:NN-1];
    wire [5*FW-1:0] r_in_f   [0:NN-1];
    wire [4:0]      r_in_c   [0:NN-1];
    wire [4:0]      r_out_v  [0:NN-1];
    wire [5*FW-1:0] r_out_f  [0:NN-1];
    wire [4:0]      r_out_c  [0:NN-1];

    genvar x, y;
    generate
        for (y = 0; y < Y; y = y + 1) begin : row
            for (x = 0; x < X; x = x + 1) begin : col
                localparam n  = y * X + x;
                localparam nn = (y > 0)     ? n - X : 0;   // north neighbour
                localparam ne = (x < X - 1) ? n + 1 : 0;   // east
                localparam ns = (y < Y - 1) ? n + X : 0;   // south
                localparam nw = (x > 0)     ? n - 1 : 0;   // west
                noc_router #(.XW(XW), .YW(YW), .PW(PW), .D(D)) u (
                    .clk(clk), .rst(rst), .my_x(x[XW-1:0]), .my_y(y[YW-1:0]),
                    .in_v(r_in_v[n]), .in_flit(r_in_f[n]), .in_credit(r_in_c[n]),
                    .out_v(r_out_v[n]), .out_flit(r_out_f[n]), .out_credit(r_out_c[n]));
                // local port
                assign r_in_v[n][0]          = loc_in_v[n];
                assign r_in_f[n][0 +: FW]    = loc_in_flit[n*FW +: FW];
                assign loc_in_credit[n]      = r_in_c[n][0];
                assign loc_out_v[n]          = r_out_v[n][0];
                assign loc_out_flit[n*FW +: FW] = r_out_f[n][0 +: FW];
                assign r_out_c[n][0]         = loc_out_credit[n];
                // north port <-> neighbour's south port
                if (y > 0) begin : ln
                    assign r_in_v[n][1] = r_out_v[nn][3];
                    assign r_in_f[n][1*FW +: FW] = r_out_f[nn][3*FW +: FW];
                    assign r_out_c[n][1] = r_in_c[nn][3];
                end else begin : tn
                    assign r_in_v[n][1] = 1'b0; assign r_in_f[n][1*FW +: FW] = {FW{1'b0}};
                    assign r_out_c[n][1] = 1'b0;
                end
                if (x < X - 1) begin : le
                    assign r_in_v[n][2] = r_out_v[ne][4];
                    assign r_in_f[n][2*FW +: FW] = r_out_f[ne][4*FW +: FW];
                    assign r_out_c[n][2] = r_in_c[ne][4];
                end else begin : te
                    assign r_in_v[n][2] = 1'b0; assign r_in_f[n][2*FW +: FW] = {FW{1'b0}};
                    assign r_out_c[n][2] = 1'b0;
                end
                if (y < Y - 1) begin : ls
                    assign r_in_v[n][3] = r_out_v[ns][1];
                    assign r_in_f[n][3*FW +: FW] = r_out_f[ns][1*FW +: FW];
                    assign r_out_c[n][3] = r_in_c[ns][1];
                end else begin : ts
                    assign r_in_v[n][3] = 1'b0; assign r_in_f[n][3*FW +: FW] = {FW{1'b0}};
                    assign r_out_c[n][3] = 1'b0;
                end
                if (x > 0) begin : lw
                    assign r_in_v[n][4] = r_out_v[nw][2];
                    assign r_in_f[n][4*FW +: FW] = r_out_f[nw][2*FW +: FW];
                    assign r_out_c[n][4] = r_in_c[nw][2];
                end else begin : tw
                    assign r_in_v[n][4] = 1'b0; assign r_in_f[n][4*FW +: FW] = {FW{1'b0}};
                    assign r_out_c[n][4] = 1'b0;
                end
            end
        end
    endgenerate
endmodule
