// tb_clint.cpp
#include "Vclint.h"                 // <-- if your module is named differently, adjust this
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cassert>
#include <cstdint>
#include <iostream>
#include <iomanip>
#include <string>

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// ---------------------- Local CLINT Offsets (offset addressing) ----------------------
static constexpr uint32_t MSIP_OFF         = 0x00000000;
static constexpr uint32_t MTIMECMP_LO_OFF  = 0x00004000;
static constexpr uint32_t MTIMECMP_HI_OFF  = 0x00004004;
static constexpr uint32_t MTIME_LO_OFF     = 0x0000BFF8;
static constexpr uint32_t MTIME_HI_OFF     = 0x0000BFFC;

// ---------------------- VCD + clock tick ----------------------
static inline void tick(Vclint* top, VerilatedVcdC* tfp) {
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
static inline void wb_idle(Vclint* top) {
    top->wb_cyc_i = 0;
    top->wb_stb_i = 0;
    top->wb_we_i  = 0;
    top->wb_adr_i = 0;
    top->wb_dat_i = 0;
}

static inline void wb_write(Vclint* top, VerilatedVcdC* tfp, uint32_t addr, uint32_t data, int max_wait = 1000) {
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
    // one extra cycle to complete handshake cleanly

    wb_idle(top);
    tick(top, tfp);
}

static inline uint32_t wb_read(Vclint* top, VerilatedVcdC* tfp, uint32_t addr, int max_wait = 1000) {
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
    // Sample data when ack is asserted
    val = top->wb_dat_o;
    // complete handshake

    wb_idle(top);
    tick(top, tfp);
    return val;
}

// Read a consistent 64-bit value split into HI/LO words (handles rollover)
static inline uint64_t read64_consistent(Vclint* top, VerilatedVcdC* tfp, uint32_t lo_off, uint32_t hi_off) {
    // Standard pattern: read HI, LO, HI; if HI changed, retry
    while (true) {
        uint32_t hi1 = wb_read(top, tfp, hi_off);
        uint32_t lo  = wb_read(top, tfp, lo_off);
        uint32_t hi2 = wb_read(top, tfp, hi_off);
        if (hi1 == hi2) {
            return (static_cast<uint64_t>(hi1) << 32) | lo;
        }
    }
}

// Safe write to 64-bit register split in HI/LO (mtimecmp): HI=0xFFFF_FFFF -> LO -> HI(desired)
static inline void write64_mtimecmp_atomic(Vclint* top, VerilatedVcdC* tfp, uint64_t value) {
    wb_write(top, tfp, MTIMECMP_HI_OFF, 0xFFFF'FFFFu);
    wb_write(top, tfp, MTIMECMP_LO_OFF, static_cast<uint32_t>(value & 0xFFFF'FFFFull));
    wb_write(top, tfp, MTIMECMP_HI_OFF, static_cast<uint32_t>((value >> 32) & 0xFFFF'FFFFull));
}

// Direct write to mtime (useful for tests)
static inline void write64_mtime(Vclint* top, VerilatedVcdC* tfp, uint64_t value) {
    wb_write(top, tfp, MTIME_HI_OFF, static_cast<uint32_t>((value >> 32) & 0xFFFF'FFFFull));
    wb_write(top, tfp, MTIME_LO_OFF, static_cast<uint32_t>(value & 0xFFFF'FFFFull));
}

// ---------------------- Assertions helpers ----------------------
static inline void must_be(bool cond, const char* msg) {
    if (!cond) { std::cerr << "ASSERTION FAILED: " << msg << "\n"; assert(cond); }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    auto* top = new Vclint;
    Verilated::traceEverOn(true);
    auto* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("wave.vcd");

    // Reset
    wb_idle(top);
    top->clk = 0;
    top->rst = 1;

    for (int i = 0; i < 8; ++i) tick(top, tfp);
    top->rst = 0;
    tick(top, tfp);

    // After reset: msip=0, mtip may be 0 if mtimecmp starts large
    std::cout << "[RESET DONE] msip=" << int(top->msip) << " mtip=" << int(top->mtip) << "\n";
    must_be(top->msip == 0, "MSIP should be 0 after reset");

    // ---------------------- Test 1: MSIP set/clear ----------------------
    std::cout << "[TEST 1] MSIP set/clear\n";
    wb_write(top, tfp, MSIP_OFF, 0x1);
    tick(top, tfp);
    must_be(top->msip == 1, "MSIP did not assert after write");

    wb_write(top, tfp, MSIP_OFF, 0x0);
    tick(top, tfp);
    must_be(top->msip == 0, "MSIP did not deassert after write");

    // ---------------------- Test 2: MTIME monotonic increase ----------------------
    std::cout << "[TEST 2] MTIME monotonicity\n";
    uint64_t t0 = read64_consistent(top, tfp, MTIME_LO_OFF, MTIME_HI_OFF);
    for (int i = 0; i < 50; ++i) tick(top, tfp);
    uint64_t t1 = read64_consistent(top, tfp, MTIME_LO_OFF, MTIME_HI_OFF);
    std::cout << "mtime: " << t0 << " -> " << t1 << "\n";
    must_be(t1 > t0, "MTIME did not increase");

    // ---------------------- Test 3: MTIP trigger when mtime >= mtimecmp ----------------------
    std::cout << "[TEST 3] MTIP trigger\n";
    // Put mtime to 0 for determinism
    write64_mtime(top, tfp, 0);
    // Program mtimecmp a small number of ticks in the future
    const uint64_t cmp_val = 200; // adjust as needed; assumes mtime ticks each clk or per prescaler
    write64_mtimecmp_atomic(top, tfp, cmp_val);

    // MTIP should remain low until threshold is reached
    must_be(top->mtip == 0, "MTIP should be low before reaching compare");

    int wait_cycles = 0;
    while (!top->mtip && wait_cycles < 5000) { tick(top, tfp); ++wait_cycles; }
    std::cout << "Waited cycles for MTIP: " << wait_cycles << "\n";
    must_be(top->mtip == 1, "MTIP did not assert when mtime >= mtimecmp");

    // ---------------------- Test 4: Clearing MTIP by moving compare forward ----------------------
    std::cout << "[TEST 4] MTIP clear on compare update\n";
    write64_mtimecmp_atomic(top, tfp, cmp_val + 100000); // move far ahead
    tick(top, tfp);
    must_be(top->mtip == 0, "MTIP did not clear after moving mtimecmp ahead");

    // ---------------------- Test 5: Safe update sequence avoids spurious MTIP ----------------------
    std::cout << "[TEST 5] Safe mtimecmp update sequence\n";
    // Move mtime near (but below) a new compare value; ensure MTIP stays low during sequence
    write64_mtime(top, tfp, 1000);
    write64_mtimecmp_atomic(top, tfp, 50000);
    tick(top, tfp);
    must_be(top->mtip == 0, "MTIP unexpectedly high after safe update");

    // Advance some cycles, still below compare
    for (int i = 0; i < 100; ++i) tick(top, tfp);
    must_be(top->mtip == 0, "MTIP should still be low (mtime < mtimecmp)");

    // March to the compare point and see MTIP rise
    while (!top->mtip) tick(top, tfp);
    must_be(top->mtip == 1, "MTIP should assert when mtime reaches updated compare");

    std::cout << "\nAll CLINT tests PASSED ✅\n";

    tfp->close();
    delete tfp;
    delete top;
    return 0;
}
