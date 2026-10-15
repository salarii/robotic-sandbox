#include "VVexRiscv.h"
#include "verilated.h"
#include "verilated_vcd_c.h"   // <-- VCD tracing
#include <fstream>
#include <iostream>

static vluint64_t main_time = 0;           // Verilator time, in "ticks"
double sc_time_stamp() { return main_time; } // For some older DPI users

// helper: tick clock (0->1) with tracing
static inline void tick(VVexRiscv* top, VerilatedVcdC* tfp) {
    // falling edge
    top->clk = 0;
    top->eval();
    if (tfp) tfp->dump(main_time);
    main_time++;

    // rising edge
    top->clk = 1;
    top->eval();
    if (tfp) tfp->dump(main_time);
    main_time++;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    // Enable tracing BEFORE model creation
    Verilated::traceEverOn(true);
    VVexRiscv* top = new VVexRiscv;

    // Set up VCD
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);            // trace depth
    tfp->open("wave.vcd");

    uint32_t rom[256] = {0};
    uint32_t memory[256] = {0}; // Simple memory for monitoring

    // Load test program
    std::ifstream fin("test.bin", std::ios::binary);
    if (fin) {
        fin.read((char*)rom, sizeof(rom));
    } else {
        std::cerr << "Error: Could not open test.bin" << std::endl;
        tfp->close();
        delete tfp;
        delete top;
        return 1;
    }

    bool next_valid = false;
    uint32_t next_inst = 0;

    // Reset sequence
    top->reset = 1;
    for (int i = 0; i < 5; i++) tick(top, tfp);
    top->reset = 0;

    // Simulation loop
    for (int cycle = 0; cycle < 100; cycle++) {
        // Combinational @low phase work (between edges)
        top->iBus_rsp_valid = next_valid;
        top->iBus_rsp_payload_inst = next_inst;
        top->iBus_rsp_payload_error = 0;
        top->iBus_cmd_ready = 1;

        next_valid = false;
        if (top->iBus_cmd_valid) {
            uint32_t pc = top->iBus_cmd_payload_pc;
            uint32_t index = (pc - 0x80000000) >> 2;
            if (index < 256) {
                next_inst = rom[index];
                next_valid = true;
            }
        }

        // Data memory handling
        top->dBus_cmd_ready = 1;
        top->dBus_rsp_ready = 1;
        top->dBus_rsp_error = 0;

        if (top->dBus_cmd_valid && top->dBus_cmd_ready) {
            if (top->dBus_cmd_payload_wr) {
                // Memory write
                uint32_t addr = top->dBus_cmd_payload_address;
                uint32_t data = top->dBus_cmd_payload_data;
                uint32_t index = (addr - 0x10000000) >> 2;

                // Monitor writes to our special address range
                if (addr >= 0x10000000 && addr < 0x10000100) {
                    memory[index] = data;
                    printf("CYC %2d: MEM WRITE @%08x = %08x (x1=%d, x2=%d, x3=%d)\n",
                           cycle, addr, data, memory[0], memory[1], memory[2]);
                }
            }
        }

        // Advance one full cycle with tracing
        tick(top, tfp);
        if (Verilated::gotFinish()) break;
    }

    tfp->close();
    delete tfp;
    delete top;
    return 0;
}
