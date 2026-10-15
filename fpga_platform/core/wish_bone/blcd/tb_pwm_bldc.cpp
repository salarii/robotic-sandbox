// tb_pwm_bldc.cpp
#include "Vwb_pwm3_bldc.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cassert>
#include <cstdint>
#include <iostream>
#include <iomanip>

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static inline void tick(Vwb_pwm3_bldc* top, VerilatedVcdC* tfp) {
    top->wb_clk_i = 1; top->eval(); if (tfp) tfp->dump(main_time++);
    top->wb_clk_i = 0; top->eval(); if (tfp) tfp->dump(main_time++);
}

static inline void wb_idle(Vwb_pwm3_bldc* top) {
    top->wb_cyc_i = 0; top->wb_stb_i = 0; top->wb_we_i = 0;
    top->wb_adr_i = 0; top->wb_dat_i = 0; top->wb_sel_i = 0xF;
}

static inline void wb_write(Vwb_pwm3_bldc* top, VerilatedVcdC* tfp, uint32_t addr, uint32_t data, int max_wait = 1000) {
    top->wb_adr_i = addr;
    top->wb_dat_i = data;
    top->wb_sel_i = 0xF;
    top->wb_we_i  = 1; top->wb_cyc_i = 1; top->wb_stb_i = 1;
    int w = 0;
    while (!top->wb_ack_o) { tick(top, tfp); if (++w > max_wait) { std::cerr << "WB write timeout @0x" << std::hex << addr << "\n"; assert(false); } }
    wb_idle(top); tick(top, tfp);
}

static inline uint32_t wb_read(Vwb_pwm3_bldc* top, VerilatedVcdC* tfp, uint32_t addr, int max_wait = 1000) {
    top->wb_adr_i = addr;
    top->wb_sel_i = 0xF;
    top->wb_we_i  = 0; top->wb_cyc_i = 1; top->wb_stb_i = 1;
    uint32_t val = 0; int w = 0;
    while (!top->wb_ack_o) { tick(top, tfp); if (++w > max_wait) { std::cerr << "WB read timeout @0x" << std::hex << addr << "\n"; assert(false); } }
    val = top->wb_dat_o;
    wb_idle(top); tick(top, tfp);
    return val;
}

// Address map (matches earlier PWM design)
static constexpr uint32_t PWM0_LOW   = 0x00;
static constexpr uint32_t PWM0_HIGH  = 0x04;
static constexpr uint32_t PWM1_LOW   = 0x08;
static constexpr uint32_t PWM1_HIGH  = 0x0C;
static constexpr uint32_t PWM2_LOW   = 0x10;
static constexpr uint32_t PWM2_HIGH  = 0x14;
static constexpr uint32_t RELOAD_OFF = 0x18;

// Assertions
static inline void must(bool cond, const char* msg) {
    if (!cond) { std::cerr << "ASSERTION FAILED: " << msg << "\n"; assert(cond); }
}

static inline void check_interlock(Vwb_pwm3_bldc* t) {
    must(!(t->ah_o && t->al_o), "Phase A shoot-through");
    must(!(t->bh_o && t->bl_o), "Phase B shoot-through");
    must(!(t->ch_o && t->cl_o), "Phase C shoot-through");
}

static inline void check_sector_mapping(Vwb_pwm3_bldc* t, uint32_t sector) {
    bool ah=t->ah_o, al=t->al_o, bh=t->bh_o, bl=t->bl_o, ch=t->ch_o, cl=t->cl_o;

    auto disallow_others = [&](bool allow1, bool allow2, const char* name) {
        // All legs except the two allowed must be 0 at all times.
        bool ok = true;
        if (!allow1 && ah) ok = false;
        if (!allow2 && bl) ok = false;
        (void)name;
        return ok;
    };

    // For each sector, only these two legs are allowed to be 1 (PWM edges may make them 0)
    switch (sector & 7u) {
        case 0: must(!(al||bh||ch||cl), "Sector0: only AH & BL may be active"); break; // AH, BL allowed
        case 1: must(!(al||bh||bl||ch), "Sector1: only AH & CL may be active"); break; // AH, CL
        case 2: must(!(ah||al||bl||ch), "Sector2: only BH & CL may be active"); break; // BH, CL
        case 3: must(!(ah||bh||bl||ch), "Sector3: only AL & BH may be active"); break; // AL, BH
        case 4: must(!(ah||bh||bl||al), "Sector4: only AL & CH may be active"); break; // AL, CH
        case 5: must(!(ah||al||bh||ch), "Sector5: only BL & CH may be active"); break; // BL, CH
        default: must(!(ah||al||bh||bl||ch||cl), "SectorX: all off"); break;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* top = new Vwb_pwm3_bldc;

    Verilated::traceEverOn(true);
    auto* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("wave_bldc.vcd");

    // Reset
    wb_idle(top);
    top->wb_clk_i = 0;
    top->wb_rst_i = 1;
    top->sector_i = 0;
    for (int i=0;i<8;i++) tick(top, tfp);
    top->wb_rst_i = 0;
    tick(top, tfp);

    // Program PWM for "mostly ON" across the period to make checks simpler:
    // timer counts 0..RELOAD; outputs high when low<timer<high → choose [1 .. RELOAD-1]
    const uint32_t RELOAD = 19;  // short period → quick sim
    wb_write(top, tfp, RELOAD_OFF, RELOAD);
    wb_write(top, tfp, PWM0_LOW,   1);
    wb_write(top, tfp, PWM0_HIGH,  RELOAD-1);
    wb_write(top, tfp, PWM1_LOW,   1);
    wb_write(top, tfp, PWM1_HIGH,  RELOAD-1);
    wb_write(top, tfp, PWM2_LOW,   1);
    wb_write(top, tfp, PWM2_HIGH,  RELOAD-1);

    // Let the timer run a bit
    for (int i=0;i<20;i++) { tick(top, tfp); check_interlock(top); }

    // Sweep all six commutation sectors and verify mapping + interlock.
    for (int s=0; s<6; ++s) {
        top->sector_i = s;
        // Hold each sector for a few periods
        for (int k=0; k<200; ++k) {
            tick(top, tfp);
            check_interlock(top);
            check_sector_mapping(top, s);
        }
        std::cout << "Sector " << s << " OK\n";
    }

    std::cout << "\nBLDC mapping/interlock tests PASSED ✅\n";
    tfp->close();
    delete tfp;
    delete top;
    return 0;
}
