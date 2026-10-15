// In your sim_main.cpp
#include "Vtop.h"  // Your top module
#include "verilated.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtop* top = new Vtop;
    
    // Reset sequence
    top->reset = 1;
    for (int i = 0; i < 5; i++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    }
    top->reset = 0;
    
    // Run simulation
    for (int cycle = 0; cycle < 100; cycle++) {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        
        // Monitor PC and instruction
        if (top->cpu->iBus_cmd_valid) {
            printf("PC: %08x, Instr: %08x\n", 
                   top->cpu->iBus_cmd_payload_pc,
                   top->cpu->iBus_rsp_payload_inst);
        }
    }
    
    delete top;
    return 0;
}