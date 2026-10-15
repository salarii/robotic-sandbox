// tap_sys_bus_cdc.v
// Bi-directional bus transfer between system clock domain and TAP TCK domain
// Only synchronizes single-bit toggles; data bus is sampled once when toggle edge arrives.
// Avoids per-bit 2FF chains.

module tap_sys_bus_cdc #(
    parameter WIDTH = 8
)(
    // System clock domain (outside TAP)
    input  wire              sys_clk,
    input  wire              sys_rst_n,
    input  wire [WIDTH-1:0]  sys_tx_data, // Data to send into TAP
    input  wire              sys_load,    // 1-cycle pulse: request send sys->tap
    output reg               sys_busy,    // high while transfer in flight sys->tap
    output reg  [WIDTH-1:0]  sys_rx_data, // data received from TAP
    output reg               sys_rx_pulse,// 1-cycle pulse when new data from TAP

    // TAP clock domain (tap_tck)
    input  wire              tap_tck,
    input  wire              tap_rst_n,
    input  wire [WIDTH-1:0]  tap_tx_data, // Data to send to system domain
    input  wire              tap_load,    // 1-cycle pulse: request send tap->sys
    output reg               tap_busy,    // high while transfer in flight tap->sys
    output reg  [WIDTH-1:0]  tap_rx_data, // data received from system domain
    output reg               tap_rx_pulse // 1-cycle pulse when new data from system
);

    // =========================================================
    // Sys -> TAP path
    // =========================================================
    reg [WIDTH-1:0] sys_latch;
    reg             sys_tgl;
    reg             tap_tgl_a1, tap_tgl_a2; // sync sys_tgl into TAP
    reg             tap_ack_tgl;
    reg             sys_ack_a1, sys_ack_a2; // sync tap_ack_tgl into SYS
    reg             sys_ack_seen;

    // =========================================================
    // TAP -> Sys path
    // =========================================================
    reg [WIDTH-1:0] tap_latch;
    reg             tap_tgl;
    reg             sys_tgl_b1, sys_tgl_b2; // sync tap_tgl into SYS
    reg             sys_ack_tgl;
    reg             tap_ack_b1, tap_ack_b2; // sync sys_ack_tgl into TAP
    reg             tap_ack_seen;

    reg sys_tgl_last;
    reg tap_tgl_last;

    // =========================================================
    // System clock domain logic
    // =========================================================
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sys_latch      <= {WIDTH{1'b0}};
            sys_tgl        <= 1'b0;
            sys_busy       <= 1'b0;
            sys_ack_a1     <= 1'b0;
            sys_ack_a2     <= 1'b0;
            sys_ack_seen   <= 1'b0;

            sys_tgl_b1     <= 1'b0;
            sys_tgl_b2     <= 1'b0;
            sys_tgl_last   <= 1'b0;
            sys_rx_data    <= {WIDTH{1'b0}};
            sys_rx_pulse   <= 1'b0;

            sys_ack_tgl    <= 1'b0;
        end else begin
            // sync ack from TAP for sys->tap channel
            sys_ack_a1 <= tap_ack_tgl;
            sys_ack_a2 <= sys_ack_a1;

            // start transfer to TAP
            if (sys_load && !sys_busy) begin
                sys_latch <= sys_tx_data;
                sys_tgl   <= ~sys_tgl;
                sys_busy  <= 1'b1;
            end
            // complete when ack toggled
            if (sys_busy && (sys_ack_a2 != sys_ack_seen)) begin
                sys_ack_seen <= sys_ack_a2;
                sys_busy     <= 1'b0;
            end

            // sync TAP toggle into SYS for tap->sys channel
            sys_tgl_b1 <= tap_tgl;
            sys_tgl_b2 <= sys_tgl_b1;

            sys_rx_pulse <= 1'b0;
            if (sys_tgl_b2 != sys_tgl_last) begin
                sys_tgl_last <= sys_tgl_b2;
                sys_rx_data  <= tap_latch;
                sys_rx_pulse <= 1'b1;
                sys_ack_tgl  <= ~sys_ack_tgl;
            end
        end
    end

    // =========================================================
    // TAP TCK domain logic
    // =========================================================
    always @(posedge tap_tck or negedge tap_rst_n) begin
        if (!tap_rst_n) begin
            tap_latch      <= {WIDTH{1'b0}};
            tap_tgl        <= 1'b0;
            tap_busy       <= 1'b0;
            tap_ack_b1     <= 1'b0;
            tap_ack_b2     <= 1'b0;
            tap_ack_seen   <= 1'b0;

            tap_tgl_a1     <= 1'b0;
            tap_tgl_a2     <= 1'b0;
            tap_tgl_last   <= 1'b0;
            tap_rx_data    <= {WIDTH{1'b0}};
            tap_rx_pulse   <= 1'b0;

            tap_ack_tgl    <= 1'b0;
        end else begin
            // sync ack from SYS for tap->sys channel
            tap_ack_b1 <= sys_ack_tgl;
            tap_ack_b2 <= tap_ack_b1;

            // start transfer to SYS
            if (tap_load && !tap_busy) begin
                tap_latch <= tap_tx_data;
                tap_tgl   <= ~tap_tgl;
                tap_busy  <= 1'b1;
            end
            if (tap_busy && (tap_ack_b2 != tap_ack_seen)) begin
                tap_ack_seen <= tap_ack_b2;
                tap_busy     <= 1'b0;
            end

            // sync SYS toggle into TAP for sys->tap channel
            tap_tgl_a1 <= sys_tgl;
            tap_tgl_a2 <= tap_tgl_a1;

            tap_rx_pulse <= 1'b0;
            if (tap_tgl_a2 != tap_tgl_last) begin
                tap_tgl_last <= tap_tgl_a2;
                tap_rx_data  <= sys_latch;
                tap_rx_pulse <= 1'b1;
                tap_ack_tgl  <= ~tap_ack_tgl;
            end
        end
    end

endmodule
