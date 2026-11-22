// sram.v - behavioural model of an on-chip SRAM block: one read port and one
// write port, each one word per tick; read data appears one tick after the
// address. On a real chip this is a memory macro from the foundry.
module sram_1r1w #(
    parameter W  = 32,      // word width (bits)
    parameter AW = 10       // address width: 2^AW words
) (
    input  wire          clk,
    input  wire [AW-1:0] raddr,
    output reg  [W-1:0]  rdata,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [W-1:0]  wdata
);
    reg [W-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        rdata <= mem[raddr];
        if (we) mem[waddr] <= wdata;
    end
endmodule
