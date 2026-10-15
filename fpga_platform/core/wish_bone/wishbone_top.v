`timescale 1ns/1ps

module wishbone_top (
    input  wire clk,
    input  wire rst,

    // ---- JTAG (exposed) ----
    input  wire jtag_tms,
    input  wire jtag_tdi,
    output wire jtag_tdo,
    input  wire jtag_tck,
    input  wire debug_reset,   // forwarded to VexRiscv

    // UART Pins
    output wire stx_pad_o,
    input  wire srx_pad_i,
    output wire rts_pad_o,
    input  wire cts_pad_i,   // currently ignored internally (kept for pinout)
    output wire dtr_pad_o,
    input  wire dsr_pad_i,   // currently ignored internally (kept for pinout)
    input  wire ri_pad_i,    // currently ignored internally (kept for pinout)
    input  wire dcd_pad_i    // currently ignored internally (kept for pinout)

);

    // ============================================================
    // CPU bridge -> two Wishbone masters (instruction & data)
    // ============================================================
    // Your renamed module: exposes iw_* (RO) and dw_* (RW)
    wire                        iw_cyc, iw_stb, iw_we;
    wire [31:0]                 iw_adr;
    wire [31:0]                 iw_dat_o;  // unused (read-only)
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
    simple_to_wishbone cpu_bridge (
        .clk(clk),
        .rst(rst_sys),

        // ---- JTAG pass-through ----
        .jtag_tms   (jtag_tms),
        .jtag_tdi   (jtag_tdi),
        .jtag_tdo   (jtag_tdo),
        .jtag_tck   (jtag_tck),
        .debug_reset(debug_reset),

        // ---- ndmreset out ----
        .ndmreset   (ndmreset),

        // Instruction WB master (read-only)
        .iw_cyc_o(iw_cyc),
        .iw_stb_o(iw_stb),
        .iw_we_o (iw_we),         // should be 1'b0 from bridge
        .iw_adr_o(iw_adr),
        .iw_dat_o(iw_dat_o),      // unused
        .iw_sel_o(iw_sel),
        .iw_dat_i(iw_dat_i),
        .iw_ack_i(iw_ack),

        // Data WB master (read/write)
        .dw_cyc_o(dw_cyc),
        .dw_stb_o(dw_stb),
        .dw_we_o (dw_we),
        .dw_adr_o(dw_adr),
        .dw_dat_o(dw_dat_m2s),
        .dw_sel_o(dw_sel),
        .dw_dat_i(dw_dat_s2m),
        .dw_ack_i(dw_ack)
    );

    // ============================================================
    // DATA BUS interconnect (UART/RAM/WATCHDOG/PLIC/CLINT)
    // ============================================================
    // Address decoding on data bus
    wire uart_sel     = (dw_adr[31:16] == 16'h1000);
    wire ram_sel      = (dw_adr[31:16] == 16'h2000);
    wire watchdog_sel = (dw_adr[31:16] == 16'h4000);
    wire plic_sel     = (dw_adr[31:16] == 16'h5000);
    wire clint_sel    = (dw_adr[31:16] == 16'h6000);
    wire imem_sel_dw = (dw_adr[31:16] == 16'h8000); 
    // Peripheral ack/data (data bus)
    wire        uart_ack, ram_ack, watchdog_ack, plic_ack, clint_ack;
    wire [31:0] uart_dat_o, ram_dat_o, watchdog_dat_o, plic_dat_o, clint_dat_o;
    wire        imem_ack_dw;
    wire [31:0] imem_dat_dw;
    // Data mux & ack OR (data bus)
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
        if (rst_sys)
            unmapped_ack_dw <= 1'b0;
        else
            unmapped_ack_dw <= (dw_cyc & dw_stb & ~any_sel_dw) & ~unmapped_ack_dw;
    end

    assign dw_ack     = (uart_sel     & uart_ack)
                      | (imem_sel_dw  & imem_ack_dw)
                      | (ram_sel      & ram_ack)
                      | (watchdog_sel & watchdog_ack)
                      | (plic_sel     & plic_ack)
                      | (clint_sel    & clint_ack)
                      | unmapped_ack_dw;

    // ---------------- Peripherals on DATA bus ----------------
    uart_top uart_inst (
        .wb_clk_i(clk), .wb_rst_i(rst_sys), .wb_adr_i(dw_adr[4:0]),
        .wb_dat_i(dw_dat_m2s), .wb_dat_o(uart_dat_o),
        .wb_we_i(dw_we), .wb_stb_i(dw_stb & uart_sel),
        .wb_cyc_i(dw_cyc), .wb_ack_o(uart_ack), .wb_sel_i(dw_sel),
        .int_o(uart_irq),

        .stx_pad_o(stx_pad_o), .srx_pad_i(srx_pad_i),

        // ---- Hard-wire modem pins ----
        .rts_pad_o(),            // leave unconnected internally (we’ll drive top port below)
        .cts_pad_i(1'b1),        // CTS = ready
        .dtr_pad_o(),            // leave unconnected internally (we’ll drive top port below)
        .dsr_pad_i(1'b1),        // DSR = ready
        .ri_pad_i (1'b0),        // RI  = no ring
        .dcd_pad_i(1'b1)         // DCD = carrier present
    );
    assign rts_pad_o = 1'b1;  // Request To Send asserted
    assign dtr_pad_o = 1'b1;  // Data Terminal Ready asserted
    wb_ram ram_inst (
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

    wire [7:0] irq_sources;
    wire       uart_irq, watchdog_irq;
    assign irq_sources = {6'd0, watchdog_irq, uart_irq};
    wire irq_to_cpu;
    wire msip;
    wire mtip;
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
    // INSTRUCTION BUS (ROM only, read-only)
    // ============================================================
    // Optional guard: ensure iBus points to ROM window (same map style)

    localparam [15:0] IMEM_BASE_HI = 16'h8000;


    wire imem_sel_iw = (iw_adr[31:16] == IMEM_BASE_HI);
    wire [31:0] imem_dat_iw, imem_dat_dw;
    wire        imem_ack_iw;
    reg unmapped_ack_iw;
    always @(posedge clk or posedge rst_sys) begin
        if (rst_sys)
            unmapped_ack_iw <= 1'b0;
        else
            unmapped_ack_iw <= (iw_cyc & iw_stb & ~imem_sel_iw) & ~unmapped_ack_iw;
    end
    // ROM is read-only: we_i=0 inside its port anyway
    assign iw_dat_i = imem_sel_iw ? imem_dat_iw : 32'h00000013; // NOP on unmapped fetch
    assign iw_ack   = imem_sel_iw ? imem_ack_iw : unmapped_ack_iw;

    wb_dp_ram #(
    .DATA_WIDTH(32),
    .ADDR_WIDTH(16),   // 64 KiB window (2^16 bytes)
    .SELECT_WIDTH(4),  // 4 byte lanes for 32-bit bus
    .INIT_FILE("/home/artur/robot/fpga_platform/core/code/test.hex")

    ) imem (
    // ---- Port A : Instruction bus (RO) ----
    .a_clk  (clk),
    .a_adr_i(iw_adr[15:0]),                  // byte address; module handles lane shift
    .a_dat_i(32'b0),
    .a_dat_o(imem_dat_iw),
    .a_we_i (1'b0),                          // read-only on i-bus
    .a_sel_i(iw_sel != 4'b0000 ? iw_sel : 4'b1111),
    .a_stb_i(iw_stb & imem_sel_iw),
    .a_ack_o(imem_ack_iw),
    .a_cyc_i(iw_cyc),

    // ---- Port B : Data bus (RW) ----
    .b_clk  (clk),
    .b_adr_i(dw_adr[15:0]),
    .b_dat_i(dw_dat_m2s),
    .b_dat_o(imem_dat_dw),
    .b_we_i (dw_we),
    .b_sel_i(dw_sel),
    .b_stb_i(dw_stb & imem_sel_dw),
    .b_ack_o(imem_ack_dw),
    .b_cyc_i(dw_cyc)
    );

  
    // ============================================================
    // (Note) irq_to_cpu, msip, mtip are generated but not wired to CPU
    // The current cpu_bridge ties interrupts off internally as requested.
    // Hook them up later when you’re ready.
    // ============================================================

endmodule
