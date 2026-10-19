`timescale 1ns/1ps
`default_nettype none

// ---------------------------------------------------------------------------
// Simulation-only stand-in for the ADS1115 chip.
// It does NOT exist in real hardware; the real chip does the same job there.
//
// What it does:
//   - watches SCL/SDA on the I2C bus
//   - when the master sends address 0x48, it pulls SDA low during the 9th
//     clock (this is the ACK). Without this, the master reads a NACK -> -EIO.
//   - keeps the ADS1115 registers: 0 = conversion, 1 = config,
//     2 = low threshold, 3 = high threshold
//   - write transfer: first byte = pointer register, then 2 data bytes
//   - read transfer: sends 2 bytes (MSB first) of the register selected
//     by the pointer
//
// Open-drain: this module only ever pulls SDA low (sda_low = 1) or lets go.
// ---------------------------------------------------------------------------
module ads1115_model #(
    parameter [6:0]  I2C_ADDR = 7'h48,
    parameter [15:0] SAMPLE   = 16'h1234   // fake ADC value
)(
    input  wire clk,
    input  wire rst,
    input  wire scl,       // resolved bus level of SCL
    input  wire sda_in,    // resolved bus level of SDA
    output reg  sda_low    // 1 = this slave pulls SDA low
);

    localparam ST_IDLE     = 0;
    localparam ST_ADDR     = 1;
    localparam ST_ADDR_ACK = 2;
    localparam ST_WR       = 3;
    localparam ST_WR_ACK   = 4;
    localparam ST_RD       = 5;
    localparam ST_RD_ACK   = 6;

    reg [2:0]  st;
    reg        scl_d, sda_d;      // previous values, for edge detection
    reg [3:0]  bitc;              // bit counter
    reg [7:0]  sh;                // shift register for received byte
    reg [7:0]  wbuf_hi;           // first data byte of a 16-bit write
    reg        rw;                // 1 = master reads
    reg        got_ptr;           // pointer byte already received
    reg        byte_idx;          // 0 = MSB byte, 1 = LSB byte
    reg        m_nack;            // master NACK seen after a read byte
    reg [1:0]  ptr;               // pointer register
    reg [15:0] cfg, lo_th, hi_th, sample;

    // Bus conditions
    wire start = scl & scl_d &  sda_d & ~sda_in;   // SDA falls while SCL high
    wire stop  = scl & scl_d & ~sda_d &  sda_in;   // SDA rises while SCL high
    wire rise  =  scl & ~scl_d;                    // SCL rising edge
    wire fall  = ~scl &  scl_d;                    // SCL falling edge

    // Value of the register selected by ptr
    reg [15:0] rdval;
    always @(*) begin
        case (ptr)
            2'd0:    rdval = sample;
            2'd1:    rdval = {1'b1, cfg[14:0]};    // OS bit = 1: conversion done
            2'd2:    rdval = lo_th;
            default: rdval = hi_th;
        endcase
    end

    // Byte currently being sent to the master
    wire [7:0] txb = byte_idx ? rdval[7:0] : rdval[15:8];

    always @(posedge clk) begin
        scl_d <= scl;
        sda_d <= sda_in;

        if (rst) begin
            st       <= ST_IDLE;
            sda_low  <= 1'b0;
            bitc     <= 4'd0;
            sh       <= 8'd0;
            wbuf_hi  <= 8'd0;
            rw       <= 1'b0;
            got_ptr  <= 1'b0;
            byte_idx <= 1'b0;
            m_nack   <= 1'b0;
            ptr      <= 2'd0;
            cfg      <= 16'h8583;
            lo_th    <= 16'h8000;
            hi_th    <= 16'h7FFF;
            sample   <= SAMPLE;
            scl_d    <= 1'b1;
            sda_d    <= 1'b1;
        end
        else if (start) begin
            // START or repeated START: next 8 bits are the address
            st      <= ST_ADDR;
            bitc    <= 4'd0;
            sda_low <= 1'b0;
        end
        else if (stop) begin
            st      <= ST_IDLE;
            sda_low <= 1'b0;
        end
        else begin
            case (st)

                // Receive 7-bit address + R/W bit
                ST_ADDR: begin
                    if (rise) begin
                        sh   <= {sh[6:0], sda_in};
                        bitc <= bitc + 4'd1;
                    end
                    else if (fall && bitc == 4'd8) begin
                        bitc <= 4'd0;
                        if (sh[7:1] == I2C_ADDR) begin
                            rw       <= sh[0];
                            byte_idx <= 1'b0;
                            if (!sh[0]) got_ptr <= 1'b0;
                            sda_low  <= 1'b1;          // ACK
                            st       <= ST_ADDR_ACK;
`ifdef I2C_TRACE
                            $display("[ADS1115] addr match, %s", sh[0] ? "READ" : "WRITE");
`endif
                        end
                        else begin
                            st <= ST_IDLE;             // not our address -> NACK
`ifdef I2C_TRACE
                            $display("[ADS1115] addr 0x%02h NOT matched", sh[7:1]);
`endif
                        end
                    end
                end

                // ACK bit finished: go to read or write data phase
                ST_ADDR_ACK: begin
                    if (fall) begin
                        if (rw) begin
                            st      <= ST_RD;
                            bitc    <= 4'd1;
                            sda_low <= ~rdval[15];     // first bit of the data
                        end
                        else begin
                            st      <= ST_WR;
                            bitc    <= 4'd0;
                            sda_low <= 1'b0;
                        end
                    end
                end

                // Master writes a byte to us
                ST_WR: begin
                    if (rise) begin
                        sh   <= {sh[6:0], sda_in};
                        bitc <= bitc + 4'd1;
                    end
                    else if (fall && bitc == 4'd8) begin
                        bitc    <= 4'd0;
                        sda_low <= 1'b1;               // ACK the byte
                        st      <= ST_WR_ACK;

                        if (!got_ptr) begin
                            ptr      <= sh[1:0];
                            got_ptr  <= 1'b1;
                            byte_idx <= 1'b0;
`ifdef I2C_TRACE
                            $display("[ADS1115] pointer <= %0d", sh[1:0]);
`endif
                        end
                        else if (!byte_idx) begin
                            wbuf_hi  <= sh;
                            byte_idx <= 1'b1;
                        end
                        else begin
                            byte_idx <= 1'b0;
                            case (ptr)
                                2'd1: begin
                                    cfg <= {wbuf_hi, sh};
                                    // OS bit set = start conversion -> new sample
                                    if (wbuf_hi[7]) sample <= sample + 16'd1;
                                end
                                2'd2: lo_th <= {wbuf_hi, sh};
                                2'd3: hi_th <= {wbuf_hi, sh};
                                default: ;
                            endcase
`ifdef I2C_TRACE
                            $display("[ADS1115] reg%0d <= 0x%02h%02h", ptr, wbuf_hi, sh);
`endif
                        end
                    end
                end

                // ACK of a written byte finished: release SDA, wait for next byte
                ST_WR_ACK: begin
                    if (fall) begin
                        sda_low <= 1'b0;
                        st      <= ST_WR;
                    end
                end

                // We send a byte to the master
                ST_RD: begin
                    if (fall) begin
                        if (bitc == 4'd8) begin
                            sda_low <= 1'b0;           // release SDA for master ACK/NACK
                            st      <= ST_RD_ACK;
                        end
                        else begin
                            sda_low <= ~txb[~bitc[2:0]];
                            bitc    <= bitc + 4'd1;
                        end
                    end
                end

                // Master ACK/NACK after our byte
                ST_RD_ACK: begin
                    if (rise) begin
                        m_nack <= sda_in;              // 1 = master NACK (end of read)
                    end
                    else if (fall) begin
                        if (m_nack) begin
                            st      <= ST_IDLE;
                            sda_low <= 1'b0;
                        end
                        else begin
                            byte_idx <= ~byte_idx;
                            sda_low  <= ~(byte_idx ? rdval[15] : rdval[7]);
                            bitc     <= 4'd1;
                            st       <= ST_RD;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

endmodule
`default_nettype wire
