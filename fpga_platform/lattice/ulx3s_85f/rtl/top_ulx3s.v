`default_nettype none

module top_ulx3s (
    input  wire clk,
    input  wire rst,          
    input  wire debug_reset,  
    
    output wire uart_tx_o,
    input  wire uart_rx_i
);

    // Dummy wires for unconnected I2C inouts
    wire i2c_scl;
    wire i2c_sda;

    // Instantiate the hardware SoC
    wishbone_top #(
        .IMEM_INIT_FILE("rtl/cpus/test.hex")
    ) soc_inst (
        .clk(clk),
        .rst(rst),
        
        // JTAG is handled internally by Lattice JTAGG in simple_to_wishbone.
        // Tie off the explicit ports for synthesis.
        .jtag_tms(1'b0),
        .jtag_tdi(1'b0),
        .jtag_tdo(),
        .jtag_tck(1'b0),
        
        .debug_reset(debug_reset),
        
        // UART hardware mapping
        .stx_pad_o(uart_tx_o),
        .srx_pad_i(uart_rx_i),
        .rts_pad_o(),
        .cts_pad_i(1'b1),
        .dtr_pad_o(),
        .dsr_pad_i(1'b1),
        .ri_pad_i(1'b0),
        .dcd_pad_i(1'b1),

        // I2C (Unmapped in LPF currently, left floating)
        .i2c_scl(i2c_scl),
        .i2c_sda(i2c_sda)
    );

endmodule
`default_nettype wire