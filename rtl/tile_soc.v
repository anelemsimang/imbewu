// tile_soc.v - the tile with its own control processor (Phase 2)
//
// Plain language: a small RISC-V processor (PicoRV32, open source) runs a
// driver program that works out the tile's command list from a short
// description of the work (layer sizes, number of batches), writes it into
// the tile, starts it and waits until it is done. On a full chip each tile
// would have one of these, so the host computer only hands out work.
//
// Processor memory map:
//   0x0000_0000 - 0x0000_3FFF  program and data RAM (16 KB)
//   0x1000_0000 - 0x1000_0018  CMD0..CMD6: one 200-bit command, lowest bits first
//   0x1000_0020                CMD_WRITE: write the command into slot (value)
//   0x1000_0024                N_CMDS
//   0x1000_0028                START (any write)
//   0x1000_002C                STATUS (read): bit 0 busy, bit 1 done since start
//   0x1000_0030 / 0x34         TICKS_BUSY / TICKS_ENGINE (read)
//   0x1000_0040                EXIT: the program writes its result code here
module tile_soc #(
    parameter N   = 4,
    parameter EAW = 20
) (
    input  wire              clk,
    input  wire              rst,
    // main memory (as tile_v3)
    output wire              mem_req,
    output wire              mem_we,
    output wire [EAW-1:0]    mem_addr,
    output wire [N*8-1:0]    mem_wdata,
    input  wire              mem_ready,
    input  wire              mem_rvalid,
    input  wire [N*8-1:0]    mem_rdata,
    // the program's result
    output reg               exit_valid,
    output reg  [31:0]       exit_code
);
    // ---- processor ---------------------------------------------------------
    wire        cpu_valid, cpu_instr;
    reg         cpu_ready;
    wire [31:0] cpu_addr, cpu_wdata;
    wire [3:0]  cpu_wstrb;
    reg  [31:0] cpu_rdata;
    picorv32 #(
        .ENABLE_FAST_MUL(1), .ENABLE_DIV(0), .ENABLE_IRQ(0), .COMPRESSED_ISA(0),
        .PROGADDR_RESET(32'h0), .STACKADDR(32'h4000)
    ) u_cpu (
        .clk(clk), .resetn(!rst), .mem_valid(cpu_valid), .mem_instr(cpu_instr),
        .mem_ready(cpu_ready), .mem_addr(cpu_addr), .mem_wdata(cpu_wdata),
        .mem_wstrb(cpu_wstrb), .mem_rdata(cpu_rdata)
    );

    // ---- RAM -----------------------------------------------------------------
    reg [31:0] ram [0:4095];
    wire is_ram  = (cpu_addr[31:14] == 18'd0);
    wire is_mmio = (cpu_addr[31:8] == 24'h100000);

    // ---- tile and its control registers ---------------------------------------
    reg  [31:0] cmdw [0:6];
    reg         t_cmd_we, t_start;
    reg  [3:0]  t_cmd_idx;
    reg  [4:0]  t_ncmds;
    reg         done_seen;
    wire        t_busy, t_done;
    wire [31:0] t_ticks_busy, t_ticks_engine;
    tile_v3 #(.N(N), .EAW(EAW)) u_tile (
        .clk(clk), .rst(rst), .cmd_we(t_cmd_we), .cmd_idx(t_cmd_idx),
        .cmd_data({cmdw[6][7:0], cmdw[5], cmdw[4], cmdw[3], cmdw[2], cmdw[1], cmdw[0]}),
        .n_cmds(t_ncmds), .start(t_start), .busy(t_busy), .done(t_done),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_ready(mem_ready), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .ticks_busy(t_ticks_busy), .ticks_engine(t_ticks_engine));

    // ---- bus: every access answered one tick later ------------------------------
    integer b;
    always @(posedge clk) begin
        cpu_ready  <= 1'b0;
        t_cmd_we   <= 1'b0;
        t_start    <= 1'b0;
        exit_valid <= 1'b0;
        if (t_done) done_seen <= 1'b1;
        if (rst) begin
            done_seen <= 1'b0; t_ncmds <= 0;
        end else if (cpu_valid && !cpu_ready) begin
            cpu_ready <= 1'b1;
            cpu_rdata <= 32'd0;
            if (is_ram) begin
                cpu_rdata <= ram[cpu_addr[13:2]];
                for (b = 0; b < 4; b = b + 1)
                    if (cpu_wstrb[b]) ram[cpu_addr[13:2]][b*8 +: 8] <= cpu_wdata[b*8 +: 8];
            end else if (is_mmio) begin
                if (|cpu_wstrb) begin
                    case (cpu_addr[7:0])
                        8'h00, 8'h04, 8'h08, 8'h0C, 8'h10, 8'h14, 8'h18:
                            cmdw[cpu_addr[4:2]] <= cpu_wdata;
                        8'h20: begin t_cmd_we <= 1'b1; t_cmd_idx <= cpu_wdata[3:0]; end
                        8'h24: t_ncmds <= cpu_wdata[4:0];
                        8'h28: begin t_start <= 1'b1; done_seen <= 1'b0; end
                        8'h40: begin exit_valid <= 1'b1; exit_code <= cpu_wdata; end
                        default: ;
                    endcase
                end else begin
                    case (cpu_addr[7:0])
                        8'h2C: cpu_rdata <= {30'd0, done_seen, t_busy};
                        8'h30: cpu_rdata <= t_ticks_busy;
                        8'h34: cpu_rdata <= t_ticks_engine;
                        default: cpu_rdata <= 32'd0;
                    endcase
                end
            end
        end
    end
endmodule
