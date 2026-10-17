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

// --- UART Software Deserializer ---
static void update_uart_rx(Vwishbone_top& top) {
    static enum { IDLE, START, DATA, STOP } state = IDLE;
    static unsigned cycle_cnt = 0;
    static int bit_idx = 0;
    static uint8_t rx_byte = 0;
    const unsigned CYCLES_PER_BIT = 434; // 50MHz clock / 115200 baud

    switch (state) {
        case IDLE:
            if (top.stx_pad_o == 0) { state = START; cycle_cnt = 0; }
            break;
        case START:
            if (++cycle_cnt >= CYCLES_PER_BIT / 2) {
                if (top.stx_pad_o == 0) { state = DATA; cycle_cnt = 0; bit_idx = 0; rx_byte = 0; }
                else { state = IDLE; }
            }
            break;
        case DATA:
            if (++cycle_cnt >= CYCLES_PER_BIT) {
                cycle_cnt = 0;
                rx_byte |= (top.stx_pad_o & 1) << bit_idx++;
                if (bit_idx == 8) state = STOP;
            }
            break;
        case STOP:
            if (++cycle_cnt >= CYCLES_PER_BIT) {
                putchar(rx_byte);
                fflush(stdout);
                state = IDLE;
            }
            break;
    }
}

static inline void step_cpu(Vwishbone_top& top, unsigned cycles) {
    for (unsigned i = 0; i < cycles; ++i) {
        top.clk = 0; top.eval();
        top.clk = 1; top.eval();
        update_uart_rx(top);
    }
}

static void handle_sig(int) {
    _exit(0);
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

    // Non-blocking Server Socket Setup for Remote Bitbang
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd >= 0) {
        int opt = 1;
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        fcntl(server_fd, F_SETFL, O_NONBLOCK);
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port = htons(5555);
        bind(server_fd, (sockaddr*)&addr, sizeof(addr));
        listen(server_fd, 1);
        printf("Verilator listening on port 5555. UART mapped to stdout.\n");
    }
    int bb_fd = -1;

    // Initial pin states
    top.clk         = 0;
    top.rst         = 1;   // assume active-high reset
    top.debug_reset = 1;

    // JTAG idle
    top.jtag_tck = 0;
    top.jtag_tms = 1;
    top.jtag_tdi = 0;

    // UART inputs (others are ignored internally)
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
        // 1. Accept OpenOCD if it connects
        if (bb_fd < 0 && server_fd >= 0) {
            sockaddr_in addr{};
            socklen_t len = sizeof(addr);
            bb_fd = accept(server_fd, (sockaddr*)&addr, &len);
            if (bb_fd >= 0) {
                fcntl(bb_fd, F_SETFL, O_NONBLOCK);
                int nodelay = 1;
                setsockopt(bb_fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, sizeof(nodelay));
                printf("\n[OpenOCD Connected!]\n");
            }
        }

        // 2. Process JTAG commands if connected
        char buf[4096];
        ssize_t n = (bb_fd >= 0) ? read(bb_fd, buf, sizeof(buf)) : -1;
        
        if (n > 0) {
            for (ssize_t i = 0; i < n; ++i) {
                char cmd = buf[i];
                if (cmd == 'Q' || cmd == 'q') break;

                // Resets: 'r'/'s'/'t'/'u'
                if (cmd == 'r' || cmd == 's' || cmd == 't' || cmd == 'u') {
                    bool srst       = (cmd == 's' || cmd == 'u');
                    bool jtag_trst  = (cmd == 't' || cmd == 'u');

                    top.rst         = srst ? 1 : 0;
                    top.debug_reset = jtag_trst ? 1 : 0;

                    step_cpu(top, 2);
                    continue;
                }

                // Drive pins: '0'..'7'
                if (cmd >= '0' && cmd <= '7') {
                    uint8_t v       = static_cast<uint8_t>(cmd - '0');
                    uint8_t new_tdi =  (v & 1u);
                    uint8_t new_tms = ((v >> 1) & 1u);
                    uint8_t new_tck = ((v >> 2) & 1u);

                    top.jtag_tdi = new_tdi;
                    top.jtag_tms = new_tms;

                    if (new_tck != last_tck) {
                        step_cpu(top, CPU_CYCLES_PER_TCK_EDGE);
                        top.jtag_tck = new_tck;
                        top.eval();
                        step_cpu(top, CPU_CYCLES_PER_TCK_EDGE);

                        if (last_tck == 1 && new_tck == 0) {
                            pending_tdo  = (top.jtag_tdo & 1);
                            have_pending = true;
                        }
                        last_tck = new_tck;
                        edges_seen++;
                    } else {
                        step_cpu(top, 1);
                    }

                    if (edges_seen >= max_edges) break;
                    continue;
                }

                // Sample TDO: 'R'
                if (cmd == 'R') {
                    char ascii = (have_pending ? pending_tdo : (top.jtag_tdo & 1)) ? '1' : '0';
                    if (write(bb_fd, &ascii, 1) < 0) { perror("write"); }
                    continue;
                }
            }
        } else if (n == 0 && bb_fd >= 0) {
            // OpenOCD disconnected
            close(bb_fd);
            bb_fd = -1;
            printf("\n[OpenOCD Disconnected]\n");
        } else {
            // No JTAG commands this loop; just run the CPU autonomously
            step_cpu(top, 100);
        }

        if (edges_seen >= max_edges) break;
    }

    if (bb_fd >= 0) close(bb_fd);
    if (server_fd >= 0) close(server_fd);
    return 0;
}