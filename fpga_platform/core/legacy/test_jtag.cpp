#include "VVexRiscv.h"
#include "verilated.h"
#include <fstream>
#include <iostream>

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// Debug state machine
typedef enum {
    DEBUG_IDLE,
    DEBUG_SEND_HALT,
    DEBUG_WAIT_HALT_ACK,
    DEBUG_READ_STATUS,
    DEBUG_WAIT_STATUS,
    DEBUG_HALTED
} DebugState;

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    VVexRiscv* top = new VVexRiscv;

    // Instruction ROM & simple data memory
    uint32_t rom[256] = {0};
    uint32_t memory[256] = {0};

    // Load test program into ROM
    std::ifstream fin("/home/artur/development/core_sim/test.bin", std::ios::binary);
    if (fin) {
        fin.read((char*)rom, sizeof(rom));
        std::cout << "[+] Loaded test.bin program\n";
    } else {
        std::cerr << "Error: Could not open test.bin" << std::endl;
        return 1;
    }

    // Reset + clock init
    top->reset = 1;
    top->clk = 0;
    top->debug_bus_cmd_valid = 0;
    top->debug_bus_cmd_payload_wr = 0;
    top->debug_bus_cmd_payload_address = 0;
    top->debug_bus_cmd_payload_data = 0;
    top->debug_resetOut = 0;

    // Reset sequence (10 cycles)
    for (int i = 0; i < 10; i++) {
        top->clk = !top->clk;
        top->eval();
        main_time++;
    }
    top->reset = 0;

    // Simulation variables
    bool next_valid = false;
    uint32_t next_inst = 0;
    uint32_t pc_prev = 0;
    bool pc_halted = false;
    const uint32_t halt_cycle = 30;
    
    // Debug state machine
    DebugState debug_state = DEBUG_IDLE;
    bool cpu_halted = false;
    bool debug_halt_requested = false;
    uint32_t debug_retry_count = 0;
    const uint32_t MAX_RETRIES = 10;

    // Simulation loop
    for (int cycle = 0; cycle < 200; cycle++) {
        // --------------------- FALLING EDGE ---------------------
        top->clk = 0;
        
        // Update debug signals based on current state
        switch (debug_state) {
            case DEBUG_IDLE:
                if (cycle >= halt_cycle && !debug_halt_requested) {
                    debug_halt_requested = true;
                    debug_state = DEBUG_SEND_HALT;
                }
                break;
                
            case DEBUG_SEND_HALT:
                // Set halt command
                top->debug_bus_cmd_valid = 1;
                top->debug_bus_cmd_payload_wr = 1;
                top->debug_bus_cmd_payload_address = 0x10;  // DMCONTROL
                top->debug_bus_cmd_payload_data = 0x80000001; // dmactive + haltreq
                break;
                
            case DEBUG_WAIT_HALT_ACK:
                // Clear command after acceptance
                top->debug_bus_cmd_valid = 0;
                break;
                
            case DEBUG_READ_STATUS:
                // Set status read command
                top->debug_bus_cmd_valid = 1;
                top->debug_bus_cmd_payload_wr = 0;
                top->debug_bus_cmd_payload_address = 0x11;  // DMSTATUS
                break;
                
            case DEBUG_WAIT_STATUS:
                // Maintain status read command until accepted
                break;
                
            case DEBUG_HALTED:
                // Keep debug interface quiet
                top->debug_bus_cmd_valid = 0;
                break;
        }
        
        // Instruction bus response
        top->iBus_rsp_valid = next_valid;
        top->iBus_rsp_payload_inst = next_inst;
        top->iBus_rsp_payload_error = 0;
        top->iBus_cmd_ready = 1;
        next_valid = false;
        
        // Fetch next instruction
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
        
        // Handle memory writes
        if (top->dBus_cmd_valid && top->dBus_cmd_ready && top->dBus_cmd_payload_wr) {
            uint32_t addr = top->dBus_cmd_payload_address;
            uint32_t data = top->dBus_cmd_payload_data;
            uint32_t index = (addr - 0x10000000) >> 2;
            
            if (addr >= 0x10000000 && addr < 0x10000100) {
                memory[index] = data;
                std::cout << "Cycle " << cycle << ": MEM WRITE @0x" 
                          << std::hex << addr << " = 0x" << data << std::dec << "\n";
            }
        }
        
        top->eval();
        
        // --------------------- RISING EDGE ---------------------
        top->clk = 1;
        top->eval();
        main_time++;
        
        // Get current PC and print
        uint32_t pc = top->iBus_cmd_payload_pc;
        printf("Cycle %3d: PC = 0x%08x\n", cycle, pc);
        
        // Update debug state machine
        switch (debug_state) {
            case DEBUG_SEND_HALT:
                if (top->debug_bus_cmd_ready) {
                    printf("[*] Halt command accepted at cycle %d\n", cycle);
                    debug_state = DEBUG_WAIT_HALT_ACK;
                }
                break;
                
            case DEBUG_WAIT_HALT_ACK:
                // Wait 1 cycle after command acceptance
                debug_state = DEBUG_READ_STATUS;
                printf("[*] Reading DMSTATUS at cycle %d\n", cycle);
                break;
                
            case DEBUG_READ_STATUS:
                debug_state = DEBUG_WAIT_STATUS;
                break;
                
            case DEBUG_WAIT_STATUS:
                if (top->debug_bus_cmd_ready) {
                    uint32_t status = top->debug_bus_rsp_data;
                    printf("DMSTATUS: 0x%08x\n", status);
                    
                    // Check allhalted bit (bit 9)
                    if (status & (1 << 5)) {
                        cpu_halted = true;
                        debug_state = DEBUG_HALTED;
                        printf("[✓] CPU fully halted (cycle %d)\n", cycle);
                    } else {
                        debug_retry_count++;
                        if (debug_retry_count < MAX_RETRIES) {
                            debug_state = DEBUG_READ_STATUS;
                            printf("[.] Retrying status read (%d/%d)\n", 
                                   debug_retry_count, MAX_RETRIES);
                        } else {
                            printf("[!] Halt failed after %d retries\n", MAX_RETRIES);
                            debug_state = DEBUG_HALTED;
                        }
                    }
                }
                break;
                
            default:
                // Other states require no action
                break;
        }
        
        // Simple PC-based halt detection
        if (!pc_halted && cycle > halt_cycle + 5) {
            if (pc == pc_prev) {
                std::cout << "[✓] PC stabilized at 0x" << std::hex << pc << std::dec 
                          << " (cycle " << cycle << ")\n";
                pc_halted = true;
            }
            pc_prev = pc;
        }
        
        // Exit early if both methods confirm halt
        if (cpu_halted && pc_halted && cycle > halt_cycle + 10) {
            printf("[+] Success: CPU fully halted and PC stabilized\n");
            break;
        }
    }

    delete top;
    return 0;
}