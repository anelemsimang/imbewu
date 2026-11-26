// hbm_dram_model.v - behavioural HBM pseudo-channel for simulation: stores
// the data, returns read data T_CL ticks after a read, and checks every
// timing rule the controller (rtl/hbm_ctrl.v) must keep. Not hardware: the
// HBM DRAM and its interface are licensed parts (D-029). `errors` counts
// rule breaks; the first few are printed. Memory starts as word i = i (in the user's addresses).
// Used by tests/tb_hbm.v and tests/tb_fabric.v.
module hbm_dram_model #(
    parameter DW = 64, CB = 5, BB = 4, RB = 6, AW = RB + BB + CB,
    parameter T_RCD = 17, T_RP = 17, T_RAS = 40, T_CL = 17, T_WL = 6, T_BL = 2,
              T_CCDS = 2, T_CCDL = 3, T_RRDS = 3, T_RRDL = 4, T_FAW = 20,
              T_RTP = 6, T_WR = 20, T_WTR = 10, T_RTW = 4, T_REFI = 4680, T_RFC = 420,
    parameter NAME = "HBM",
    parameter HASH = 1            // as hbm_ctrl: physical bank = bank ^ row low bits
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          d_act, d_pre, d_ref, d_rd, d_wr,
    input  wire [BB-1:0] d_rbank, d_cbank,
    input  wire [RB-1:0] d_row,
    input  wire [CB-1:0] d_col,
    input  wire [DW-1:0] d_wdata,
    output reg           d_rvalid,
    output reg  [DW-1:0] d_rdata
);
    localparam NEG = -100000;
    integer now, errors;
    reg [DW-1:0] mem [0:(1<<AW)-1];
    integer b_open [0:15], b_row [0:15], b_act [0:15], b_pre [0:15], b_rd [0:15], b_wre [0:15];
    integer g_act [0:3], g_col [0:3];
    integer act_any, col_any, ref_t, wr_end, rd_end, bus_free;
    integer acts [0:3];
    integer rd_due [0:63]; reg [DW-1:0] rd_val [0:63]; integer rd_w, rd_r;
    integer b, g, k;
    task bad; input [8*48-1:0] what; begin
        errors = errors + 1;
        if (errors < 8) $display("ERROR %0s tick %0d: %0s", NAME, now, what);
    end endtask

    always @(posedge clk) if (!rst) begin
        // row commands
        if (d_act) begin
            b = d_rbank; g = b / 4;
            if (b_open[b]) bad("ACT to an open bank");
            if (now - b_pre[b] < T_RP) bad("tRP");
            if (now - act_any < T_RRDS) bad("tRRD_S");
            if (now - g_act[g] < T_RRDL) bad("tRRD_L");
            if (now - acts[0] < T_FAW) bad("tFAW");
            if (now - ref_t < T_RFC) bad("tRFC (ACT)");
            b_open[b] = 1; b_row[b] = d_row; b_act[b] = now; act_any = now; g_act[g] = now;
            acts[0] = acts[1]; acts[1] = acts[2]; acts[2] = acts[3]; acts[3] = now;
        end
        if (d_pre) begin
            b = d_rbank;
            if (!b_open[b]) bad("PRE to a closed bank");
            if (now - b_act[b] < T_RAS) bad("tRAS");
            if (now - b_rd[b] < T_RTP) bad("tRTP");
            if (now - b_wre[b] < T_WR) bad("tWR");
            b_open[b] = 0; b_pre[b] = now;
        end
        if (d_ref) begin
            for (k = 0; k < 16; k = k + 1) begin
                if (b_open[k]) bad("REF with a bank open");
                if (now - b_pre[k] < T_RP) bad("tRP before REF");
            end
            if (now - ref_t < T_RFC) bad("tRFC (REF)");
            ref_t = now;
        end
        if (now - (ref_t < 0 ? 0 : ref_t) > T_REFI + 200) bad("refresh overdue");
        // column commands
        if (d_rd || d_wr) begin
            b = d_cbank; g = b / 4;
            if (!b_open[b]) bad("column command to a closed bank");
            if (now - b_act[b] < T_RCD) bad("tRCD");
            if (now - col_any < T_CCDS) bad("tCCD_S");
            if (now - g_col[g] < T_CCDL) bad("tCCD_L");
            if (now - ref_t < T_RFC) bad("tRFC (column)");
            col_any = now; g_col[g] = now;
            if (d_rd) begin
                if (now < wr_end + T_WTR) bad("tWTR");
                if (now + T_CL < bus_free) bad("data bus clash (read)");
                bus_free = now + T_CL + T_BL; rd_end = now + T_CL + T_BL; b_rd[b] = now;
                rd_due[rd_w % 64] = now + T_CL; rd_val[rd_w % 64] = mem[{b_row[b][RB-1:0], d_col[CB-1:2], d_cbank, d_col[1:0]}];
                rd_w = rd_w + 1;
            end else begin
                if (now + T_WL < bus_free) bad("data bus clash (write)");
                if (now + T_WL < rd_end + T_RTW) bad("read-to-write turnaround");
                bus_free = now + T_WL + T_BL; wr_end = now + T_WL + T_BL; b_wre[b] = wr_end;
                mem[{b_row[b][RB-1:0], d_col[CB-1:2], d_cbank, d_col[1:0]}] = d_wdata;
            end
        end
    end
    // read data back to the controller
    always @(negedge clk) begin
        d_rvalid = 0;
        if (rd_r < rd_w && rd_due[rd_r % 64] == now + 1) begin
            d_rvalid = 1; d_rdata = rd_val[rd_r % 64]; rd_r = rd_r + 1;
        end
    end
    integer i;
    always @(posedge clk) now <= rst ? 0 : now + 1;
    initial begin
        errors = 0; now = 0; act_any = NEG; col_any = NEG; ref_t = -T_RFC; wr_end = NEG; rd_end = NEG;
        bus_free = 0; rd_w = 0; rd_r = 0; d_rvalid = 0; d_rdata = 0;
        for (k = 0; k < 16; k = k + 1) begin
            b_open[k] = 0; b_act[k] = NEG; b_pre[k] = NEG; b_rd[k] = NEG; b_wre[k] = NEG;
        end
        for (k = 0; k < 4; k = k + 1) begin g_act[k] = NEG; g_col[k] = NEG; acts[k] = NEG; end
        // starting value = the word's address as the controller's user sees it
        for (i = 0; i < (1 << AW); i = i + 1)
            mem[i] = HASH ? (i ^ (((i >> (CB + BB)) % (1 << BB)) << 2)) : i;
    end
endmodule
