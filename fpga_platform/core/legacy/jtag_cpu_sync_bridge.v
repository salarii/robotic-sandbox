`timescale 1ns/1ps

module jtag_cpu_sync_bridge(
    input  wire        clk,           // CPU clock
    input  wire        rst_clk,       // Reset for CPU clock domain
    input  wire        tck,           // JTAG/TAP clock
    input  wire        rst_tck,       // Reset for JTAG/TAP clock domain

    // JTAG/TAP domain input (to CPU)
    input  wire [40:0] cmd_in_jtag,   // Command from JTAG FIFO
    input  wire        cmd_valid_jtag,

    // Synchronized outputs to CPU domain
    output wire [40:0] cmd_out_cpu,
    output wire        cmd_valid_cpu,

    // CPU domain input (to JTAG)
    input  wire [31:0] rsp_in_cpu,    // Response from CPU
    input  wire        rsp_valid_cpu,

    // Synchronized outputs to JTAG domain
    output wire [31:0] rsp_out_jtag,
    output wire        rsp_valid_jtag
);
    reg  [40:0] cmd_hold_jtag;
    reg         cmd_req_tgl_jtag;
    wire        cmd_ack_tgl_jtag_sync;   // ack synced into TCK

    // CPU (dest)
    wire        cmd_req_tgl_cpu_sync;    // req synced into CLK
    reg         cmd_req_tgl_cpu_d;
    reg  [40:0] cmd_out_cpu_r;
    reg         cmd_valid_cpu_r;
    reg         cmd_ack_tgl_cpu;         // ack generated in CLK

    assign cmd_out_cpu   = cmd_out_cpu_r;
    assign cmd_valid_cpu = cmd_valid_cpu_r;

    // Sync toggles (1-bit)
    ff_sync #(.WIDTH(1)) u_cmd_req_sync_clk (
        .clk     (clk),
        .rst_p   (rst_clk),
        .in_async(cmd_req_tgl_jtag),
        .out     (cmd_req_tgl_cpu_sync)
    );
    ff_sync #(.WIDTH(1)) u_cmd_ack_sync_tck (
        .clk     (tck),
        .rst_p   (rst_tck),
        .in_async(cmd_ack_tgl_cpu),
        .out     (cmd_ack_tgl_jtag_sync)
    );

    // JTAG domain: capture command & flip req when not busy
    always @(posedge tck or posedge rst_tck) begin
        if (rst_tck) begin
            cmd_hold_jtag    <= {41{1'b0}};
            cmd_req_tgl_jtag <= 1'b0;
        end else begin
            // not busy when req == ack
            if (cmd_valid_jtag && (cmd_req_tgl_jtag == cmd_ack_tgl_jtag_sync)) begin
                cmd_hold_jtag    <= cmd_in_jtag;
                cmd_req_tgl_jtag <= ~cmd_req_tgl_jtag;
            end
        end
    end

    // CPU domain: on req edge, latch bus, pulse valid, flip ack
    always @(posedge clk or posedge rst_clk) begin
        if (rst_clk) begin
            cmd_req_tgl_cpu_d <= 1'b0;
            cmd_out_cpu_r     <= {41{1'b0}};
            cmd_valid_cpu_r   <= 1'b0;
            cmd_ack_tgl_cpu   <= 1'b0;
        end else begin
            cmd_valid_cpu_r <= 1'b0; // 1-cycle pulse
            if (cmd_req_tgl_cpu_sync != cmd_req_tgl_cpu_d) begin
                cmd_out_cpu_r   <= cmd_hold_jtag;   // latch stable bus
                cmd_valid_cpu_r <= 1'b1;
                cmd_ack_tgl_cpu <= ~cmd_ack_tgl_cpu;
            end
            cmd_req_tgl_cpu_d <= cmd_req_tgl_cpu_sync;
        end
    end

    // ===================== CPU -> JTAG (responses, 32b) ====================
    // CPU (source)
    reg  [31:0] rsp_hold_cpu;
    reg         rsp_req_tgl_cpu;
    wire        rsp_ack_tgl_cpu_sync;    // ack synced into CLK

    // JTAG (dest)
    wire        rsp_req_tgl_jtag_sync;   // req synced into TCK
    reg         rsp_req_tgl_jtag_d;
    reg  [31:0] rsp_out_jtag_r;
    reg         rsp_valid_jtag_r;
    reg         rsp_ack_tgl_jtag;        // ack generated in TCK

    assign rsp_out_jtag   = rsp_out_jtag_r;
    assign rsp_valid_jtag = rsp_valid_jtag_r;

    // Sync toggles (1-bit)
    ff_sync #(.WIDTH(1)) u_rsp_req_sync_tck (
        .clk     (tck),
        .rst_p   (rst_tck),
        .in_async(rsp_req_tgl_cpu),
        .out     (rsp_req_tgl_jtag_sync)
    );
    ff_sync #(.WIDTH(1)) u_rsp_ack_sync_clk (
        .clk     (clk),
        .rst_p   (rst_clk),
        .in_async(rsp_ack_tgl_jtag),
        .out     (rsp_ack_tgl_cpu_sync)
    );

    // CPU domain: launch response & flip req when not busy
    always @(posedge clk or posedge rst_clk) begin
        if (rst_clk) begin
            rsp_hold_cpu    <= 32'd0;
            rsp_req_tgl_cpu <= 1'b0;
        end else begin
            if (rsp_valid_cpu && (rsp_req_tgl_cpu == rsp_ack_tgl_cpu_sync)) begin
                rsp_hold_cpu    <= rsp_in_cpu;
                rsp_req_tgl_cpu <= ~rsp_req_tgl_cpu;
            end
        end
    end

    // JTAG domain: on req edge, latch bus, pulse valid, flip ack
    always @(posedge tck or posedge rst_tck) begin
        if (rst_tck) begin
            rsp_req_tgl_jtag_d <= 1'b0;
            rsp_out_jtag_r     <= 32'd0;
            rsp_valid_jtag_r   <= 1'b0;
            rsp_ack_tgl_jtag   <= 1'b0;
        end else begin
            rsp_valid_jtag_r <= 1'b0; // 1-cycle pulse
            if (rsp_req_tgl_jtag_sync != rsp_req_tgl_jtag_d) begin
                rsp_out_jtag_r   <= rsp_hold_cpu;   // latch stable bus
                rsp_valid_jtag_r <= 1'b1;
                rsp_ack_tgl_jtag <= ~rsp_ack_tgl_jtag;
            end
            rsp_req_tgl_jtag_d <= rsp_req_tgl_jtag_sync;
        end
    end
endmodule
