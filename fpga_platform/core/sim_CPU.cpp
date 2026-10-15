#include "VVexRiscv.h"
#include "verilated.h"
#include <fstream>
#include <iostream>

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    VVexRiscv* top = new VVexRiscv;
    uint32_t rom[256] = {0};
    uint32_t memory[256] = {0}; // Simple memory for monitoring

    // Load test program
    std::ifstream fin("test.bin", std::ios::binary);
    if (fin) {
        fin.read((char*)rom, sizeof(rom));
    } else {
        std::cerr << "Error: Could not open test.bin" << std::endl;
        return 1;
    }

    bool next_valid = false;
    uint32_t next_inst = 0;

    // Reset sequence
    top->reset = 1;
    for (int i = 0; i < 5; i++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }
    top->reset = 0;

    // Simulation loop
    for (int cycle = 0; cycle < 100; cycle++) {
        top->clk = 0;
        top->eval();

        // Instruction memory response
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

        top->clk = 1;
        top->eval();
    }

    delete top;
    return 0;
}