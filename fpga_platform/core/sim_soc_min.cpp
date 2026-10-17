#include "Vsim_soc_min.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdint>
#include <cstdio>
#include <iostream>

static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// Expected store sequence (program loops forever, so it repeats)
struct ExpWrite { uint32_t addr; uint32_t data; };
static const ExpWrite EXPECTED[3] = {
    {0x10000000u, 42u},    // sw ra,0(a0)
    {0x10000004u, 100u},   // sw sp,4(a0)
    {0x10000008u, 142u},   // sw gp,8(a0)
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    // Enable tracing
    Verilated::traceEverOn(true);
    Vsim_soc_min *top = new Vsim_soc_min;

    VerilatedVcdC *tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("wave.vcd");

    // Simple tracking for data memory writes
    uint32_t tracked_memory[64] = {0};

    // Sanity-check state
    int write_count = 0;
    int errors      = 0;

    // Reset sequence
    top->rst = 1;
    top->jtag_tms = 1;
    top->jtag_tdi = 0;
    top->jtag_tck = 0;
    top->debug_reset = 1;

    // Tick clock during reset
    for (int i = 0; i < 10; i++) {
        top->clk = 0; top->eval(); tfp->dump(main_time++);
        top->clk = 1; top->eval(); tfp->dump(main_time++);
    }

    // Release reset
    top->rst = 0;
    top->debug_reset = 0;

    std::cout << "Starting Wishbone SoC Simulation..." << std::endl;

    // Simulation loop (run for 200 cycles)
    for (int cycle = 0; cycle < 200; cycle++) {
        // Clock low
        top->clk = 0;
        top->eval();
        tfp->dump(main_time++);

        // ---- Sanity monitor ----
        // Sampled while clk is low, i.e. the values the next rising edge will
        // capture. A write completes when cyc & stb & we & ack are all high.
        if (top->dbg_dw_cyc && top->dbg_dw_stb && top->dbg_dw_we && top->dbg_dw_ack) {
            uint32_t addr = top->dbg_dw_adr;
            uint32_t data = top->dbg_dw_dat_m2s;
            uint32_t sel  = top->dbg_dw_sel;

            std::printf("[cycle %3d] WRITE addr=0x%08X data=0x%08X sel=0x%X\n",
                        cycle, addr, data, sel);

            // Track in local memory (only data RAM region)
            if ((addr >> 16) == 0x1000) {
                uint32_t idx = (addr & 0xFFFF) >> 2;
                if (idx < 64) tracked_memory[idx] = data;
            }

            // Check against expected sequence
            const ExpWrite &e = EXPECTED[write_count % 3];
            if (addr != e.addr || data != e.data) {
                std::printf("  ERROR: expected addr=0x%08X data=0x%08X\n",
                            e.addr, e.data);
                errors++;
            }
            if (sel != 0xF) {
                std::printf("  ERROR: expected sel=0xF for sw, got 0x%X\n", sel);
                errors++;
            }
            write_count++;
        }

        // Clock high
        top->clk = 1;
        top->eval();
        tfp->dump(main_time++);

        if (Verilated::gotFinish()) break;
    }

    std::cout << "Simulation finished." << std::endl;

    // ---- Final checks ----
    if (write_count < 3) {
        std::printf("ERROR: only %d writes seen, expected at least 3\n", write_count);
        errors++;
    }
    if (tracked_memory[0] != 42 || tracked_memory[1] != 100 || tracked_memory[2] != 142) {
        std::printf("ERROR: tracked memory wrong: [0]=%u [1]=%u [2]=%u (want 42,100,142)\n",
                    tracked_memory[0], tracked_memory[1], tracked_memory[2]);
        errors++;
    }

    std::printf("\n%d writes observed, %d errors -> %s\n",
                write_count, errors, errors ? "FAIL" : "PASS");

    tfp->close();
    delete tfp;
    delete top;
    return errors ? 1 : 0;
}