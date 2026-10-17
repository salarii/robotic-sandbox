// Dual-Wishbone bridge wrapper for VexRiscv
// - Separate Wishbone masters: instruction (read-only) and data (read/write)
// - Classic single-beat cycles (CYC/STB held until ACK)
// - iBus/dBus valid/ready mapped to Wishbone handshake
// - Debug & interrupts ignored/tied off

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
    reg          dBus_cmd_ready;
    wire         dBus_cmd_payload_wr;
    wire [3:0]   dBus_cmd_payload_mask;
    wire [31:0]  dBus_cmd_payload_address;
    wire [31:0]  dBus_cmd_payload_data;
    wire [1:0]   dBus_cmd_payload_size;     // unused here, but exposed by core

    // Vex expects these as inputs from "slave" side; we just keep them ready/clean
    wire         dBus_rsp_ready = 1'b1;
    wire         dBus_rsp_error = 1'b0;
    wire [31:0]  dBus_rsp_data;

    // Map external interrupt to the array
    wire [0:0]   externalInterruptArray = externalInterrupt;

    // Debug - ignored
    wire         debug_bus_cmd_valid    = 1'b0;
    wire         debug_bus_cmd_payload_wr = 1'b0;
    wire [7:0]   debug_bus_cmd_payload_address = 8'h00;
    wire [31:0]  debug_bus_cmd_payload_data    = 32'h0000_0000;
    wire         debug_resetOut;
    wire [31:0]  debug_bus_rsp_data;
    wire         debug_bus_cmd_ready;

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
        .jtag_tms                 (jtag_tms),
        .jtag_tdi                 (jtag_tdi),
        .jtag_tdo                 (jtag_tdo),
        .jtag_tck                 (jtag_tck),
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
    // Instruction WB adapter
    // =========================

    // Simple "busy" tracker for iBus single-beat transaction
    reg i_busy;

    // Read-only Wishbone
    assign iw_we_o  = 1'b0;
    assign iw_dat_o = {DATA_WIDTH{1'b0}};
    assign iw_sel_o = {(DATA_WIDTH/8){1'b1}};

    // Map CPU instruction response data
    always @(*) begin
        // Feed back the last captured WB data when asserting rsp_valid
        iBus_rsp_payload_inst = iw_dat_i;
    end

    // Ready when not busy (i.e., we can accept a new fetch command)
    always @(*) begin
        iBus_cmd_ready = ~i_busy;
    end

    // Generate rsp_valid as a 1-cycle pulse on ACK
    // Keep CYC/STB asserted from accept until ACK
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            i_busy             <= 1'b0;
            iw_cyc_o           <= 1'b0;
            iw_stb_o           <= 1'b0;
            iw_adr_o           <= {ADDR_WIDTH{1'b0}};
            iBus_rsp_valid     <= 1'b0;
        end else begin
            // default: deassert rsp_valid unless we just got an ack
            iBus_rsp_valid <= 1'b0;

            if (!i_busy) begin
                // Idle, check for new fetch
                if (iBus_cmd_valid && iBus_cmd_ready) begin
                    i_busy   <= 1'b1;
                    iw_cyc_o <= 1'b1;
                    iw_stb_o <= 1'b1;
                    // VexRiscv's PC is a byte address; pass through
                    iw_adr_o <= iBus_cmd_payload_pc;
                end
            end else begin
                // Busy: wait for ACK
                if (iw_ack_i) begin
                    // One-beat read completes
                    i_busy         <= 1'b0;
                    iw_cyc_o       <= 1'b0;
                    iw_stb_o       <= 1'b0;
                    iBus_rsp_valid <= 1'b1;  // pulse to deliver instruction word
                end
            end
        end
    end

    // =========================
    // Data WB adapter
    // =========================

    reg d_busy;

    // Drive dBus response wires
    assign dBus_rsp_data = dw_dat_i;

    // Ready when not busy (we can accept a new data command)
    always @(*) begin
        dBus_cmd_ready = ~d_busy;
    end

    // Latch request info so we can hold it stable during the WB cycle
    reg               d_req_we;
    reg [ADDR_WIDTH-1:0] d_req_addr;
    reg [DATA_WIDTH-1:0] d_req_wdata;
    reg [(DATA_WIDTH/8)-1:0] d_req_sel;

    // Generate no explicit "rsp_valid" for dBus because VexRiscv's dBus uses
    // ready/valid differently (it samples rsp_data when its internal logic expects it).
    // For simplest timing, we keep dBus_rsp_ready=1 and "complete" the transfer on ACK.

    // Classic single-beat WB cycle
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            d_busy   <= 1'b0;
            dw_cyc_o <= 1'b0;
            dw_stb_o <= 1'b0;
            dw_we_o  <= 1'b0;
            dw_adr_o <= {ADDR_WIDTH{1'b0}};
            dw_dat_o <= {DATA_WIDTH{1'b0}};
            dw_sel_o <= {(DATA_WIDTH/8){1'b0}};

            d_req_we   <= 1'b0;
            d_req_addr <= {ADDR_WIDTH{1'b0}};
            d_req_wdata<= {DATA_WIDTH{1'b0}};
            d_req_sel  <= {(DATA_WIDTH/8){1'b0}};
        end else begin
            if (!d_busy) begin
                // Idle: accept a new data command
                if (dBus_cmd_valid && dBus_cmd_ready) begin
                    d_busy     <= 1'b1;

                    // Latch request
                    d_req_we    <= dBus_cmd_payload_wr;
                    d_req_addr  <= dBus_cmd_payload_address;
                    d_req_wdata <= dBus_cmd_payload_data;
                    d_req_sel   <= dBus_cmd_payload_mask;

                    // Start WB cycle
                    dw_cyc_o <= 1'b1;
                    dw_stb_o <= 1'b1;
                    dw_we_o  <= dBus_cmd_payload_wr;
                    dw_adr_o <= dBus_cmd_payload_address;
                    dw_dat_o <= dBus_cmd_payload_data;
                    dw_sel_o <= dBus_cmd_payload_mask;
                end
            end else begin
                // Busy: wait for ACK to finish the beat
                if (dw_ack_i) begin
                    d_busy   <= 1'b0;
                    dw_cyc_o <= 1'b0;
                    dw_stb_o <= 1'b0;
                    // dw_we_o/dw_* can remain as latched; they'll be overwritten on next txn
                end
            end
        end
    end

endmodule

`default_nettype wire
