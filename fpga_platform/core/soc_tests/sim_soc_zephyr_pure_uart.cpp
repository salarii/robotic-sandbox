// Verilator testbench: Zephyr SoC with pure UART console output.
// No JTAG / remote bitbang, no bus-transfer debug ring buffers, no wave tracing.
//
// Environment variables (optional):
//   SIM_TIMEOUT_CYCLES  stop after N clock cycles (0 / unset = run forever)
//
// Plusargs are passed to Verilated::commandArgs (e.g. +hex=...).

#include "Vsim_soc_zephyr.h"
#include "verilated.h"

#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>

static uint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int) { g_stop = 1; }

static Vsim_soc_zephyr *top = nullptr;

// ---------------------------------------------------------------------------
// UART snoop (prints bytes the CPU writes to the 16550 THR)
// ---------------------------------------------------------------------------
static bool uart_dlab = false;

static void uart_snoop() {
    if (!(top->dbg_dw_cyc && top->dbg_dw_stb && top->dbg_dw_ack)) return;
    if (!top->dbg_dw_we) return;

    uint32_t adr = top->dbg_dw_adr;
    if ((adr & ~0x1Fu) != 0x10000000u) return;

    uint32_t sel = top->dbg_dw_sel;
    // uart_wb in 32-bit mode: register = { adr[2], byte lane taken from sel }
    uint32_t lane = (sel & 1) ? 0 : (sel & 2) ? 1 : (sel & 4) ? 2 : 3;
    uint32_t reg  = (((adr >> 2) & 1) << 2) | lane;
    uint8_t  b    = (top->dbg_dw_dat_m2s >> (8 * lane)) & 0xFF;

    if (reg == 3) {                      // LCR: track DLAB bit
        uart_dlab = (b & 0x80) != 0;
    } else if (reg == 0 && !uart_dlab) { // THR write
        std::putchar(static_cast<char>(b));
        std::fflush(stdout);
    }
}

// ---------------------------------------------------------------------------
// Clock stepping
// ---------------------------------------------------------------------------
static uint64_t cycle = 0;

static inline void tick() {
    top->clk = 0;
    top->eval();
    main_time++;

    uart_snoop(); // Sample just before the rising edge

    top->clk = 1;
    top->eval();
    main_time++;
    cycle++;
}

static inline void ticks(unsigned n) {
    while (n--) tick();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    const char *e = std::getenv("SIM_TIMEOUT_CYCLES");
    uint64_t max_cycles = e ? std::strtoull(e, nullptr, 0) : 0;

    top = new Vsim_soc_zephyr;

    // Default static states for JTAG pins
    top->jtag_tck = 0;
    top->jtag_tms = 1;
    top->jtag_tdi = 0;

    // --- Reset Sequence ---
    top->rst = 1;
    top->debug_reset = 1;
    ticks(10);
    top->rst = 0;
    top->debug_reset = 0;

    std::cout << "Starting Zephyr SoC Simulation (Pure UART mode)..." << std::endl;

    while (!Verilated::gotFinish() && !g_stop) {
        tick();

        if (max_cycles > 0 && cycle >= max_cycles) {
            std::cout << "\n[Simulation timeout reached] cycles=" << cycle << std::endl;
            break;
        }
    }

    if (g_stop) {
        std::cout << "\n[Interrupted]" << std::endl;
    }

    top->final();
    delete top;
    return 0;
}