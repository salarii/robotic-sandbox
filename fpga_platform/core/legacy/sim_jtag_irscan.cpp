#include "Vjtag_state_machine.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <iostream>
#include <cassert>
#include <vector>
#include <string>

// Use your state encoding here
enum JtagStates {
    TEST_LOGIC_RESET = 0x0,
    RUN_TEST_IDLE    = 0x1,
    SELECT_DR        = 0x2,
    CAPTURE_DR       = 0x3,
    SHIFT_DR         = 0x4,
    EXIT1_DR         = 0x5,
    PAUSE_DR         = 0x6,
    EXIT2_DR         = 0x7,
    UPDATE_DR        = 0x8,
    SELECT_IR        = 0x9,
    CAPTURE_IR       = 0xA,
    SHIFT_IR         = 0xB,
    EXIT1_IR         = 0xC,
    PAUSE_IR         = 0xD,
    EXIT2_IR         = 0xE,
    UPDATE_IR        = 0xF,
};

const std::vector<std::string> state_names = {
    "TEST_LOGIC_RESET", "RUN_TEST_IDLE", "SELECT_DR", "CAPTURE_DR",
    "SHIFT_DR", "EXIT1_DR", "PAUSE_DR", "EXIT2_DR",
    "UPDATE_DR", "SELECT_IR", "CAPTURE_IR", "SHIFT_IR",
    "EXIT1_IR", "PAUSE_IR", "EXIT2_IR", "UPDATE_IR"
};

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

void print_and_check(Vjtag_state_machine* tap, int expected_state) {
    int state = tap->state;
    std::cout << "TAP state: " << state << " (" << state_names[state] << ")" << std::endl;
    assert(state == expected_state && "Unexpected TAP state!");
}

void step_tck(Vjtag_state_machine* tap, VerilatedVcdC* tfp) {
    tap->tck = 1;
    tap->eval();
    tfp->dump(main_time++);
    tap->tck = 0;
    tap->eval();
    tfp->dump(main_time++);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* tap = new Vjtag_state_machine;

    Verilated::traceEverOn(true);
    auto* tfp = new VerilatedVcdC;
    tap->trace(tfp, 99);
    tfp->open("wave.vcd");

    tap->trst = 1;
    tap->tms = 1;

    // 1. Reset: TMS=1 for 6 clocks
    std::cout << "[RESET SEQUENCE]" << std::endl;
    for (int i = 0; i < 6; ++i) {
        step_tck(tap, tfp);
        print_and_check(tap, TEST_LOGIC_RESET);
    }

    // 2. Move to RUN_TEST_IDLE (TMS=0, 1 clock)
    std::cout << "[IDLE]" << std::endl;
    tap->tms = 0;
    step_tck(tap, tfp);
    print_and_check(tap, RUN_TEST_IDLE);

    // 3. Go to SELECT_DR (TMS=1, 1 clock)
    std::cout << "[SELECT_DR]" << std::endl;
    tap->tms = 1;
    step_tck(tap, tfp);
    print_and_check(tap, SELECT_DR);

    // 4. Go to SELECT_IR (TMS=1, 1 clock)
    std::cout << "[SELECT_IR]" << std::endl;
    tap->tms = 1;
    step_tck(tap, tfp);
    print_and_check(tap, SELECT_IR);

    // 5. Go to CAPTURE_IR (TMS=0, 1 clock)
    std::cout << "[CAPTURE_IR]" << std::endl;
    tap->tms = 0;
    step_tck(tap, tfp);
    print_and_check(tap, CAPTURE_IR);

    // 6. Go to SHIFT_IR (TMS=0, 1 clock)
    std::cout << "[SHIFT_IR]" << std::endl;
    tap->tms = 0;
    step_tck(tap, tfp);
    print_and_check(tap, SHIFT_IR);

    // 7. Shift 4 IR bits (stay in SHIFT_IR, TMS=0 for 3 bits, TMS=1 on last)
    int IR_WIDTH = 4;
    int ir_bits[4] = {1, 1, 0, 1}; // Example IR: LSB first
    for (int i = 0; i < IR_WIDTH; ++i) {
    
        tap->tms = (i == IR_WIDTH - 1) ? 1 : 0;
        step_tck(tap, tfp);
        if (i < IR_WIDTH - 1) {
            print_and_check(tap, SHIFT_IR);
        } else {
            print_and_check(tap, EXIT1_IR);
        }
    }

    // 8. From EXIT1_IR to UPDATE_IR (TMS=1, 1 clock)
    std::cout << "[UPDATE_IR]" << std::endl;
    tap->tms = 1;
    step_tck(tap, tfp);
    print_and_check(tap, UPDATE_IR);

    // 9. From UPDATE_IR to RUN_TEST_IDLE (TMS=0, 1 clock)
    std::cout << "[RETURN TO IDLE]" << std::endl;
    tap->tms = 0;
    step_tck(tap, tfp);
    print_and_check(tap, RUN_TEST_IDLE);

    // --- Optionally, walk through all other TAP states to show coverage ---
    // 1. Reset: TMS=1 for 6 clocks

    // DR scan chain demo
    std::cout << "[DR CHAIN DEMO]" << std::endl;
    tap->tms = 1; step_tck(tap, tfp); print_and_check(tap, SELECT_DR);
    tap->tms = 0; step_tck(tap, tfp); print_and_check(tap, CAPTURE_DR);
    tap->tms = 0; step_tck(tap, tfp); print_and_check(tap, SHIFT_DR);
    tap->tms = 1; step_tck(tap, tfp); print_and_check(tap, EXIT1_DR);
    tap->tms = 0; step_tck(tap, tfp); print_and_check(tap, PAUSE_DR);
    tap->tms = 1; step_tck(tap, tfp); print_and_check(tap, EXIT2_DR);
    tap->tms = 0; step_tck(tap, tfp); print_and_check(tap, SHIFT_DR);
    tap->tms = 1; step_tck(tap, tfp); print_and_check(tap, EXIT1_DR);
    tap->tms = 1; step_tck(tap, tfp); print_and_check(tap, UPDATE_DR);
    tap->tms = 0; step_tck(tap, tfp); print_and_check(tap, RUN_TEST_IDLE);

    // IR pause and exit demo
    std::cout << "[IR PAUSE/EXIT DEMO]" << std::endl;
    tap->tms = 1; step_tck(tap, tfp); print_and_check(tap, SELECT_DR);
    tap->tms = 1; step_tck(tap, tfp); print_and_check(tap, SELECT_IR);
    tap->tms = 0; step_tck(tap, tfp); print_and_check(tap, CAPTURE_IR);
    tap->tms = 0; step_tck(tap, tfp); print_and_check(tap, SHIFT_IR);
    tap->tms = 1; step_tck(tap, tfp); print_and_check(tap, EXIT1_IR);
    tap->tms = 0; step_tck(tap, tfp); print_and_check(tap, PAUSE_IR);
    tap->tms = 1; step_tck(tap, tfp); print_and_check(tap, EXIT2_IR);
    tap->tms = 0; step_tck(tap, tfp); print_and_check(tap, SHIFT_IR);
    tap->tms = 1; step_tck(tap, tfp); print_and_check(tap, EXIT1_IR);
    tap->tms = 1; step_tck(tap, tfp); print_and_check(tap, UPDATE_IR);
    tap->tms = 0; step_tck(tap, tfp); print_and_check(tap, RUN_TEST_IDLE);

    std::cout << "[RESET SEQUENCE]" << std::endl;
    tap->tms = 1;
    const int expected_states[5] = {
        SELECT_DR,        // After 1st TCK
        SELECT_IR,        // After 2nd TCK
        TEST_LOGIC_RESET, // After 3rd TCK
        TEST_LOGIC_RESET, // After 4th TCK
        TEST_LOGIC_RESET  // After 5th TCK
    };
    for (int i = 0; i < 5; ++i) {
        step_tck(tap, tfp);
       print_and_check(tap, expected_states[i]);
    }
    tfp->close();
    delete tap;
    return 0;
}
