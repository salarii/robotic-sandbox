`default_nettype none

module top_ulx3s (
    input  wire clk,
    input  wire rst,          
    input  wire debug_reset,  
    
    output wire uart_tx_o,
    input  wire uart_rx_i,

    // YOU MUST ADD THESE PORTS TO REACH THE PHYSICAL PINS
    input  wire jtag_tck,
    input  wire jtag_tms,
    input  wire jtag_tdi,
    output wire jtag_tdo,

    inout  wire i2c_scl,
    inout  wire i2c_sda
);


    wishbone_top #(
        .IMEM_INIT_FILE("rtl/cpus/test.hex")
    ) soc_inst (
        .clk(clk),
        .rst(rst),
        
        // CONNECT TO THE EXPOSED PORTS, DO NOT TIE TO 1'b0
        .jtag_tms(jtag_tms),
        .jtag_tdi(jtag_tdi),
        .jtag_tdo(jtag_tdo),
        .jtag_tck(jtag_tck),
        
        .debug_reset(debug_reset),
        
        .stx_pad_o(uart_tx_o),
        .srx_pad_i(uart_rx_i),
        .rts_pad_o(),
        .cts_pad_i(1'b1),
        .dtr_pad_o(),
        .dsr_pad_i(1'b1),
        .ri_pad_i(1'b0),
        .dcd_pad_i(1'b1),

        .i2c_scl(i2c_scl),
        .i2c_sda(i2c_sda)
    );

endmodule
`default_nettype wire