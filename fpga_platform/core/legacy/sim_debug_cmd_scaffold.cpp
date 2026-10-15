#include "Vdebug_cmd_scaffold.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

void tick(Vdebug_cmd_scaffold *dut, VerilatedVcdC *tfp) {
    dut->clk = 0; dut->eval(); tfp->dump(main_time++);
    dut->clk = 1; dut->eval(); tfp->dump(main_time++);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vdebug_cmd_scaffold *dut = new Vdebug_cmd_scaffold;
    Verilated::traceEverOn(true);
    VerilatedVcdC *tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("debug_cmd_scaffold.vcd");

    // Reset
    dut->reset = 1; dut->dr_packet_valid = 0; dut->cpu_cmd_ready = 0; 
    tick(dut, tfp);
    dut->reset = 0;
    tick(dut, tfp);

    // Issue 3 commands, properly handshake each
    for (int i = 0; i < 3; ++i) {
        // 1. Present command
        dut->dr_packet_valid = 1;
        // Compose packet: [40]=wr, [39:32]=address, [31:0]=data
        dut->dr_packet = (0ull << 40) | (0x55ull << 32) | (i+1); // wr=0 (read), address=0x55, data=i+1
        tick(dut, tfp);

        // 2. Remove dr_packet_valid (simulate "pulse")
        dut->dr_packet_valid = 0;
        tick(dut, tfp);

        // 3. Wait for cpu_cmd_valid to go high (command is unpacked and ready for CPU)
        int wait_count = 0;
        while (!dut->cpu_cmd_valid && wait_count++ < 10) tick(dut, tfp);

        // 4. Now, provide response and signal cpu_cmd_ready
        dut->cpu_cmd_ready = 1;
        dut->cpu_rsp = (0x1234 << 16) | i;
        tick(dut, tfp);

        // 5. Remove cpu_cmd_ready
        dut->cpu_cmd_ready = 0;
        tick(dut, tfp);

        // 6. Wait for rsp_valid_to_tap to go high
        wait_count = 0;
        while (!dut->rsp_valid_to_tap && wait_count++ < 10) tick(dut, tfp);

        tick(dut, tfp);

   
        tick(dut, tfp);
    }

    // Idle cycles to see signal states
    for (int i = 0; i < 10; ++i) tick(dut, tfp);

    tfp->close();
    delete dut;
    delete tfp;
    return 0;
}
