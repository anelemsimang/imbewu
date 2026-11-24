// cluster.v - several Imbewu tiles sharing one main memory (Phase 3, goals G2, G3)
//
// Plain language: a real chip has many tiles. They all fetch from the same
// main memory (HBM), which has a limited number of channels. This block
// holds T tiles (tile_v3.v) and a memory arbiter: every tick it lets up to
// B tiles that are asking use the memory (taking turns, so no tile waits
// forever), tags each request with the tile's number, and sends each answer
// back to the tile that asked for it.
//
// Main-memory side: up to B requests per tick, each with a tag (tile
// number); read answers come back with their tag, at most one per tile per
// tick, in the order each tile asked.
module cluster #(
    parameter N   = 4,
    parameter T   = 2,           // tiles
    parameter B   = 1,           // memory requests accepted per tick (channels)
    parameter EAW = 20
) (
    input  wire               clk,
    input  wire               rst,
    // command lists, one port per tile (tile t uses slice t)
    input  wire [T-1:0]       cmd_we,
    input  wire [4*T-1:0]     cmd_idx,
    input  wire [200*T-1:0]   cmd_data,
    input  wire [5*T-1:0]     n_cmds,
    input  wire               start,
    output wire               busy,
    output reg                done,
    // main memory: B request slots per tick
    output reg  [B-1:0]       m_req,
    output reg  [B-1:0]       m_we,
    output reg  [B*EAW-1:0]   m_addr,
    output reg  [B*N*8-1:0]   m_wdata,
    output reg  [B*8-1:0]     m_tag,
    // read answers: one valid bit and word per tile (the memory model has
    // already routed them by tag)
    input  wire [T-1:0]       m_rvalid,
    input  wire [T*N*8-1:0]   m_rdata,
    // measurement
    output wire [32*T-1:0]    ticks_engine,
    output reg  [31:0]        ticks
);
    localparam W8 = N * 8;
    localparam TW = (T > 1) ? $clog2(T) : 1;

    wire [T-1:0]     t_req, t_we, t_busy, t_done;
    wire [T*EAW-1:0] t_addr;
    wire [T*W8-1:0]  t_wdata;
    reg  [T-1:0]     t_ready;
    wire [T*32-1:0]  t_ticks_busy;

    genvar i;
    generate
        for (i = 0; i < T; i = i + 1) begin : tile
            tile_v3 #(.N(N), .EAW(EAW)) u (
                .clk(clk), .rst(rst),
                .cmd_we(cmd_we[i]), .cmd_idx(cmd_idx[4*i +: 4]), .cmd_data(cmd_data[200*i +: 200]),
                .n_cmds(n_cmds[5*i +: 5]), .start(start), .busy(t_busy[i]), .done(t_done[i]),
                .mem_req(t_req[i]), .mem_we(t_we[i]), .mem_addr(t_addr[EAW*i +: EAW]),
                .mem_wdata(t_wdata[W8*i +: W8]), .mem_ready(t_ready[i]),
                .mem_rvalid(m_rvalid[i]), .mem_rdata(m_rdata[W8*i +: W8]),
                .ticks_busy(t_ticks_busy[32*i +: 32]), .ticks_engine(ticks_engine[32*i +: 32]));
        end
    endgenerate

    // ---- arbiter: up to B grants per tick, round robin ------------------------
    // A tile's request is "accepted" in the tick its mem_ready is high; the
    // granted requests are passed to memory in the same tick.
    reg [TW-1:0] rr;                     // the tile that gets first choice
    integer k, j, g;
    reg [TW:0] idx;
    always @(*) begin
        t_ready = {T{1'b0}};
        m_req = {B{1'b0}}; m_we = {B{1'b0}}; m_addr = 0; m_wdata = 0; m_tag = 0;
        g = 0;
        for (k = 0; k < T; k = k + 1) begin
            idx = rr + k;
            if (idx >= T) idx = idx - T;
            if (t_req[idx] && g < B) begin
                t_ready[idx] = 1'b1;
                for (j = 0; j < B; j = j + 1)
                    if (j == g) begin
                        m_req[j] = 1'b1;
                        m_we[j] = t_we[idx];
                        m_addr[EAW*j +: EAW] = t_addr[EAW*idx +: EAW];
                        m_wdata[W8*j +: W8] = t_wdata[W8*idx +: W8];
                        m_tag[8*j +: 8] = idx;
                    end
                g = g + 1;
            end
        end
    end

    // ---- whole-cluster status ----------------------------------------------------
    reg [T-1:0] finished;
    reg         running;
    assign busy = running;
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            rr <= 0; finished <= 0; running <= 1'b0; ticks <= 0;
        end else begin
            rr <= (rr == T - 1) ? 0 : rr + 1'b1;
            if (start && !running) begin
                running <= 1'b1; finished <= 0; ticks <= 0;
            end else if (running) begin
                ticks <= ticks + 1;
                if ((finished | t_done) == {T{1'b1}}) begin
                    running <= 1'b0; done <= 1'b1;
                end
                finished <= finished | t_done;
            end
        end
    end
endmodule
