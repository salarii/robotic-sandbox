// tb_plic.cpp
#include "Vwishbone_plic.h"         // Verilated header for your module
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cassert>
#include <cstdint>
#include <iostream>
#include <iomanip>

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// ---------------------- PLIC Offsets (offset addressing) ----------------------
static constexpr uint32_t PLIC_PRIORITY(uint32_t id) { return 0x00000000u + 4u*id; } // id=1..8 -> 0x4..0x20
static constexpr uint32_t PLIC_PENDING_OFF  = 0x00001000u;  // bit0=0, bit id = source id
static constexpr uint32_t PLIC_ENABLE_OFF   = 0x00002000u;  // bits [7:0] map to IDs 1..8 at [0..7]
static constexpr uint32_t PLIC_THRESH_OFF   = 0x00200000u;  // threshold (0..7), strict >
static constexpr uint32_t PLIC_CLAIM_OFF    = 0x00200004u;  // read: claim ID; write: complete(ID)

// ---------------------- VCD + clock tick ----------------------
static inline void tick(Vwishbone_plic* top, VerilatedVcdC* tfp) {
    // rising edge
    top->clk = 1;
    top->eval();
    if (tfp) tfp->dump(main_time++);
    // falling edge
    top->clk = 0;
    top->eval();
    if (tfp) tfp->dump(main_time++);
}

// ---------------------- Wishbone BFM ----------------------
static inline void wb_idle(Vwishbone_plic* top) {
    top->wb_cyc_i = 0;
    top->wb_stb_i = 0;
    top->wb_we_i  = 0;
    top->wb_adr_i = 0;
    top->wb_dat_i = 0;
}

static inline void wb_write(Vwishbone_plic* top, VerilatedVcdC* tfp, uint32_t addr, uint32_t data, int max_wait = 1000) {
    top->wb_adr_i = addr;
    top->wb_dat_i = data;
    top->wb_we_i  = 1;
    top->wb_cyc_i = 1;
    top->wb_stb_i = 1;

    int w = 0;
    while (!top->wb_ack_o) {
        tick(top, tfp);
        if (++w > max_wait) { std::cerr << "WB write timeout @0x" << std::hex << addr << "\n"; assert(false); }
    }
    // Complete handshake: drop STB/CYC now, then tick once so slave sees !req
    wb_idle(top);
    tick(top, tfp);
}

static inline uint32_t wb_read(Vwishbone_plic* top, VerilatedVcdC* tfp, uint32_t addr, int max_wait = 1000) {
    top->wb_adr_i = addr;
    top->wb_we_i  = 0;
    top->wb_cyc_i = 1;
    top->wb_stb_i = 1;

    uint32_t val = 0;
    int w = 0;
    while (!top->wb_ack_o) {
        tick(top, tfp);
        if (++w > max_wait) { std::cerr << "WB read timeout @0x" << std::hex << addr << "\n"; assert(false); }
    }
    val = top->wb_dat_o;      // sample on ACK
    wb_idle(top);
    tick(top, tfp);
    return val;
}

// ---------------------- Convenience helpers ----------------------
static inline void plic_set_priority(Vwishbone_plic* top, VerilatedVcdC* tfp, uint32_t id, uint32_t prio) {
    wb_write(top, tfp, PLIC_PRIORITY(id), prio & 0x7u);
}
static inline void plic_set_enable_mask(Vwishbone_plic* top, VerilatedVcdC* tfp, uint32_t mask) {
    wb_write(top, tfp, PLIC_ENABLE_OFF, mask & 0xFFu);
}
static inline void plic_set_threshold(Vwishbone_plic* top, VerilatedVcdC* tfp, uint32_t thr) {
    wb_write(top, tfp, PLIC_THRESH_OFF, thr & 0x7u);
}
static inline uint32_t plic_read_pending(Vwishbone_plic* top, VerilatedVcdC* tfp) {
    return wb_read(top, tfp, PLIC_PENDING_OFF);
}
static inline uint32_t plic_claim(Vwishbone_plic* top, VerilatedVcdC* tfp) {
    return wb_read(top, tfp, PLIC_CLAIM_OFF) & 0xFu; // ID in low nibble (1..8), 0=no IRQ
}
static inline void plic_complete(Vwishbone_plic* top, VerilatedVcdC* tfp, uint32_t id) {
    wb_write(top, tfp, PLIC_CLAIM_OFF, id & 0xFu);
}

// ---------------------- Assertions ----------------------
static inline void must_be(bool cond, const char* msg) {
   if (!cond) { std::cerr << "ASSERTION FAILED: " << msg << "\n"; assert(cond); }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    auto* top = new Vwishbone_plic;
    Verilated::traceEverOn(true);
    auto* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("wave.vcd");

    // Reset
    wb_idle(top);
    top->irq_sources = 0;
    top->clk = 0;
    top->rst = 1;
    for (int i = 0; i < 8; ++i) tick(top, tfp);
    top->rst = 0;
    tick(top, tfp);

    // Configure PLIC
    // threshold = 2  → only priorities >2 are eligible (i.e., 3..7)
    plic_set_threshold(top, tfp, 2);

    // priorities: ID2=5 (highest), ID7=4, ID5=3
    plic_set_priority(top, tfp, 2, 5);
    plic_set_priority(top, tfp, 7, 4);
    plic_set_priority(top, tfp, 5, 3);

    // enable IDs 2,5,7
    const uint32_t EN_MASK = (1u<<(2-1)) | (1u<<(5-1)) | (1u<<(7-1)); // bits 1,4,6
    plic_set_enable_mask(top, tfp, EN_MASK);

    // No sources asserted yet
    must_be(top->irq_to_cpu == 0, "MEIP should be low with no pending");

    // Assert three sources: IDs 2,5,7
    uint8_t src_mask = EN_MASK;           // level-high lines for 2,5,7
    top->irq_sources = src_mask;
    tick(top, tfp);                       // let pending latch

    // Pending readback: bit0=0, bits 2,5,7 set
    uint32_t pend = plic_read_pending(top, tfp);
    uint32_t expected_pend = (1u<<2) | (1u<<5) | (1u<<7);
    must_be( (pend & ((1u<<8)-1)) == expected_pend, "Pending bitmap mismatch after assert");
    must_be(top->irq_to_cpu == 1, "MEIP should be high when eligible winner exists");

    // -------- Typical OS flow: claim; (optionally loop claim) ; then complete --------

    // Claim #1: should be ID 2 (prio 5 highest)
    uint32_t id1 = plic_claim(top, tfp);
    std::cout << "Claim1 = " << id1 << "\n";
    must_be(id1 == 2, "First claim should pick ID 2");

    // Without completing ID2, claim again (OS can loop claims inside handler):
    // ID2 is now in_service, so winner should be ID7 (prio 4)
    src_mask &= ~(1u<<(7-1));
    src_mask &= ~(1u<<(2-1));
    top->irq_sources = src_mask;  
    uint32_t id2 = plic_claim(top, tfp);
    std::cout << "Claim2 = " << id2 << "\n";
    must_be(id2 == 7, "Second claim should pick ID 7 while ID2 is in-service");

    // Now complete ID2, BUT keep its line asserted (level-high) → it should re-pend next cycle
    plic_complete(top, tfp, 2);

    tick(top, tfp); // allow in_service[2] to clear and level to re-set pending

    // Next claim should return ID2 AGAIN (since it re-pended and outranks ID5)
    uint32_t id3 = plic_claim(top, tfp);
    std::cout << "Claim3 = " << id3 << "\n";
    must_be(id3 == 2, "Third claim should re-pick ID 2 (level-high re-pended)");

    // Complete ID7 now (we had claimed it as #2)

    plic_complete(top, tfp, 7);
    tick(top, tfp);

    // Complete ID2 (second time). This time, DEASSERT its line so it won't re-pend.
    

    tick(top, tfp);
    plic_complete(top, tfp, 2);
    src_mask &= ~(1u<<(5-1));     // drop ID5 line (for completeness)
    top->irq_sources = src_mask;
    // At this point only ID5 remains pending/eligible → next claim should be ID5.
    uint32_t id4 = plic_claim(top, tfp);
    std::cout << "Claim4 = " << id4 << "\n";
    must_be(id4 == 5, "Fourth claim should pick ID 5");

    // Complete ID5; with no lines asserted, MEIP should go low and claim returns 0.
    plic_complete(top, tfp, 5);

    tick(top, tfp);
    
    must_be(top->irq_to_cpu == 0, "MEIP should be low after all IRQs handled");
    uint32_t id5 = plic_claim(top, tfp);
    std::cout << "Final claim = " << id5 << "\n";
    must_be(id5 == 0, "Claim should return 0 when nothing pending");

    std::cout << "\nAll PLIC tests PASSED ✅\n";

    tfp->close();
    delete tfp;
    delete top;
    return 0;
}
