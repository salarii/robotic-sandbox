`timescale 1ns/1ps

module top_vex (
  input  wire         clk,
  input  wire         reset,

  // JTAG pins driving the internal VexRiscv Debug Module directly
  input  wire         jtag_tck,
  input  wire         jtag_tms,
  input  wire         jtag_tdi,
  output wire         jtag_tdo,

  // iBus exposed to C++ testbench
  output wire         iBus_cmd_valid,
  input  wire         iBus_cmd_ready,
  output wire [31:0]  iBus_cmd_payload_pc,
  input  wire         iBus_rsp_valid,
  input  wire         iBus_rsp_payload_error,
  input  wire [31:0]  iBus_rsp_payload_inst,

  // dBus exposed to C++ testbench
  output wire         dBus_cmd_valid,
  input  wire         dBus_cmd_ready,
  output wire         dBus_cmd_payload_wr,
  output wire [3:0]   dBus_cmd_payload_mask,
  output wire [31:0]  dBus_cmd_payload_address,
  output wire [31:0]  dBus_cmd_payload_data,
  output wire [1:0]   dBus_cmd_payload_size,
  input  wire         dBus_rsp_ready,
  input  wire         dBus_rsp_error,
  input  wire [31:0]  dBus_rsp_data
);

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

    .jtag_tck                  (jtag_tck),
    .jtag_tms                  (jtag_tms),
    .jtag_tdi                  (jtag_tdi),
    .jtag_tdo                  (jtag_tdo),
    .debug_reset               (reset),
    .ndmreset                  (),
    .stoptime                  (),

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

endmodule