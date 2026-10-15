
#include "VVexRiscv.h"
#include "verilated_vcd_c.h"

#include "verilated.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <iostream>
#include <csignal>
static VerilatedVcdC* g_tfp = nullptr;


static inline void step_cpu(VVexRiscv& top, VerilatedVcdC* tfp, vluint64_t& main_time, unsigned cycles) {
    for (unsigned i = 0; i < cycles; ++i) {
        top.clk = 0; top.eval(); tfp->dump(main_time++);
        top.clk = 1; top.eval(); tfp->dump(main_time++);
    }
}

static void handle_sig(int) {
    if (g_tfp) { g_tfp->flush(); g_tfp->close(); }
    _exit(0); // quick, async-signal-safe-ish exit
}
// Accept a single Remote Bitbang connection
static int accept_bitbang(int port) {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); exit(1); }
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);
    if (bind(server_fd, (sockaddr*)&addr, sizeof(addr)) < 0) { perror("bind"); exit(1); }
    listen(server_fd, 1);
    printf("Waiting for OpenOCD on port %d...\n", port);
    socklen_t len = sizeof(addr);
    int client = accept(server_fd, (sockaddr*)&addr, &len);
    if (client < 0) { perror("accept"); exit(1); }
    close(server_fd);
    fcntl(client, F_SETFL, O_NONBLOCK);
    printf("Connected!\n");
    return client;
}

// TAP state names
static const char* state_names[] = {
    "TEST_LOGIC_RESET", "RUN_TEST_IDLE", "SELECT_DR", "CAPTURE_DR",
    "SHIFT_DR", "EXIT1_DR", "PAUSE_DR", "EXIT2_DR",
    "UPDATE_DR", "SELECT_IR", "CAPTURE_IR", "SHIFT_IR",
    "EXIT1_IR","PAUSE_IR","EXIT2_IR","UPDATE_IR"
};


const unsigned CPU_CYCLES_PER_TCK = 20;        // your target
const unsigned CPU_CYCLES_PER_TCK_EDGE = CPU_CYCLES_PER_TCK / 2;

int main(int argc, char** argv) {
    // Parse optional --max-edges N
    size_t max_edges = 10000000;
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::strcmp(argv[i], "--max-edges") == 0) {
            max_edges = std::strtoul(argv[i+1], nullptr, 0);
        }
    }

    Verilated::commandArgs(argc, argv);


    VVexRiscv top;



    std::signal(SIGINT,  handle_sig);
    std::signal(SIGTERM, handle_sig);

    Verilated::traceEverOn(true);

    VerilatedVcdC* tfp = new VerilatedVcdC;
    g_tfp = tfp;
    top.trace(tfp, 99);
    tfp->open("wave.vcd");

    const int port = 5555;
    int bb_fd = accept_bitbang(port);

    // Timing
    vluint64_t main_time = 0;
    const int N_CLK_PER_TCK = 10; // sim granularity at each jtag_tck level

    // JTAG pins
    uint8_t last_tck = 0;

    // Start with jtag_trst deasserted, jtag_tms=1, jtag_tck=0

    top.clk = 0;
    top.reset = 1; 
    top.debug_reset = 0;
    top.jtag_tck  = 0;
    top.jtag_tms  = 1;
    top.jtag_tdi  = 0;


    step_cpu(top, tfp, main_time, 8);
    top.reset = 0;   // release CPU reset
    step_cpu(top, tfp, main_time, 8);
    //for (int i = 0; i < 10; ++i) { top.eval(); tfp->dump(main_time++); }

    // Bookkeeping
    size_t edges_seen = 0;
    int pending_tdo = 0;         // last jtag_tdo captured at falling edge
    bool have_pending = false;   // whether pending_tdo is valid yet

    while (!Verilated::gotFinish()) {
        char cmd;
        ssize_t r = read(bb_fd, &cmd, 1);
        if (r > 0) {
            // Normalize lowercase quit too
            if (cmd == 'Q' || cmd == 'q') break;

            // Resets: 'r'/'s'/'t'/'u' => bit0=jtag_trst, bit1=SRST (OpenOCD rb driver)
            if (cmd == 'r' || cmd == 's' || cmd == 't' || cmd == 'u') {
                bool srst = (cmd == 's' || cmd == 'u');
                bool jtag_trst = (cmd == 't' || cmd == 'u');
                // In your setup you likely want to ignore SRST and only map jtag_trst:
                top.debug_reset = jtag_trst ? 1 : 0;

                step_cpu(top, tfp, main_time, 2); 
                continue;
            }

            // Drive pins: '0'..'7' (bit2=jtag_tck, bit1=jtag_tms, bit0=jtag_tdi)
            if (cmd >= '0' && cmd <= '7') {
                uint8_t v = (uint8_t)(cmd - '0');
                uint8_t new_tdi =  v & 1u;
                uint8_t new_tms = (v >> 1) & 1u;
                uint8_t new_tck = (v >> 2) & 1u;

                // Drive jtag_tms/TD I immediately
                top.jtag_tdi = new_tdi;
                top.jtag_tms = new_tms;

                // Edge on jtag_tck?
                if (new_tck != last_tck) {
                    top.jtag_tck = new_tck;
                    step_cpu(top, tfp, main_time, CPU_CYCLES_PER_TCK_EDGE);
                    // Evaluate at this level
                    top.jtag_tck = new_tck;
                    top.eval();
                    tfp->dump(main_time++);
                    step_cpu(top, tfp, main_time, CPU_CYCLES_PER_TCK_EDGE);
                    // Count this edge
                    edges_seen++;

                    // On falling edge, latch jtag_tdo for upcoming 'R'
                    if (last_tck == 1 && new_tck == 0) {
                        pending_tdo = (top.jtag_tdo & 1);
                        have_pending = true;

                    }

                    last_tck = new_tck;
                } 
                // Stop by configured number of edges
                if (edges_seen >= max_edges) break;
                continue;
            }

            // Sample jtag_tdo request: 'R' (reply ASCII '0'/'1')
            if (cmd == 'R') {
                // If we haven't seen a falling edge yet, return current level (rare)
                char ascii = (have_pending ? pending_tdo : (top.jtag_tdo & 1)) ? '1' : '0';
                if (write(bb_fd, &ascii, 1) < 0) { perror("write"); }

                continue;
            }

            // Unknown command: ignore
            // fprintf(stderr, "Unknown rb cmd: 0x%02x '%c'\n", (unsigned char)cmd, cmd);
        } else {
            // idle
            usleep(100);
        }

        if (edges_seen >= max_edges) break;
    }

    tfp->close();
    delete tfp;
    close(bb_fd);
    return 0;
}
