#include "Vtop_dmi_vex.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdint>
#include <cstdio>

// --------- VCD time ----------
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static inline void tick(Vtop_dmi_vex* top, VerilatedVcdC* tfp) {
    top->clk = 0; top->eval(); if (tfp) tfp->dump(main_time++);
    top->clk = 1; top->eval(); if (tfp) tfp->dump(main_time++);
    ++main_time;
}

static inline void runtest(Vtop_dmi_vex* top, VerilatedVcdC* tfp, int cycles) {
    for (int i = 0; i < cycles; ++i) tick(top, tfp);
}

// ------------- DMI helpers -------------
// DMI request format in top: {addr[40:34], data[33:2], op[1:0]}
// op: 0=NOP, 1=READ, 2=WRITE
static inline uint64_t pack_dmi_req(uint8_t addr, uint32_t data, uint8_t op) {
    uint64_t req = 0;
    req |= ((uint64_t)(addr & 0x7F)) << 34;
    req |= ((uint64_t)data) << 2;
    req |= (uint64_t)(op & 0x3);
    return req;
}

static inline void dmi_pulse(Vtop_dmi_vex* top, VerilatedVcdC* tfp, uint64_t req) {
    top->dmi_req = req;
    top->dmi_req_valid = 1;
    tick(top, tfp);              // present for 1 cycle
    top->dmi_req_valid = 0;
}

static inline uint32_t dmi_read(Vtop_dmi_vex* top, VerilatedVcdC* tfp, uint8_t addr) {
    // Issue READ
    dmi_pulse(top, tfp, pack_dmi_req(addr, 0, 1));

    // Wait until response becomes valid
    int guard = 10000;
    while (!top->dmi_rsp_valid && guard-- > 0) tick(top, tfp);

    // Sample data field [33:2]
    uint32_t data = (uint32_t)((top->dmi_rsp >> 2) & 0xFFFFFFFFull);
    return data;
}

static inline void dmi_write(Vtop_dmi_vex* top, VerilatedVcdC* tfp, uint8_t addr, uint32_t data) {
    dmi_pulse(top, tfp, pack_dmi_req(addr, data, 2));
    tick(top, tfp);
}

// --------- Keep your original API names, now backed by DMI ----------
static void dbg_write(Vtop_dmi_vex* top, VerilatedVcdC* tfp, uint8_t addr, uint32_t data) {
    dmi_write(top, tfp, addr, data);
}

static uint32_t dbg_read(Vtop_dmi_vex* top, VerilatedVcdC* tfp, uint8_t addr) {
    return dmi_read(top, tfp, addr);
}

// Plugin convenience
static inline void     dbg_ctrl  (Vtop_dmi_vex* t, VerilatedVcdC* f, uint32_t data){ dbg_write(t,f,0x00,data); }
static inline void     dbg_inject(Vtop_dmi_vex* t, VerilatedVcdC* f, uint32_t ins){  dbg_write(t,f,0x04,ins); }
static inline uint32_t dbg_data  (Vtop_dmi_vex* t, VerilatedVcdC* f){ return dbg_read(t,f,0x04); }
static inline uint32_t dbg_status(Vtop_dmi_vex* t, VerilatedVcdC* f){ return dbg_read(t,f,0x11); }

// --------- Status decoding ----------
struct StatusBits {
    int resetIt;        // [0]
    int haltIt;         // [1]
    int isPipBusy;      // [2]
    int haltedByBreak;  // [3]
    int stepIt;         // [4]
};
static StatusBits decode_status(uint32_t s) {
    StatusBits b;
    b.resetIt       = (s >> 0) & 1;
    b.haltIt        = (s >> 1) & 1;
    b.isPipBusy     = (s >> 2) & 1;
    b.haltedByBreak = (s >> 3) & 1;
    b.stepIt        = (s >> 4) & 1;
    return b;
}

// --------- Tiny asserts / reporting ----------
static int g_failures = 0;
#define EXPECT_EQ(tag, got, exp) do { \
    if ((got) != (exp)) { \
        std::printf("FAIL: %s: got 0x%08X, exp 0x%08X\n", tag, (unsigned)(got), (unsigned)(exp)); \
        g_failures++; \
    } else { \
        std::printf("PASS: %s: 0x%08X\n", tag, (unsigned)(got)); \
    } \
} while(0)

#define EXPECT_TRUE(tag, cond) do { \
    if (!(cond)) { \
        std::printf("FAIL: %s\n", tag); \
        g_failures++; \
    } else { \
        std::printf("PASS: %s\n", tag); \
    } \
} while(0)

// --------- Encodings we use ----------
static const uint32_t CTRL_STEP   = 0x00000010;
static const uint32_t CTRL_HALT   = 0x00020000;
static const uint32_t CTRL_RESUME = 0x02000000;
static const uint32_t CTRL_RST_ON = 0x00010000;
static const uint32_t CTRL_RST_OFF= 0x01000000;

// RV32I instructions
static const uint32_t INS_NOP         = 0x00000013;
static const uint32_t INS_LUI_A0_1    = 0x00001537;
static const uint32_t INS_ADDI_A0_M1  = 0xFFF50513;
static const uint32_t INS_MOV_X31_A0  = 0x00050F93;
static const uint32_t INS_EBREAK      = 0x00100073;

// One instruction step helper
static inline void step_one(Vtop_dmi_vex* top, VerilatedVcdC* tfp) {
    dbg_ctrl(top, tfp, CTRL_STEP | CTRL_RESUME);
    runtest(top, tfp, 2);
}

// --------- Soft-breakpoint runner ----------
static void run_prog_with_soft_bp(Vtop_dmi_vex* top, VerilatedVcdC* tfp,
                                  const uint32_t* prog, int len, int bp_idx)
{
    for (int i = 0; i < len; ++i) {
        if (i == bp_idx) {
            dbg_inject(top, tfp, INS_EBREAK);
            step_one(top, tfp);
            uint32_t s_raw = dbg_status(top, tfp);
            StatusBits s = decode_status(s_raw);
            std::printf("[BP] hit at idx %d, status=0x%08X [halt=%d brk=%d]\n",
                        i, s_raw, s.haltIt, s.haltedByBreak);
            EXPECT_TRUE("soft BP: haltedByBreak==1", s.haltedByBreak == 1);
            uint32_t pc_at_break = dbg_data(top, tfp);
            std::printf("[BP] PC captured: 0x%08X\n", pc_at_break);
            return;
        } else {
            dbg_inject(top, tfp, prog[i]);
            step_one(top, tfp);
        }
    }
    EXPECT_TRUE("soft BP: not reached", false);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    Vtop_dmi_vex* top = new Vtop_dmi_vex;

    top->clk   = 0;
    top->reset = 1;
    top->dmi_req = 0;
    top->dmi_req_valid = 0;

    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("wave.vcd");

    // Reset
    runtest(top, tfp, 8);
    top->reset = 0;
    runtest(top, tfp, 4);

    std::printf("\n=== Scenario 0: Initial status ===\n");
    uint32_t s_raw = dbg_status(top, tfp);
    StatusBits s = decode_status(s_raw);
    EXPECT_TRUE("init !haltIt", s.haltIt == 0);
/*
    std::printf("\n=== Scenario 1: HALT ===\n");
    dbg_ctrl(top, tfp, CTRL_HALT);
    s_raw = dbg_status(top, tfp);
    s = decode_status(s_raw);
    EXPECT_TRUE("haltIt==1", s.haltIt == 1);

    std::printf("\n=== Scenario 2: Single-step NOP ===\n");
    dbg_inject(top, tfp, INS_NOP);
    step_one(top, tfp);
    s_raw = dbg_status(top, tfp);
    s = decode_status(s_raw);
    EXPECT_TRUE("rehalted after step", s.haltIt == 1);

    std::printf("\n=== Scenario 3: a0 <- 0x00000FFF ===\n");
    dbg_inject(top, tfp, INS_LUI_A0_1);
    step_one(top, tfp);
    dbg_inject(top, tfp, INS_ADDI_A0_M1);
    step_one(top, tfp);
    dbg_inject(top, tfp, INS_MOV_X31_A0);
    step_one(top, tfp);
    uint32_t wb = dbg_data(top, tfp);
    EXPECT_EQ("a0 value via WB", wb, 0x00000FFF);

    std::printf("\n=== Scenario 4: EBREAK capture ===\n");
    dbg_inject(top, tfp, INS_EBREAK);
    step_one(top, tfp);
    s_raw = dbg_status(top, tfp);
    s = decode_status(s_raw);
    EXPECT_TRUE("haltedByBreak==1", s.haltedByBreak == 1);
    uint32_t pc_at_break = dbg_data(top, tfp);
    EXPECT_TRUE("pc_at_break plausible (non-zero)", pc_at_break != 0x00000000);

    std::printf("\n=== Scenario 5: RESUME ===\n");
    dbg_ctrl(top, tfp, CTRL_RESUME);
    s_raw = dbg_status(top, tfp);
    s = decode_status(s_raw);
    EXPECT_TRUE("haltIt==0", s.haltIt == 0);

    std::printf("\n=== Scenario 6: Debug reset pulse ===\n");
    dbg_ctrl(top, tfp, CTRL_RST_ON);
    dbg_ctrl(top, tfp, CTRL_RST_OFF);
    s_raw = dbg_status(top, tfp);
    s = decode_status(s_raw);
    EXPECT_TRUE("resetIt==0 after OFF", s.resetIt == 0);

    std::printf("\n=== Scenario 7: Soft breakpoint ===\n");
    const uint32_t prog[] = {
        INS_NOP,
        INS_LUI_A0_1,
        INS_ADDI_A0_M1,
        INS_MOV_X31_A0
    };
    const int bp_idx = 2;
    dbg_ctrl(top, tfp, CTRL_HALT);
    run_prog_with_soft_bp(top, tfp, prog, (int)(sizeof(prog)/sizeof(prog[0])), bp_idx);
*/
    std::printf("\n=== SUMMARY: %d failure(s) ===\n", g_failures);
    runtest(top, tfp, 8);
    tfp->close();
    delete tfp;
    delete top;

    return (g_failures == 0) ? 0 : 1;
}
