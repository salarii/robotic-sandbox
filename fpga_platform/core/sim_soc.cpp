#include "Vsoc.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

void tick(Vsoc *dut, VerilatedVcdC *tfp) {
    dut->clk = 0; dut->eval(); tfp->dump(main_time++);
    dut->clk = 1; dut->eval(); tfp->dump(main_time++);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vsoc *dut = new Vsoc;
    Verilated::traceEverOn(true);
    VerilatedVcdC *tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("soc_tb.vcd");

    // Reset
    dut->reset = 1;
    dut->dr_packet_valid = 0;
    dut->dr_packet = 0;
    for (int i = 0; i < 4; ++i) tick(dut, tfp);

    dut->reset = 0;
    tick(dut, tfp);

    // -------- Send debug command to read register x1 --------
    // dr_packet = {wr, address, data}
    // wr=0 (read), address=1, data=0
    dut->dr_packet_valid = 1;
    dut->dr_packet = (0ull << 40) | (0x01ull << 32) | 0;  // 41 bits: [40]=wr, [39:32]=addr, [31:0]=data
    tick(dut, tfp);

    // Deassert dr_packet_valid
    dut->dr_packet_valid = 0;
    dut->dr_packet = 0;
    tick(dut, tfp);

    // Let simulation run and potentially handle the command/response
    for (int i = 0; i < 20; ++i) {
        // Optionally: Print debug info if response seen
        if (dut->debug_if__rsp_valid_to_tap) {
            printf("Response from core: 0x%08x\n", dut->debug_if__rsp_to_tap);
        }
        tick(dut, tfp);
    }

    tfp->close();
    delete dut;
    delete tfp;
    return 0;
}
