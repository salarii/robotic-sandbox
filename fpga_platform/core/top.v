module top(
    input wire clk,
    input wire reset
);
    // VexRiscv instance
    VexRiscv cpu(
        .clk(clk),
        .reset(reset),
        // Other ports...
    );
    
    // ROM instance
    vex_rom #(
        .ADDR_WIDTH(12),
        .INIT_FILE("firmware.hex")  // Optional
    ) rom (
        .clk(clk),
        .reset(reset),
        .i_cmd_valid(cpu.iBus_cmd_valid),
        .i_cmd_ready(cpu.iBus_cmd_ready),
        .i_cmd_payload_pc(cpu.iBus_cmd_payload_pc),
        .i_rsp_valid(cpu.iBus_rsp_valid),
        .i_rsp_payload_error(cpu.iBus_rsp_payload_error),
        .i_rsp_payload_inst(cpu.iBus_rsp_payload_inst)
    );
endmodule