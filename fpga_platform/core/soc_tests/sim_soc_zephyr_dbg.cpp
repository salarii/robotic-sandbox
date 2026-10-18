// Verilator testbench: Zephyr SoC + OpenOCD remote_bitbang JTAG. No tracing.
//
// Environment variables (all optional):
//   SIM_TIMEOUT_CYCLES  stop after N clock cycles (0 / unset = run forever)
//   JTAG_DIV            clk cycles run after every JTAG bitbang command (default 4)
//   JTAG_PORT           TCP port for OpenOCD (default 5555)
//   WAIT_FOR_JTAG=1     keep the CPU in reset until OpenOCD connects
//
// Plusargs are passed to Verilated::commandArgs (e.g. +hex=...).

#include "Vsim_soc_zephyr.h"
#include "verilated.h"

#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

static uint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int) { g_stop = 1; }

static Vsim_soc_zephyr *top = nullptr;

// ---------------------------------------------------------------------------
// UART snoop (prints bytes the CPU writes to the 16550 THR)
// ---------------------------------------------------------------------------
static bool uart_dlab = false;

static uint64_t cycle = 0;
static uint64_t bus_log_left = 0;      // BUS_LOG=N: print first N acked data-bus transfers
static uint64_t bus_xfers = 0;
static uint32_t bus_filter = 0xFFFFFFFFu; // BUS_FILTER=60: only log addresses 0x60xxxxxx (hex top byte)

struct BusRec { uint64_t n, cyc; bool we; uint32_t adr, sel, dat; };
static const unsigned RING_N = 24;
static BusRec   ring[RING_N];
static uint64_t ring_pos = 0;

static void dump_ring() {
    uint64_t cnt = ring_pos < RING_N ? ring_pos : RING_N;
    std::fprintf(stderr, "--- last %llu data-bus transfers ---\n", (unsigned long long)cnt);
    for (uint64_t i = ring_pos - cnt; i < ring_pos; i++) {
        const BusRec &r = ring[i % RING_N];
        std::fprintf(stderr, "[bus #%llu cyc %llu] %s adr=%08x sel=%x dat=%08x\n",
                     (unsigned long long)r.n, (unsigned long long)r.cyc,
                     r.we ? "WR" : "RD", r.adr, r.sel, r.dat);
    }
}

static void uart_snoop() {
    if (!(top->dbg_dw_cyc && top->dbg_dw_stb && top->dbg_dw_ack)) return;
    uint32_t adr = top->dbg_dw_adr;
    uint32_t sel = top->dbg_dw_sel;
    uint32_t dat = top->dbg_dw_we ? top->dbg_dw_dat_m2s : top->dbg_dw_dat_s2m;
    bus_xfers++;

    {   // keep the last 24 transfers for the timeout report
        BusRec &r = ring[ring_pos++ % RING_N];
        r.n = bus_xfers; r.cyc = cycle; r.we = top->dbg_dw_we; r.adr = adr; r.sel = sel; r.dat = dat;
    }

    if (bus_log_left && (bus_filter == 0xFFFFFFFFu || (adr >> 24) == bus_filter)) {
        bus_log_left--;
        std::fprintf(stderr, "[bus #%llu cyc %llu] %s adr=%08x sel=%x dat=%08x\n",
                     (unsigned long long)bus_xfers, (unsigned long long)cycle,
                     top->dbg_dw_we ? "WR" : "RD", adr, sel, dat);
    }

    if (!top->dbg_dw_we) return;
    if ((adr & ~0x1Fu) != 0x10000000u) return;

    // uart_wb in 32-bit mode: register = { adr[2], byte lane taken from sel }
    uint32_t lane = (sel & 1) ? 0 : (sel & 2) ? 1 : (sel & 4) ? 2 : 3;
    uint32_t reg  = (((adr >> 2) & 1) << 2) | lane;
    uint8_t  b    = (top->dbg_dw_dat_m2s >> (8 * lane)) & 0xFF;

    if (reg == 3) {                    // LCR: track DLAB
        uart_dlab = (b & 0x80) != 0;
    } else if (reg == 0 && !uart_dlab) { // THR (not the baud divisor)
        std::putchar((char)b);
        std::fflush(stdout);
    }
}

// ---------------------------------------------------------------------------
// One full clock cycle
// ---------------------------------------------------------------------------
static inline void tick() {
    top->clk = 0;
    top->eval();
    main_time++;
    uart_snoop();                      // sampled just before the rising edge
    top->clk = 1;
    top->eval();
    main_time++;
    cycle++;
}

static inline void ticks(unsigned n) {
    while (n--) tick();
}

// ---------------------------------------------------------------------------
// Remote bitbang
// ---------------------------------------------------------------------------
static void jtag_idle_pins() {
    top->jtag_tck = 0;
    top->jtag_tms = 1;
    top->jtag_tdi = 0;
    top->eval();
}

static bool send_byte(int fd, char c) {
    for (;;) {
        ssize_t n = send(fd, &c, 1, MSG_NOSIGNAL);
        if (n == 1) return true;
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        return false;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);

    const char *e;
    uint64_t max_cycles = (e = std::getenv("SIM_TIMEOUT_CYCLES")) ? std::strtoull(e, nullptr, 0) : 0;
    unsigned jtag_div   = (e = std::getenv("JTAG_DIV")) ? (unsigned)std::strtoul(e, nullptr, 0) : 4;
    int      port       = (e = std::getenv("JTAG_PORT")) ? std::atoi(e) : 5555;
    bool     wait_jtag  = (e = std::getenv("WAIT_FOR_JTAG")) && e[0] == '1';
    if (jtag_div == 0) jtag_div = 1;
    if ((e = std::getenv("BUS_LOG"))) bus_log_left = std::strtoull(e, nullptr, 0);
    if ((e = std::getenv("BUS_FILTER"))) bus_filter = (uint32_t)std::strtoul(e, nullptr, 16);

    top = new Vsim_soc_zephyr;

    // --- listening socket ---
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); return 1; }
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    sockaddr_in addr{};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port        = htons((uint16_t)port);
    if (bind(server_fd, (sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    if (listen(server_fd, 1) < 0) { perror("listen"); return 1; }
    fcntl(server_fd, F_SETFL, O_NONBLOCK);
    std::cout << "Listening for OpenOCD JTAG connection on port " << port
              << " (JTAG_DIV=" << jtag_div << ")..." << std::endl;

    int client_fd = -1;

    // --- reset sequence ---
    top->rst = 1;
    top->debug_reset = 1;
    jtag_idle_pins();
    ticks(10);
    top->debug_reset = 0;
    if (!wait_jtag) top->rst = 0;
    else std::cout << "CPU held in reset until OpenOCD connects." << std::endl;

    std::cout << "Starting Zephyr SoC Simulation..." << std::endl;
    bool cpu_released = !wait_jtag;

    while (!Verilated::gotFinish() && !g_stop) {
        // --- accept new client ---
        if (client_fd < 0) {
            int fd = accept(server_fd, nullptr, nullptr);
            if (fd >= 0) {
                int one = 1;
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
                fcntl(fd, F_SETFL, O_NONBLOCK);
                client_fd = fd;
                jtag_idle_pins();
                std::cout << "\n[JTAG] OpenOCD connected!" << std::endl;
                if (!cpu_released) {
                    top->rst = 0;
                    cpu_released = true;
                }
            }
        }

        // --- service JTAG ---
        bool got_cmd = false;
        if (client_fd >= 0) {
            char cmd;
            ssize_t n = recv(client_fd, &cmd, 1, 0);
            if (n == 1) {
                got_cmd = true;
                bool drop = false;
                if (cmd >= '0' && cmd <= '7') {
                    int v = cmd - '0';
                    top->jtag_tck = (v >> 2) & 1;
                    top->jtag_tms = (v >> 1) & 1;
                    top->jtag_tdi = v & 1;
                    top->eval();
                } else if (cmd == 'R') {
                    top->eval();
                    if (!send_byte(client_fd, top->jtag_tdo ? '1' : '0')) drop = true;
                } else if (cmd == 'Q') {
                    drop = true;
                }
                // 'r','s','t','u' (trst/srst), 'b','B' (blink): ignored
                if (drop) {
                    std::cout << "\n[JTAG] OpenOCD disconnected." << std::endl;
                    close(client_fd);
                    client_fd = -1;
                    jtag_idle_pins();
                }
            } else if (n == 0) {   // peer closed without 'Q'
                std::cout << "\n[JTAG] OpenOCD connection closed." << std::endl;
                close(client_fd);
                client_fd = -1;
                jtag_idle_pins();
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                std::cout << "\n[JTAG] socket error, dropping client." << std::endl;
                close(client_fd);
                client_fd = -1;
                jtag_idle_pins();
            }
        }

        // After a JTAG command give the design a few clocks so the TCK->clk
        // synchronisers settle; when idle run a larger batch to save syscalls.
        ticks(got_cmd ? jtag_div : 32);

        if (max_cycles > 0 && cycle >= max_cycles) {
            std::cout << "\n[Simulation timeout reached] cycles=" << cycle
                  << " data-bus transfers=" << bus_xfers << std::endl;
        dump_ring();
            break;
        }
    }

    if (g_stop) std::cout << "\n[Interrupted]" << std::endl;
    if (client_fd >= 0) close(client_fd);
    close(server_fd);
    top->final();
    delete top;
    return 0;
}