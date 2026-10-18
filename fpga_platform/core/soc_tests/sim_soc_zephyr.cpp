#include "Vsim_soc_zephyr.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <cstdlib>

static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

int main(int argc, char **argv) {
    // Pass args to verilated to support +hex=file.hex 
    Verilated::commandArgs(argc, argv);
    
    // Parse an optional cycle limit from environment variable (0 = infinite)
    const char* timeout_env = std::getenv("SIM_TIMEOUT_CYCLES");
    uint64_t max_cycles = timeout_env ? std::stoull(timeout_env) : 0;

    Vsim_soc_zephyr *top = new Vsim_soc_zephyr;

    // Setup waveform generation
    Verilated::traceEverOn(true);
    VerilatedVcdC *tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("wave.vcd");

    // Initialization & Reset Sequence
    top->rst = 1;
    top->jtag_tms = 1;
    top->jtag_tdi = 0;
    top->jtag_tck = 0;
    top->debug_reset = 1;

    for (int i = 0; i < 10; i++) {
        top->clk = 0; top->eval(); tfp->dump(main_time++);
        top->clk = 1; top->eval(); tfp->dump(main_time++);
    }

    // Release reset
    top->rst = 0;
    top->debug_reset = 0;

    std::cout << "Starting Zephyr SoC Simulation..." << std::endl;

    uint64_t cycle = 0;
    
    // Main simulation loop
    while (!Verilated::gotFinish()) {
        top->clk = 0;
        top->eval();
        tfp->dump(main_time++);

        // SNOOP THE WISHBONE BUS FOR UART WRITES
        // A write completes when cyc, stb, we, and ack are all high.
        if (top->dbg_dw_cyc && top->dbg_dw_stb && top->dbg_dw_we && top->dbg_dw_ack) {
            
            // The UART is mapped to 0x10000000. 
            // The Transmit Holding Register (THR) is at offset 0.
            if (top->dbg_dw_adr == 0x10000000) {
                // Extract the lowest byte and print it immediately
                char c = static_cast<char>(top->dbg_dw_dat_m2s & 0xFF);
                std::putchar(c);
                std::fflush(stdout); 
            }
        }

        top->clk = 1;
        top->eval();
        tfp->dump(main_time++);

        cycle++;
        
        // Enforce finite execution if requested
        if (max_cycles > 0 && cycle >= max_cycles) {
            std::cout << "\n[Simulation timeout reached: " << max_cycles << " cycles]" << std::endl;
            break;
        }
    }

    tfp->close();
    delete tfp;
    delete top;
    return 0;
}