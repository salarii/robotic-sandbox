// remote_bitbang_tb.cpp
#include "Vwishbone_top.h"
#include "verilated.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>
#include <netinet/tcp.h>

#include <poll.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <csignal>

static inline void step_cpu(Vwishbone_top& top, unsigned cycles) {
    for (unsigned i = 0; i < cycles; ++i) {
        top.clk = 0; top.eval();
        top.clk = 1; top.eval();
    }
}

static void handle_sig(int) {
    _exit(0);
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
    if (listen(server_fd, 1) < 0) { perror("listen"); exit(1); }
    printf("Waiting for OpenOCD on port %d...\n", port);
    socklen_t len = sizeof(addr);
    int client = accept(server_fd, (sockaddr*)&addr, &len);
    if (client < 0) { perror("accept"); exit(1); }
    close(server_fd);
    fcntl(client, F_SETFL, O_NONBLOCK);
    int nodelay = 1;
    setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));

    printf("Connected!\n");
    return client;
}

const unsigned CPU_CYCLES_PER_TCK      = 2;
const unsigned CPU_CYCLES_PER_TCK_EDGE = CPU_CYCLES_PER_TCK / 2;

int main(int argc, char** argv) {
    // Optional: --max-edges N
    size_t max_edges = 1000000000;
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::strcmp(argv[i], "--max-edges") == 0) {
            max_edges = std::strtoul(argv[i+1], nullptr, 0);
        }
    }

    Verilated::commandArgs(argc, argv);

    Vwishbone_top top;

    std::signal(SIGINT,  handle_sig);
    std::signal(SIGTERM, handle_sig);

    const int port = 5555;
    int bb_fd = accept_bitbang(port);

    // Initial pin states
    top.clk         = 0;
    top.rst         = 1;   // assume active-high reset
    top.debug_reset = 1;

    // JTAG idle
    top.jtag_tck = 0;
    top.jtag_tms = 1;
    top.jtag_tdi = 0;

    // UART inputs (others are ignored internally per your note)
    top.srx_pad_i = 1; // idle high
    top.cts_pad_i = 0;
    top.dsr_pad_i = 0;
    top.ri_pad_i  = 0;
    top.dcd_pad_i = 0;

    // Bring system out of reset
    step_cpu(top, 8);
    top.rst = 0;
    top.debug_reset = 0;
    step_cpu(top, 8);

    // Bookkeeping
    size_t   edges_seen   = 0;
    uint8_t  last_tck     = 0;
    int      pending_tdo  = 0;
    bool     have_pending = false;

    while (!Verilated::gotFinish()) {
        char cmd;
        char buf[4096];
        ssize_t n = read(bb_fd, buf, sizeof(buf));
        if (n > 0) {
            for (ssize_t i = 0; i < n; ++i) {
                char cmd = buf[i];
            if (cmd == 'Q' || cmd == 'q') break;

            // Resets: 'r'/'s'/'t'/'u' (bit0=jtag_trst via t/u, bit1=SRST via s/u)
            if (cmd == 'r' || cmd == 's' || cmd == 't' || cmd == 'u') {
                bool srst       = (cmd == 's' || cmd == 'u');
                bool jtag_trst  = (cmd == 't' || cmd == 'u');

                // Map SRST -> SoC reset, TRST -> debug_reset
                top.rst         = srst ? 1 : 0;
                top.debug_reset = jtag_trst ? 1 : 0;

                step_cpu(top, 2);
                continue;
            }

            // Drive pins: '0'..'7' (bit2=TCK, bit1=TMS, bit0=TDI)
            if (cmd >= '0' && cmd <= '7') {
                uint8_t v       = static_cast<uint8_t>(cmd - '0');
                uint8_t new_tdi =  (v & 1u);
                uint8_t new_tms = ((v >> 1) & 1u);
                uint8_t new_tck = ((v >> 2) & 1u);

                // Apply TMS/TDI first
                top.jtag_tdi = new_tdi;
                top.jtag_tms = new_tms;

                if (new_tck != last_tck) {
                    // --- PRE-EDGE SETTLE
                    step_cpu(top, CPU_CYCLES_PER_TCK_EDGE);

                    // --- TOGGLE TCK (this creates the sampling edge)
                    top.jtag_tck = new_tck;
                    top.eval();

                    // --- POST-EDGE HOLD
                    step_cpu(top, CPU_CYCLES_PER_TCK_EDGE);

                    // Capture TDO on falling edge (1 -> 0)
                    if (last_tck == 1 && new_tck == 0) {
                        pending_tdo  = (top.jtag_tdo & 1);
                        have_pending = true;
                    }

                    last_tck = new_tck;
                    edges_seen++;
                } else {
                    // No TCK edge; small settle
                    step_cpu(top, 1);
                }

                if (edges_seen >= max_edges) break;
                continue;
            }

            // Sample TDO: 'R' -> ASCII '0'/'1'
            if (cmd == 'R') {
                char ascii = (have_pending ? pending_tdo : (top.jtag_tdo & 1)) ? '1' : '0';
                if (write(bb_fd, &ascii, 1) < 0) { perror("write"); }
                continue;
            }
        }
            // else: ignore unknown
            } else {
                // Non-blocking idle wait, but **do not** sleep 10ms every time.
                struct pollfd pfd;
                pfd.fd = bb_fd;
                pfd.events = POLLIN;
                pfd.revents = 0;
                (void)poll(&pfd, 1, 0);   // timeout = 0 ms → no artificial delay
            }
        if (edges_seen >= max_edges) break;
    }

    close(bb_fd);
    return 0;
}
