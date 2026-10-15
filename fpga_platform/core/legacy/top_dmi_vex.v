`timescale 1ns/1ps

module top_dmi_vex (
  input  wire         clk,
  input  wire         reset,

  // DMI window (to Verilator/OpenOCD)
  input  wire [40:0]  dmi_req,        // {addr[40:34], data[33:2], op[1:0]}
  input  wire         dmi_req_valid,  // external request (level or pulse)
  output wire [40:0]  dmi_rsp,        // {addr, data, op} from previous scan
  output wire         dmi_rsp_valid   // "long-lasting" valid (see logic below)
);

  // -----------------------------
  // Wires between bridge and CPU
  // -----------------------------
  wire          dbg_valid;
  wire          dbg_ready;
  wire          dbg_wr;
  wire  [7:0]   dbg_addr;
  wire  [31:0]  dbg_wdata;
  wire  [31:0]  dbg_rdata;

  // --------------------------------
  // Instantiate the DMI↔Debug bridge
  // --------------------------------
  reg dmi_req_valid_q;    // 1-scan delayed request
  reg dmi_rsp_valid_q;    // sticky valid

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      dmi_req_valid_q <= 1'b0;
      dmi_rsp_valid_q <= 1'b0;
    end else begin
      dmi_req_valid_q <= dmi_req_valid;
      // Make valid "long-lasting": hold high until a new request comes
      if (dmi_req_valid) begin
        dmi_rsp_valid_q <= 1'b0;     // clear on new request (about to pipeline)
      end else if (dmi_req_valid_q) begin
        dmi_rsp_valid_q <= 1'b1;     // assert one scan after the request
      end
      // If you prefer 1-cycle valid, replace the two lines above with:
      // dmi_rsp_valid_q <= dmi_req_valid_q;
    end
  end

  assign dmi_rsp_valid = dmi_rsp_valid_q;

  // -----------------------------
  // Bridge instance: FIXED PORTS
  // -----------------------------
  rv_dm_bridge #(.XLEN(32)) u_dm (
    .clk   (clk),
    .reset (reset),

    .dmi_req    (dmi_req),
    .dmi_rsp    (dmi_rsp),
    .dmi_req_stb(dmi_req_valid),  // <-- FIX: tie top's valid to bridge strobe

    .debug_bus_cmd_valid           (dbg_valid),
    .debug_bus_cmd_ready           (dbg_ready),
    .debug_bus_cmd_payload_wr      (dbg_wr),
    .debug_bus_cmd_payload_address (dbg_addr),
    .debug_bus_cmd_payload_data    (dbg_wdata),
    .debug_bus_rsp_data            (dbg_rdata)
  );

  // ------------------------
  // VexRiscv core instance
  // ------------------------
  wire          iBus_cmd_valid;
  reg           iBus_cmd_ready;
  wire  [31:0]  iBus_cmd_payload_pc;
  reg           iBus_rsp_valid;
  reg           iBus_rsp_payload_error;
  reg   [31:0]  iBus_rsp_payload_inst;

  wire          dBus_cmd_valid;
  reg           dBus_cmd_ready;
  wire          dBus_cmd_payload_wr;
  wire  [3:0]   dBus_cmd_payload_mask;
  wire  [31:0]  dBus_cmd_payload_address;
  wire  [31:0]  dBus_cmd_payload_data;
  wire  [1:0]   dBus_cmd_payload_size;
  reg           dBus_rsp_ready;
  reg           dBus_rsp_error;
  reg   [31:0]  dBus_rsp_data;

  // idle interrupts
  wire          timerInterrupt         = 1'b0;
  wire          softwareInterrupt      = 1'b0;
  wire  [0:0]   externalInterruptArray = 1'b0;

  // CPU instance
  VexRiscv u_cpu (
    .iBus_cmd_valid            (iBus_cmd_valid),
    .iBus_cmd_ready            (iBus_cmd_ready),
    .iBus_cmd_payload_pc       (iBus_cmd_payload_pc),
    .iBus_rsp_valid            (iBus_rsp_valid),
    .iBus_rsp_payload_error    (iBus_rsp_payload_error),
    .iBus_rsp_payload_inst     (iBus_rsp_payload_inst),

    .timerInterrupt            (timerInterrupt),
    .softwareInterrupt         (softwareInterrupt),

    .debug_bus_cmd_valid           (dbg_valid),
    .debug_bus_cmd_ready           (dbg_ready),
    .debug_bus_cmd_payload_wr      (dbg_wr),
    .debug_bus_cmd_payload_address (dbg_addr),
    .debug_bus_cmd_payload_data    (dbg_wdata),
    .debug_bus_rsp_data            (dbg_rdata),
    .debug_resetOut                (),

    .externalInterruptArray    (externalInterruptArray),

    .dBus_cmd_valid            (dBus_cmd_valid),
    .dBus_cmd_ready            (dBus_cmd_ready),
    .dBus_cmd_payload_wr       (dBus_cmd_payload_wr),
    .dBus_cmd_payload_mask     (dBus_cmd_payload_mask),
    .dBus_cmd_payload_address  (dBus_cmd_payload_address),
    .dBus_cmd_payload_data     (dBus_cmd_payload_data),
    .dBus_cmd_payload_size     (dBus_cmd_payload_size),
    .dBus_rsp_ready            (dBus_rsp_ready),
    .dBus_rsp_error            (dBus_rsp_error),
    .dBus_rsp_data             (dBus_rsp_data),

    .clk                       (clk),
    .reset                     (reset)
  );

  // -----------------------------
  // Minimal iBus: 1-cycle NOP rsp
  // -----------------------------
  localparam [31:0] NOP = 32'h00000013; // ADDI x0,x0,0

  always @* begin
    iBus_cmd_ready = 1'b1;
  end

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      iBus_rsp_valid         <= 1'b0;
      iBus_rsp_payload_error <= 1'b0;
      iBus_rsp_payload_inst  <= NOP;
    end else begin
      iBus_rsp_valid         <= iBus_cmd_valid & iBus_cmd_ready;
      iBus_rsp_payload_error <= 1'b0;
      iBus_rsp_payload_inst  <= NOP;
    end
  end

  // -----------------------------
  // Minimal dBus: ready, zero data
  // -----------------------------
  always @* begin
    dBus_cmd_ready = 1'b1;
    dBus_rsp_ready = 1'b1;
  end

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      dBus_rsp_error <= 1'b0;
      dBus_rsp_data  <= 32'h00000000;
    end else begin
      dBus_rsp_error <= 1'b0;
      dBus_rsp_data  <= 32'h00000000;
    end
  end

endmodule
