`timescale 1ns/1ps
`default_nettype none

module sim_soc_zephyr (
    input  wire clk,
    input  wire rst,

    // JTAG pass-through (optional/tied if not used)
    input  wire jtag_tms,
    input  wire jtag_tdi,
    output wire jtag_tdo,
    input  wire jtag_tck,
    input  wire debug_reset,

    // Testbench monitor outputs (data bus)
    output wire        dbg_dw_cyc,
    output wire        dbg_dw_stb,
    output wire        dbg_dw_we,
    output wire        dbg_dw_ack,
    output wire [31:0] dbg_dw_adr,
    output wire [31:0] dbg_dw_dat_m2s,
    output wire [3:0]  dbg_dw_sel
);

    // Wishbone Masters from CPU Bridge
    wire                        iw_cyc, iw_stb, iw_we;
    wire [31:0]                 iw_adr;
    wire [31:0]                 iw_dat_o;
    wire [3:0]                  iw_sel;
    wire [31:0]                 iw_dat_i;
    wire                        iw_ack;

    wire                        dw_cyc, dw_stb, dw_we;
    wire [31:0]                 dw_adr;
    wire [31:0]                 dw_dat_m2s;
    wire [3:0]                  dw_sel;
    wire [31:0]                 dw_dat_s2m;
    wire                        dw_ack;

    wire ndmreset;
    wire rst_sys = rst | ndmreset;

    wire irq_to_cpu;
    wire msip;
    wire mtip;

    // CPU Bridge Instance (requires interrupt ports added)
    simple_to_wishbone cpu_bridge (
        .clk(clk),
        .rst(rst_sys),
        .jtag_tms   (jtag_tms),
        .jtag_tdi   (jtag_tdi),
        .jtag_tdo   (jtag_tdo),
        .jtag_tck   (jtag_tck),
        .debug_reset(debug_reset),
        
        .timerInterrupt   (mtip),
        .softwareInterrupt(msip),
        .externalInterrupt(irq_to_cpu),
        .ndmreset         (ndmreset),

        // Instruction master
        .iw_cyc_o(iw_cyc), .iw_stb_o(iw_stb), .iw_we_o(iw_we),
        .iw_adr_o(iw_adr), .iw_dat_o(iw_dat_o), .iw_sel_o(iw_sel),
        .iw_dat_i(iw_dat_i), .iw_ack_i(iw_ack),

        // Data master
        .dw_cyc_o(dw_cyc), .dw_stb_o(dw_stb), .dw_we_o(dw_we),
        .dw_adr_o(dw_adr), .dw_dat_o(dw_dat_m2s), .dw_sel_o(dw_sel),
        .dw_dat_i(dw_dat_s2m), .dw_ack_i(dw_ack)
    );

    // ============================================================
    // Address Decoding (Data Bus) based on DTSI
    // ============================================================
    wire uart_sel     = (dw_adr[31:16] == 16'h1000);
    wire ram_sel      = (dw_adr[31:16] == 16'h2000); 
    wire watchdog_sel = (dw_adr[31:16] == 16'h4000);
    wire plic_sel     = (dw_adr[31:16] == 16'h5000);
    wire clint_sel    = (dw_adr[31:16] == 16'h6000);
    wire imem_sel_dw  = (dw_adr[31:16] == 16'h8000); 

    wire        uart_ack, ram_ack, watchdog_ack, plic_ack, clint_ack, imem_ack_dw;
    wire [31:0] uart_dat_o, ram_dat_o, watchdog_dat_o, plic_dat_o, clint_dat_o, imem_dat_dw;

    assign dw_dat_s2m = uart_sel     ? uart_dat_o     :
                        imem_sel_dw  ? imem_dat_dw    :
                        ram_sel      ? ram_dat_o      :
                        watchdog_sel ? watchdog_dat_o :
                        plic_sel     ? plic_dat_o     :
                        clint_sel    ? clint_dat_o    :
                        32'd0;

    wire any_sel_dw = uart_sel | imem_sel_dw | ram_sel | watchdog_sel | plic_sel | clint_sel;
    reg unmapped_ack_dw;
    always @(posedge clk or posedge rst_sys) begin
        if (rst_sys) unmapped_ack_dw <= 1'b0;
        else unmapped_ack_dw <= (dw_cyc & dw_stb & ~any_sel_dw) & ~unmapped_ack_dw;
    end

    assign dw_ack = (uart_sel & uart_ack) | (imem_sel_dw & imem_ack_dw) | (ram_sel & ram_ack) | 
                    (watchdog_sel & watchdog_ack) | (plic_sel & plic_ack) | (clint_sel & clint_ack) | unmapped_ack_dw;

    // Peripherals
    wire uart_irq, watchdog_irq;
    
    uart_top uart_inst (
        .wb_clk_i(clk), .wb_rst_i(rst_sys), .wb_adr_i(dw_adr[4:0]),
        .wb_dat_i(dw_dat_m2s), .wb_dat_o(uart_dat_o),
        .wb_we_i(dw_we), .wb_stb_i(dw_stb & uart_sel),
        .wb_cyc_i(dw_cyc), .wb_ack_o(uart_ack), .wb_sel_i(dw_sel),
        .int_o(uart_irq),
        .stx_pad_o(), .srx_pad_i(1'b1), // Tied idle for sim
        .rts_pad_o(), .cts_pad_i(1'b1),
        .dtr_pad_o(), .dsr_pad_i(1'b1),
        .ri_pad_i (1'b0), .dcd_pad_i(1'b1)
    );

    wb_ram #(
        .DATA_WIDTH(32), .ADDR_WIDTH(16), .SELECT_WIDTH(4)
    ) data_ram (
        .clk(clk), .adr_i(dw_adr[15:0]), .dat_i(dw_dat_m2s),
        .dat_o(ram_dat_o), .we_i(dw_we), .sel_i(dw_sel),
        .stb_i(dw_stb & ram_sel), .ack_o(ram_ack), .cyc_i(dw_cyc)
    );

    watchdog watchdog_inst (
        .wb_clk_i(clk), .wb_rst_i(rst_sys), .wb_dat_i(dw_dat_m2s),
        .wb_dat_o(watchdog_dat_o), .wb_we_i(dw_we),
        .wb_stb_i(dw_stb & watchdog_sel), .wb_cyc_i(dw_cyc),
        .wb_ack_o(watchdog_ack), .wb_int_o(watchdog_irq)
    );

    // Map UART to IRQ ID 5 (index 4)
    wire [7:0] irq_sources = {3'd0, uart_irq, 3'd0, watchdog_irq};
    
    wishbone_plic plic_inst (
        .clk(clk), .rst(rst_sys),
        .wb_cyc_i(dw_cyc), .wb_stb_i(dw_stb & plic_sel), .wb_we_i(dw_we),
        .wb_adr_i(dw_adr), .wb_dat_i(dw_dat_m2s), .wb_dat_o(plic_dat_o),
        .wb_ack_o(plic_ack), .irq_sources(irq_sources), .irq_to_cpu(irq_to_cpu)
    );

    clint clint_inst (
        .clk(clk), .rst(rst_sys),
        .wb_cyc_i(dw_cyc), .wb_stb_i(dw_stb & clint_sel), .wb_we_i(dw_we),
        .wb_adr_i(dw_adr), .wb_dat_i(dw_dat_m2s), .wb_dat_o(clint_dat_o),
        .wb_ack_o(clint_ack), .msip(msip), .mtip(mtip)
    );

    // ============================================================
    // Instruction Bus Decoding (ROM / IMEM)
    // ============================================================
    wire imem_sel_iw = (iw_adr[31:16] == 16'h8000);
    wire imem_ack_iw;
    wire [31:0] imem_dat_iw;

    reg unmapped_ack_iw;
    always @(posedge clk or posedge rst_sys) begin
        if (rst_sys) unmapped_ack_iw <= 1'b0;
        else unmapped_ack_iw <= (iw_cyc & iw_stb & ~imem_sel_iw) & ~unmapped_ack_iw;
    end

    assign iw_dat_i = imem_sel_iw ? imem_dat_iw : 32'h00000013;
    assign iw_ack   = imem_sel_iw ? imem_ack_iw : unmapped_ack_iw;

    wb_dp_ram #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(16),
        .SELECT_WIDTH(4),
        .INIT_FILE("cpus/test.hex")
    ) imem (
        .a_clk(clk), .a_adr_i(iw_adr[15:0]), .a_dat_i(32'b0),
        .a_dat_o(imem_dat_iw), .a_we_i(1'b0),
        .a_sel_i(iw_sel != 4'b0000 ? iw_sel : 4'b1111),
        .a_stb_i(iw_stb & imem_sel_iw), .a_ack_o(imem_ack_iw), .a_cyc_i(iw_cyc),

        .b_clk(clk), .b_adr_i(dw_adr[15:0]), .b_dat_i(dw_dat_m2s),
        .b_dat_o(imem_dat_dw), .b_we_i(dw_we), .b_sel_i(dw_sel),
        .b_stb_i(dw_stb & imem_sel_dw), .b_ack_o(imem_ack_dw), .b_cyc_i(dw_cyc)
    );

    // ============================================================
    // Testbench monitor outputs
    // ============================================================
    assign dbg_dw_cyc     = dw_cyc;
    assign dbg_dw_stb     = dw_stb;
    assign dbg_dw_we      = dw_we;
    assign dbg_dw_ack     = dw_ack;
    assign dbg_dw_adr     = dw_adr;
    assign dbg_dw_dat_m2s = dw_dat_m2s;
    assign dbg_dw_sel     = dw_sel;

endmodule
`default_nettype wire