// Dual-Wishbone bridge wrapper for VexRiscv
// - Separate Wishbone masters: instruction (read-only) and data (read/write)
// - Instruction side: registered single-beat cycles (unchanged from before)
// - Data side: command accepted immediately and latched (cmd.ready = !busy);
//   rsp.ready pulses in the cycle the slave acks a read, so the core's
//   writeback stage waits for real read data.
// - Debug (JTAG) and interrupts go straight to the core

`default_nettype none

module simple_to_wishbone #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
)(
    input  wire                       clk,
    input  wire                       rst,

    // ---- JTAG outward ----
    input  wire                       jtag_tms,
    input  wire                       jtag_tdi,
    output wire                       jtag_tdo,
    input  wire                       jtag_tck,
    input  wire                       debug_reset,

    input  wire                       timerInterrupt,
    input  wire                       softwareInterrupt,
    input  wire                       externalInterrupt,

    // ---- ndmreset outward (OR this with your system reset at top level) ----
    output wire                       ndmreset,

    // Wishbone MASTER: INSTRUCTION (read-only)
    output reg                        iw_cyc_o,
    output reg                        iw_stb_o,
    output wire                       iw_we_o,     // always 0 for iBus
    output reg  [ADDR_WIDTH-1:0]      iw_adr_o,
    output wire [DATA_WIDTH-1:0]      iw_dat_o,    // unused on read-only bus
    output wire [(DATA_WIDTH/8)-1:0]  iw_sel_o,    // usually all 1s
    input  wire [DATA_WIDTH-1:0]      iw_dat_i,
    input  wire                       iw_ack_i,

    // Wishbone MASTER: DATA (read/write)
    output reg                        dw_cyc_o,
    output reg                        dw_stb_o,
    output reg                        dw_we_o,
    output reg  [ADDR_WIDTH-1:0]      dw_adr_o,
    output reg  [DATA_WIDTH-1:0]      dw_dat_o,
    output reg  [(DATA_WIDTH/8)-1:0]  dw_sel_o,
    input  wire [DATA_WIDTH-1:0]      dw_dat_i,
    input  wire                       dw_ack_i
);


    // =========================
    // JTAG Routing
    // =========================
    wire core_jtag_tck;
    wire core_jtag_tms;
    wire core_jtag_tdi;
    wire core_jtag_tdo;

    assign core_jtag_tck = jtag_tck;
    assign core_jtag_tms = jtag_tms;
    assign core_jtag_tdi = jtag_tdi;
    assign jtag_tdo      = core_jtag_tdo;
    // =========================
    // VexRiscv CPU instance
    // =========================

    // iBus <-> instruction WB: handshake & data regs
    wire         iBus_cmd_valid;
    reg          iBus_cmd_ready;
    wire [31:0]  iBus_cmd_payload_pc;

    reg          iBus_rsp_valid;
    wire         iBus_rsp_payload_error = 1'b0;
    reg  [31:0]  iBus_rsp_payload_inst;

    // dBus <-> data WB
    wire         dBus_cmd_valid;
    wire         dBus_cmd_ready;
    wire         dBus_cmd_payload_wr;
    wire [3:0]   dBus_cmd_payload_mask;
    wire [31:0]  dBus_cmd_payload_address;
    wire [31:0]  dBus_cmd_payload_data;
    wire [1:0]   dBus_cmd_payload_size;     // unused here, but exposed by core

    wire         dBus_rsp_ready;
    wire         dBus_rsp_error = 1'b0;
    wire [31:0]  dBus_rsp_data;

    // Map external interrupt to the array
    wire [0:0]   externalInterruptArray = externalInterrupt;

    VexRiscv cpu (
        // Instruction bus
        .iBus_cmd_valid           (iBus_cmd_valid),
        .iBus_cmd_ready           (iBus_cmd_ready),
        .iBus_cmd_payload_pc      (iBus_cmd_payload_pc),
        .iBus_rsp_valid           (iBus_rsp_valid),
        .iBus_rsp_payload_error   (iBus_rsp_payload_error),
        .iBus_rsp_payload_inst    (iBus_rsp_payload_inst),

        // Interrupts
        .timerInterrupt           (timerInterrupt),
        .softwareInterrupt        (softwareInterrupt),
        .externalInterruptArray   (externalInterruptArray),

        // JTAG + ndmreset
        .jtag_tms                 (core_jtag_tms),
        .jtag_tdi                 (core_jtag_tdi),
        .jtag_tdo                 (core_jtag_tdo),
        .jtag_tck                 (core_jtag_tck),
        .ndmreset                 (ndmreset),

        // Data bus
        .dBus_cmd_valid           (dBus_cmd_valid),
        .dBus_cmd_ready           (dBus_cmd_ready),
        .dBus_cmd_payload_wr      (dBus_cmd_payload_wr),
        .dBus_cmd_payload_mask    (dBus_cmd_payload_mask),
        .dBus_cmd_payload_address (dBus_cmd_payload_address),
        .dBus_cmd_payload_data    (dBus_cmd_payload_data),
        .dBus_cmd_payload_size    (dBus_cmd_payload_size),
        .dBus_rsp_ready           (dBus_rsp_ready),
        .dBus_rsp_error           (dBus_rsp_error),
        .dBus_rsp_data            (dBus_rsp_data),

        // System
        .reset                    (rst),       // DO NOT OR here; do it at the top level
        .stoptime                 (),          // unused
        .clk                      (clk),
        .debug_reset              (debug_reset)
    );

    // =========================
    // Instruction WB adapter (unchanged)
    // =========================

    reg i_busy;

    assign iw_we_o  = 1'b0;
    assign iw_dat_o = {DATA_WIDTH{1'b0}};
    assign iw_sel_o = {(DATA_WIDTH/8){1'b1}};

    always @(*) begin
        iBus_rsp_payload_inst = iw_dat_i;
    end

    always @(*) begin
        iBus_cmd_ready = ~i_busy;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            i_busy             <= 1'b0;
            iw_cyc_o           <= 1'b0;
            iw_stb_o           <= 1'b0;
            iw_adr_o           <= {ADDR_WIDTH{1'b0}};
            iBus_rsp_valid     <= 1'b0;
        end else begin
            iBus_rsp_valid <= 1'b0;

            if (!i_busy) begin
                if (iBus_cmd_valid && iBus_cmd_ready) begin
                    i_busy   <= 1'b1;
                    iw_cyc_o <= 1'b1;
                    iw_stb_o <= 1'b1;
                    iw_adr_o <= iBus_cmd_payload_pc;
                end
            end else begin
                if (iw_ack_i) begin
                    i_busy         <= 1'b0;
                    iw_cyc_o       <= 1'b0;
                    iw_stb_o       <= 1'b0;
                    iBus_rsp_valid <= 1'b1;
                end
            end
        end
    end

    // =========================
    // Data WB adapter
    // =========================
    // The core holds cmd.valid and the payload stable until cmd.ready.
    // The command is only consumed when the slave acknowledges it, and a
    // read response is only valid in that same cycle.

    // VexRiscv issues a load from the memory stage but consumes the data in
    // the writeback stage, which stalls until rsp.ready pulses. So the
    // command is accepted immediately (and latched), and rsp.ready is a
    // one-cycle pulse in the cycle the slave acks a READ.
    reg d_busy;

    assign dBus_cmd_ready = ~d_busy;
    assign dBus_rsp_ready = d_busy & dw_ack_i & ~dw_we_o;
    assign dBus_rsp_data  = dw_dat_i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            d_busy   <= 1'b0;
            dw_cyc_o <= 1'b0;
            dw_stb_o <= 1'b0;
            dw_we_o  <= 1'b0;
            dw_adr_o <= {ADDR_WIDTH{1'b0}};
            dw_dat_o <= {DATA_WIDTH{1'b0}};
            dw_sel_o <= {(DATA_WIDTH/8){1'b0}};
        end else begin
            if (!d_busy) begin
                if (dBus_cmd_valid) begin
                    d_busy   <= 1'b1;
                    dw_cyc_o <= 1'b1;
                    dw_stb_o <= 1'b1;
                    dw_we_o  <= dBus_cmd_payload_wr;
                    dw_adr_o <= dBus_cmd_payload_address;
                    dw_dat_o <= dBus_cmd_payload_data;
                    dw_sel_o <= dBus_cmd_payload_mask;
                end
            end else if (dw_ack_i) begin
                d_busy   <= 1'b0;
                dw_cyc_o <= 1'b0;
                dw_stb_o <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire