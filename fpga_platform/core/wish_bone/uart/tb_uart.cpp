// tb_uart.cpp
// Verilator testbench for an ns16550-compatible UART with Wishbone interface
// Assumes top-level module is named `uart_top` (class Vuart_top).
// If your top has a different name, adjust the include and the `using VTop = ...;`.
//
// Build (example):
//   verilator -cc --trace -O3 -CFLAGS "-std=c++17" \
//     -GREG_SHIFT=2 \
//     uart_top.v uart_wb.v uart_regs.v \
//     -exe tb_uart.cpp && \
//   make -C obj_dir -f Vuart_top.mk -j && \
//   ./obj_dir/Vuart_top
//
// Device-tree expectation this validates (4-byte stride):
//   compatible = "ns16550"; reg = <0x10000000 0x100>; reg-shift = <2>;
//   clock-frequency = <50000000>; current-speed = <115200>;
//
// What this test checks:
//   1) Wishbone access + 4-byte register spacing (reg-shift=2)
//   2) DLAB path to DLL/DLH and readback (divisor ~ 27 for 50 MHz / 115200)
//   3) Basic LCR/FCR/IIR sanity
//   4) THR write triggers TX activity (detect a start-bit falling edge)
//   5) Optional loopback via MCR[4] (if implemented) to receive the byte back

#include "Vuart_top.h"              // <--- adjust if your module/class is differently named
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cassert>
#include <cstdint>
#include <iostream>
#include <iomanip>
#include <string>

using VTop = Vuart_top;

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// ---------------------- ns16550 register offsets (with reg-shift=2) ----------------------
static constexpr uint32_t UART_RBR_THR_DLL = 0x00; // RBR (R) / THR (W) / DLL (DLAB=1)
static constexpr uint32_t UART_IER_DLH     = 0x04; // IER (DLAB=0) / DLH (DLAB=1)
static constexpr uint32_t UART_IIR_FCR     = 0x08; // IIR (R) / FCR (W)
static constexpr uint32_t UART_LCR         = 0x0C;
static constexpr uint32_t UART_MCR         = 0x10;
static constexpr uint32_t UART_LSR         = 0x14;
static constexpr uint32_t UART_MSR         = 0x18;
static constexpr uint32_t UART_SCR         = 0x1C;

// LSR bits
static constexpr uint8_t LSR_DR    = 1u << 0; // Data Ready
static constexpr uint8_t LSR_OE    = 1u << 1;
static constexpr uint8_t LSR_PE    = 1u << 2;
static constexpr uint8_t LSR_FE    = 1u << 3;
static constexpr uint8_t LSR_BI    = 1u << 4;
static constexpr uint8_t LSR_THRE  = 1u << 5; // THR Empty
static constexpr uint8_t LSR_TEMT  = 1u << 6; // Transmitter Empty
static constexpr uint8_t LSR_ERR   = 1u << 7;

// LCR bits
static constexpr uint8_t LCR_DLAB  = 1u << 7;

// MCR bits (16550): [4]=Loopback if implemented
static constexpr uint8_t MCR_LOOP  = 1u << 4;

// ---------------------- VCD + clock tick ----------------------
static inline void tick(VTop* top, VerilatedVcdC* tfp) {
    // rising edge
    top->wb_clk_i = 1;
    top->eval();
    if (tfp) tfp->dump(main_time++);
    // falling edge
    top->wb_clk_i = 0;
    top->eval();
    if (tfp) tfp->dump(main_time++);
}

// ---------------------- Wishbone BFM ----------------------
static inline void wb_idle(VTop* top) {
    top->wb_cyc_i = 0;
    top->wb_stb_i = 0;
    top->wb_we_i  = 0;
    top->wb_adr_i = 0;
    top->wb_dat_i = 0;
}

static inline void wb_write(VTop* top, VerilatedVcdC* tfp, uint32_t addr, uint32_t data, int max_wait = 1000) {
    top->wb_adr_i = addr;
    top->wb_dat_i = data;
    top->wb_we_i  = 1;
    top->wb_cyc_i = 1;
    top->wb_stb_i = 1;

    int w = 0;
    while (!top->wb_ack_o) {
        tick(top, tfp);
        if (++w > max_wait) {
            std::cerr << "WB write timeout @0x" << std::hex << addr << "\n";
            assert(false);
        }
    }
    // complete handshake cleanly
    wb_idle(top);
    tick(top, tfp);
}

static inline uint32_t wb_read(VTop* top, VerilatedVcdC* tfp, uint32_t addr, int max_wait = 1000) {
    top->wb_adr_i = addr;
    top->wb_we_i  = 0;
    top->wb_cyc_i = 1;
    top->wb_stb_i = 1;

    uint32_t val = 0;
    int w = 0;
    while (!top->wb_ack_o) {
        tick(top, tfp);
        if (++w > max_wait) {
            std::cerr << "WB read timeout @0x" << std::hex << addr << "\n";
            assert(false);
        }
    }
    // Sample data when ack is asserted
    val = top->wb_dat_o;
    // complete handshake
    wb_idle(top);
    tick(top, tfp);
    return val;
}

// ---------------------- Assertions helpers ----------------------
static inline void must_be(bool cond, const char* msg) {
    if (!cond) { std::cerr << "ASSERTION FAILED: " << msg << "\n"; assert(cond); }
}
static inline void warn_if(bool cond, const char* msg) {
    if (cond) { std::cerr << "WARNING: " << msg << "\n"; }
}

// ---------------------- Helpers ----------------------
static bool wait_tx_falling_edge(VTop* top, VerilatedVcdC* tfp, int max_cycles) {
    // UART TX idles high. Detect a transition 1 -> 0 (start bit).
    int prev = (top->stx_pad_o ? 1 : 0);
    for (int i = 0; i < max_cycles; ++i) {
        tick(top, tfp);
        int cur = (top->stx_pad_o ? 1 : 0);
        if (prev == 1 && cur == 0) return true;
        prev = cur;
    }
    return false;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    auto* top = new VTop;
    Verilated::traceEverOn(true);
    auto* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("uart_wave.vcd");

    // Tie-offs (RX idle=1). If your top has modem inputs (cts/dsr/dcd/ri), add them here.
    top->srx_pad_i = 1;

    // Reset
    wb_idle(top);
    top->wb_clk_i = 0;
    top->wb_rst_i = 1;

    for (int i = 0; i < 8; ++i) tick(top, tfp);
    top->wb_rst_i = 0;
    tick(top, tfp);

    // ---------------------- Test 0: Basic post-reset sanity ----------------------
    std::cout << "[RESET DONE]\n";
    uint32_t lsr0 = wb_read(top, tfp, UART_LSR);
    std::cout << "LSR after reset = 0x" << std::hex << std::setw(2) << std::setfill('0') << (lsr0 & 0xFF) << std::dec << "\n";
    // Many 16550s come up THRE=1 and TEMT=1; warn if not, but don't fail.
    warn_if(((lsr0 & LSR_THRE) == 0), "LSR.THRE is 0 after reset (ok for some variants)");
    warn_if(((lsr0 & LSR_TEMT) == 0), "LSR.TEMT is 0 after reset (ok for some variants)");

    // ---------------------- Test 1: reg-shift (4-byte spacing) using SCR read/write ----------------------
    std::cout << "[TEST 1] SCR read/write (stride sanity)\n";
    wb_write(top, tfp, UART_SCR, 0xA5);
    uint32_t scr = wb_read(top, tfp, UART_SCR);
    std::cout << "SCR = 0x" << std::hex << (scr & 0xFF) << std::dec << "\n";
    must_be((scr & 0xFF) == 0xA5, "SCR readback mismatch (check reg-shift=2 and address decode)");

    // ---------------------- Test 2: DLAB path + divisor program ----------------------
    std::cout << "[TEST 2] DLAB + DLL/DLH program\n";
    // Set DLAB=1 in LCR to access DLL/DLH
    wb_write(top, tfp, UART_LCR, LCR_DLAB);
    // For 50 MHz and 115200 baud, divisor ~= 27 (50e6/(16*115200) = 27.1267)
    const uint32_t dll = 27;
    const uint32_t dlh = 0;
    wb_write(top, tfp, UART_RBR_THR_DLL, dll);
    wb_write(top, tfp, UART_IER_DLH,     dlh);
    // Read back
    uint32_t dll_rb = wb_read(top, tfp, UART_RBR_THR_DLL) & 0xFF;
    uint32_t dlh_rb = wb_read(top, tfp, UART_IER_DLH)     & 0xFF;
    std::cout << "DLL=" << dll_rb << " DLH=" << dlh_rb << "\n";
    must_be(dll_rb == dll, "DLL readback mismatch");
    must_be(dlh_rb == dlh, "DLH readback mismatch");

    // Clear DLAB, set 8N1 (0x03)
    wb_write(top, tfp, UART_LCR, 0x03);
    uint32_t lcr = wb_read(top, tfp, UART_LCR) & 0xFF;
    must_be(lcr == 0x03, "LCR readback mismatch (expect 0x03 = 8N1)");

    // ---------------------- Test 3: FIFO enable + IIR sanity ----------------------
    std::cout << "[TEST 3] FIFO/IIR sanity\n";
    // Write FCR (enable FIFO = bit0). FCR is write-only; IIR[7:6] reflect FIFO status on many cores.
    wb_write(top, tfp, UART_IIR_FCR, 0x01);
    uint32_t iir = wb_read(top, tfp, UART_IIR_FCR) & 0xFF;
    std::cout << "IIR = 0x" << std::hex << iir << std::dec << "\n";
    // Bit0==1 -> no interrupt pending; bits7:6 FIFO enabled indicator often == 0b11
    warn_if((iir & 0x01) == 0, "IIR bit0 indicates interrupt pending unexpectedly");
    warn_if(((iir >> 6) == 0), "IIR[7:6] do not indicate FIFO enabled (may be ok for your core)");

    // ---------------------- Test 4: Transmit a byte and detect start bit ----------------------
    std::cout << "[TEST 4] TX activity on THR write\n";
    // Informative read of LSR
    uint32_t lsr1 = wb_read(top, tfp, UART_LSR) & 0xFF;
    std::cout << "LSR before TX = 0x" << std::hex << lsr1 << std::dec << "\n";
    // Write 'U' (0x55) to THR
    wb_write(top, tfp, UART_RBR_THR_DLL, 0x55);
    // After writing THR, we expect TX line to go low for start bit within some cycles
    bool saw_fall = wait_tx_falling_edge(top, tfp, /*max_cycles*/ 50000);
    must_be(saw_fall, "Did not observe TX start bit (check divisor/clocking)");
    // Allow some cycles for transmitter to run
    for (int i = 0; i < 2000; ++i) tick(top, tfp);

    // ---------------------- Test 5 (optional): Loopback via MCR[4] ----------------------
    std::cout << "[TEST 5] Optional loopback (MCR[4])\n";
    // Try to enable internal loopback; if not implemented, this may be a no-op.
    wb_write(top, tfp, UART_MCR, MCR_LOOP);
    // Write another byte
    wb_write(top, tfp, UART_RBR_THR_DLL, 0xA6);
    // Wait until Data Ready (LSR[0]) or timeout
    bool got_dr = false;
    for (int i = 0; i < 200000; ++i) {
        uint32_t lsr = wb_read(top, tfp, UART_LSR) & 0xFF;
        if (lsr & LSR_DR) { got_dr = true; break; }
    }
    if (got_dr) {
        uint32_t rxd = wb_read(top, tfp, UART_RBR_THR_DLL) & 0xFF;
        std::cout << "RX (loopback) got 0x" << std::hex << rxd << std::dec << "\n";
        must_be(rxd == 0xA6, "Loopback received byte mismatch");
    } else {
        std::cout << "Loopback not observed (MCR[4] unsupported or needs external wiring). Skipping.\n";
    }

    std::cout << "\nAll UART tests completed ✅\n";

    tfp->close();
    delete tfp;
    delete top;
    return 0;
}
