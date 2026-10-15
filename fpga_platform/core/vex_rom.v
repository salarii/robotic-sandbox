module vex_rom #(
    parameter ADDR_WIDTH = 12,  // 4KB ROM by default (12-bit address)
    parameter INIT_FILE = ""    // Optional initialization file
) (
    input wire clk,
    input wire reset,
    
    // Instruction bus interface (read-only)
    input wire i_cmd_valid,
    output wire i_cmd_ready,
    input wire [31:0] i_cmd_payload_pc,
    
    output wire i_rsp_valid,
    output wire i_rsp_payload_error,
    output wire [31:0] i_rsp_payload_inst,
    
    // Optional write interface for initialization
    input wire wr_en,
    input wire [ADDR_WIDTH-1:0] wr_addr,
    input wire [31:0] wr_data
);

// ROM storage
reg [31:0] rom [(2**ADDR_WIDTH)-1:0];

// Default program (addi x1, x0, 42; addi x1, x1, 1; j _start)
initial begin
    rom[0] = 32'h02a00093;  // addi x1, x0, 42
    rom[1] = 32'h00108093;  // addi x1, x1, 1
    rom[2] = 32'h0000006f;  // j 0 (infinite loop)
    
    // Load from file if specified
    if (INIT_FILE != "") begin
        $readmemh(INIT_FILE, rom);
    end
end

// Write interface (for initialization)
always @(posedge clk) begin
    if (wr_en) begin
        rom[wr_addr] <= wr_data;
    end
end

// Read logic
reg [31:0] rsp_data;
reg rsp_valid;

assign i_cmd_ready = 1'b1;  // Always ready
assign i_rsp_valid = rsp_valid;
assign i_rsp_payload_inst = rsp_data;
assign i_rsp_payload_error = 1'b0;

always @(posedge clk) begin
    if (reset) begin
        rsp_valid <= 1'b0;
    end else begin
        rsp_valid <= i_cmd_valid;
        if (i_cmd_valid) begin
            // Simple address translation (assuming 32-bit aligned accesses)
            rsp_data <= rom[i_cmd_payload_pc[ADDR_WIDTH+1:2]];
        end
    end
end

endmodule