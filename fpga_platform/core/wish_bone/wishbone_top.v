`timescale 1ns/1ps
`default_nettype none

// ============================================================================
// Real-hardware top for the VexRiscv SoC.
//
// Memory map (must match the Zephyr DTS and sim_soc_zephyr.v):
//   0x10000000  UART 16550   (64 KB window, 32-bit mode, reg-shift 0)
//   0x20000000  RAM          (64 KB)
//   0x30000000  I2C          (SiFive-compatible, 256 B used, 64 KB window)
//   0x40000000  Watchdog     (64 KB window)
//   0x50000000  PLIC         (4 MB window)
//   0x60000000  CLINT        (64 KB window)
//   0x80000000  IMEM/ROM     (64 KB, dual-port: instruction + data)
//
// PLIC interrupt IDs (must match the DTS; ID = bit index + 1):
//   ID 1 = watchdog, ID 5 = UART, ID 6 = I2C
//
// I2C pins:
//   i2c_scl / i2c_sda are open-drain INOUT pads. The core only ever drives
//   them low (or releases them); the line goes high through EXTERNAL pull-up
//   resistors (typically 4.7k to 3.3V). In your constraints file:
//     - assign the two pins to real I/O pins with the correct I/O standard
//     - do NOT rely on the FPGA internal pull-up (too weak/slow for I2C)
//   Inputs are passed through a 2-flop synchronizer before the controller
//   sees them (the bus is asynchronous to the system clock).
// ============================================================================

module wishbone_top #(
    parameter IMEM_INIT_FILE = ""
) (
    input  wire clk,
    input  wire rst,

    // ---- JTAG (exposed) ----
    input  wire jtag_tms,
    input  wire jtag_tdi,
    output wire jtag_tdo,
    input  wire jtag_tck,
    input  wire debug_reset,   // forwarded to VexRiscv

    // ---- UART pins ----
    output wire stx_pad_o,
    input  wire srx_pad_i,
    output wire rts_pad_o,
    input  wire cts_pad_i,   // currently ignored internally (kept for pinout)
    output wire dtr_pad_o,
    input  wire dsr_pad_i,   // currently ignored internally (kept for pinout)
    input  wire ri_pad_i,    // currently ignored internally (kept for pinout)
    input  wire dcd_pad_i,   // currently ignored internally (kept for pinout)

    // ---- I2C pins (open-drain, external pull-ups required) ----
    inout  wire i2c_scl,
    inout  wire i2c_sda
);

    // ============================================================
    // Signals
    // ============================================================
    // Instruction master (read-only)
    wire        iw_cyc, iw_stb, iw_we;
    wire [31:0] iw_adr;
    wire [31:0] iw_dat_o;      // unused (read-only)
    wire [3:0]  iw_sel;
    wire [31:0] iw_dat_i;
    wire        iw_ack;

    // Data master (read/write)
    wire        dw_cyc, dw_stb, dw_we;
    wire [31:0] dw_adr;
    wire [31:0] dw_dat_m2s;
    wire [3:0]  dw_sel;
    wire [31:0] dw_dat_s2m;
    wire        dw_ack;

    // Resets
    wire ndmreset;
    wire rst_sys = rst | ndmreset;

    // Interrupts
    wire irq_to_cpu;           // PLIC  -> CPU external interrupt
    wire msip;                 // CLINT -> CPU software interrupt
    wire mtip;                 // CLINT -> CPU timer interrupt
    wire uart_irq;
    wire watchdog_irq;
    wire i2c_irq;
    // PLIC source index = ID - 1
    //   [0] watchdog (ID 1), [4] UART (ID 5), [5] I2C (ID 6)
    wire [7:0] irq_sources = {2'd0, i2c_irq, uart_irq, 3'd0, watchdog_irq};

    // ============================================================
    // CPU bridge -> two Wishbone masters (instruction & data)
    // ============================================================
    simple_to_wishbone cpu_bridge (
        .clk(clk),
        .rst(rst_sys),

        // ---- JTAG pass-through ----
        .jtag_tms   (jtag_tms),
        .jtag_tdi   (jtag_tdi),
        .jtag_tdo   (jtag_tdo),
        .jtag_tck   (jtag_tck),
        .debug_reset(debug_reset),

        // ---- Interrupts ----
        .timerInterrupt   (mtip),
        .softwareInterrupt(msip),
        .externalInterrupt(irq_to_cpu),

        // ---- ndmreset out ----
        .ndmreset   (ndmreset),

        // Instruction WB master (read-only)
        .iw_cyc_o(iw_cyc), .iw_stb_o(iw_stb), .iw_we_o(iw_we),
        .iw_adr_o(iw_adr), .iw_dat_o(iw_dat_o), .iw_sel_o(iw_sel),
        .iw_dat_i(iw_dat_i), .iw_ack_i(iw_ack),

        // Data WB master (read/write)
        .dw_cyc_o(dw_cyc), .dw_stb_o(dw_stb), .dw_we_o(dw_we),
        .dw_adr_o(dw_adr), .dw_dat_o(dw_dat_m2s), .dw_sel_o(dw_sel),
        .dw_dat_i(dw_dat_s2m), .dw_ack_i(dw_ack)
    );

    // ============================================================
    // DATA BUS interconnect
    // ============================================================
    wire uart_sel     = (dw_adr[31:16] == 16'h1000);
    wire ram_sel      = (dw_adr[31:16] == 16'h2000);
    wire i2c_sel      = (dw_adr[31:16] == 16'h3000);
    wire watchdog_sel = (dw_adr[31:16] == 16'h4000);
    wire plic_sel     = (dw_adr[31:22] == 10'h140);   // 0x50000000, 4 MB
    wire clint_sel    = (dw_adr[31:16] == 16'h6000);
    wire imem_sel_dw  = (dw_adr[31:16] == 16'h8000);

    wire        uart_ack, ram_ack, i2c_ack, watchdog_ack, plic_ack, clint_ack, imem_ack_dw;
    wire [31:0] uart_dat_o, ram_dat_o, i2c_dat_o, watchdog_dat_o, plic_dat_o, clint_dat_o, imem_dat_dw;

    assign dw_dat_s2m = uart_sel     ? uart_dat_o     :
                        imem_sel_dw  ? imem_dat_dw    :
                        ram_sel      ? ram_dat_o      :
                        i2c_sel      ? i2c_dat_o      :
                        watchdog_sel ? watchdog_dat_o :
                        plic_sel     ? plic_dat_o     :
                        clint_sel    ? clint_dat_o    :
                        32'd0;

    // Unmapped data accesses get a one-cycle ack so the CPU never hangs
    wire any_sel_dw = uart_sel | imem_sel_dw | ram_sel | i2c_sel |
                      watchdog_sel | plic_sel | clint_sel;
    reg  unmapped_ack_dw;
    always @(posedge clk or posedge rst_sys) begin
        if (rst_sys)
            unmapped_ack_dw <= 1'b0;
        else
            unmapped_ack_dw <= (dw_cyc & dw_stb & ~any_sel_dw) & ~unmapped_ack_dw;
    end

    assign dw_ack = (uart_sel     & uart_ack)
                  | (imem_sel_dw  & imem_ack_dw)
                  | (ram_sel      & ram_ack)
                  | (i2c_sel      & i2c_ack)
                  | (watchdog_sel & watchdog_ack)
                  | (plic_sel     & plic_ack)
                  | (clint_sel    & clint_ack)
                  | unmapped_ack_dw;

    // ---------------- Peripherals on the data bus ----------------
    uart_top uart_inst (
        .wb_clk_i(clk), .wb_rst_i(rst_sys), .wb_adr_i(dw_adr[4:0]),
        .wb_dat_i(dw_dat_m2s), .wb_dat_o(uart_dat_o),
        .wb_we_i(dw_we), .wb_stb_i(dw_stb & uart_sel),
        .wb_cyc_i(dw_cyc), .wb_ack_o(uart_ack), .wb_sel_i(dw_sel),
        .int_o(uart_irq),

        .stx_pad_o(stx_pad_o), .srx_pad_i(srx_pad_i),

        // Modem pins hard-wired: CTS/DSR/DCD asserted, no ring
        .rts_pad_o(),
        .cts_pad_i(1'b1),
        .dtr_pad_o(),
        .dsr_pad_i(1'b1),
        .ri_pad_i (1'b0),
        .dcd_pad_i(1'b1)
    );
    assign rts_pad_o = 1'b1;  // Request To Send asserted
    assign dtr_pad_o = 1'b1;  // Data Terminal Ready asserted

    wb_ram #(
        .DATA_WIDTH(32), .ADDR_WIDTH(16), .SELECT_WIDTH(4)
    ) ram_inst (
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

    // PLIC expects offsets (0x000000 .. 0x3FFFFF) within its 4 MB window
    wishbone_plic plic_inst (
        .clk(clk), .rst(rst_sys),
        .wb_cyc_i(dw_cyc), .wb_stb_i(dw_stb & plic_sel), .wb_we_i(dw_we),
        .wb_adr_i({10'd0, dw_adr[21:0]}), .wb_dat_i(dw_dat_m2s), .wb_dat_o(plic_dat_o),
        .wb_ack_o(plic_ack), .irq_sources(irq_sources), .irq_to_cpu(irq_to_cpu)
    );

    // CLINT expects offsets (0x0000 .. 0xFFFF) within its 64 KB window
    clint clint_inst (
        .clk(clk), .rst(rst_sys),
        .wb_cyc_i(dw_cyc), .wb_stb_i(dw_stb & clint_sel), .wb_we_i(dw_we),
        .wb_adr_i({16'd0, dw_adr[15:0]}), .wb_dat_i(dw_dat_m2s), .wb_dat_o(clint_dat_o),
        .wb_ack_o(clint_ack), .msip(msip), .mtip(mtip)
    );

    // ============================================================
    // I2C controller (SiFive register map, as used by Zephyr)
    // ============================================================
    wire i2c_sda_o, i2c_sda_oe;
    wire i2c_scl_o, i2c_scl_oe;
    wire i2c_sda_i, i2c_scl_i;     // synchronized pad values

    i2c_sifive_wb i2c_inst (
        .wb_clk_i(clk),
        .wb_rst_i(rst_sys),
        .wb_adr_i(dw_adr),
        .wb_dat_i(dw_dat_m2s),
        .wb_dat_o(i2c_dat_o),
        .wb_we_i(dw_we),
        .wb_stb_i(dw_stb & i2c_sel),
        .wb_cyc_i(dw_cyc),
        .wb_ack_o(i2c_ack),
        .wb_int_o(i2c_irq),

        .sda_i (i2c_sda_i),
        .sda_o (i2c_sda_o),
        .sda_oe(i2c_sda_oe),
        .scl_i (i2c_scl_i),
        .scl_o (i2c_scl_o),
        .scl_oe(i2c_scl_oe)
    );

    // Open-drain pad drivers: drive the value (always 0 in this core) when
    // output-enable is set, otherwise release the line (high-Z -> pull-up).
    assign i2c_sda = i2c_sda_oe ? i2c_sda_o : 1'bz;
    assign i2c_scl = i2c_scl_oe ? i2c_scl_o : 1'bz;

    // 2-flop synchronizers for the asynchronous pad inputs.
    // Reading the pad while we drive it low correctly returns 0 (wired-AND),
    // and a slave pulling SCL low (clock stretching) is seen the same way.
    reg [1:0] sda_sync, scl_sync;
    always @(posedge clk) begin
        sda_sync <= {sda_sync[0], i2c_sda};
        scl_sync <= {scl_sync[0], i2c_scl};
    end
    assign i2c_sda_i = sda_sync[1];
    assign i2c_scl_i = scl_sync[1];

    // ============================================================
    // INSTRUCTION BUS (ROM, read-only)
    // ============================================================
    wire        imem_sel_iw = (iw_adr[31:16] == 16'h8000);
    wire [31:0] imem_dat_iw;
    wire        imem_ack_iw;

    // Unmapped fetches get a one-cycle ack and a NOP
    reg unmapped_ack_iw;
    always @(posedge clk or posedge rst_sys) begin
        if (rst_sys)
            unmapped_ack_iw <= 1'b0;
        else
            unmapped_ack_iw <= (iw_cyc & iw_stb & ~imem_sel_iw) & ~unmapped_ack_iw;
    end

    assign iw_dat_i = imem_sel_iw ? imem_dat_iw : 32'h00000013;
    assign iw_ack   = imem_sel_iw ? imem_ack_iw : unmapped_ack_iw;

    wb_dp_ram #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(16),     // 64 KiB window
        .SELECT_WIDTH(4),
        .INIT_FILE(IMEM_INIT_FILE)
    ) imem (
        // ---- Port A: instruction bus (read-only) ----
        .a_clk  (clk),
        .a_adr_i(iw_adr[15:0]),
        .a_dat_i(32'b0),
        .a_dat_o(imem_dat_iw),
        .a_we_i (1'b0),
        .a_sel_i(iw_sel != 4'b0000 ? iw_sel : 4'b1111),
        .a_stb_i(iw_stb & imem_sel_iw),
        .a_ack_o(imem_ack_iw),
        .a_cyc_i(iw_cyc),

        // ---- Port B: data bus (read/write) ----
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

endmodule
`default_nettype wire