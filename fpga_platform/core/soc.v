module soc(
    input wire clk,
    input wire reset,
    input wire dr_packet_valid,
    input wire [40:0] dr_packet
);

    // Internal wires to connect debug_cmd_scaffold <-> VexRiscv
    wire        cpu_cmd_valid;
    wire        cpu_cmd_wr;
    wire [7:0]  cpu_cmd_address;
    wire [31:0] cpu_cmd_data;
    wire        cpu_cmd_ready;
    wire [31:0] cpu_rsp;
    wire        rsp_valid_to_tap;
    wire [31:0] rsp_to_tap;

    // Debug Command Scaffolding
    debug_cmd_scaffold #(
        .CMD_WIDTH(41),
        .ADDR_WIDTH(8),
        .DATA_WIDTH(32)
    ) debug_if (
        .clk(clk),
        .reset(reset),
        .dr_packet_valid(dr_packet_valid),
        .dr_packet(dr_packet),

        // CPU side
        .cpu_cmd_valid(cpu_cmd_valid),
        .cpu_cmd_wr(cpu_cmd_wr),
        .cpu_cmd_address(cpu_cmd_address),
        .cpu_cmd_data(cpu_cmd_data),
        .cpu_cmd_ready(cpu_cmd_ready),
        .cpu_rsp(cpu_rsp),

        // Response to JTAG/TAP
        .rsp_valid_to_tap(rsp_valid_to_tap),
        .rsp_to_tap(rsp_to_tap)
    );

    // -- "Busify" debug_cmd_scaffold outputs for VexRiscv compatibility
    // (VexRiscv expects a ready/valid bus, wr/address/data)
    assign cpu_cmd_ready = 1'b1; // For now, always ready (adjust as needed)
    assign cpu_rsp       = 32'b0; // For now, dummy response (you may want to drive actual CPU response!)

    VexRiscv cpu (
        // Connect debug interface to signals (as in your version)
        .debug_bus_cmd_valid(cpu_cmd_valid),
        .debug_bus_cmd_ready(cpu_cmd_ready),   // Driven above (currently always 1'b1)
        .debug_bus_cmd_payload_wr(cpu_cmd_wr),
        .debug_bus_cmd_payload_address(cpu_cmd_address),
        .debug_bus_cmd_payload_data(cpu_cmd_data),
        .debug_bus_rsp_data(cpu_rsp),

        // Unused outputs
        .debug_resetOut(),

        // Instruction/data bus, interrupts, and other ports are left unconnected for now
        .iBus_cmd_valid(),
        .iBus_cmd_ready(1'b0),
        .iBus_cmd_payload_pc(),
        .iBus_rsp_valid(1'b0),
        .iBus_rsp_payload_error(1'b0),
        .iBus_rsp_payload_inst(32'b0),
        .timerInterrupt(1'b0),
        .softwareInterrupt(1'b0),
        .externalInterruptArray(1'b0),
        .dBus_cmd_valid(),
        .dBus_cmd_ready(1'b0),
        .dBus_cmd_payload_wr(),
        .dBus_cmd_payload_mask(),
        .dBus_cmd_payload_address(),
        .dBus_cmd_payload_data(),
        .dBus_cmd_payload_size(),
        .dBus_rsp_ready(1'b0),
        .dBus_rsp_error(1'b0),
        .dBus_rsp_data(32'b0),

        .clk(clk),
        .reset(reset)
    );

    // You may want to forward rsp_valid_to_tap/rsp_to_tap to a top-level output or TAP/JTAG module.
    // For now, they are unused in this example.

endmodule
