`default_nettype none

module i2c_sifive_wb (
    input  wire        wb_clk_i,
    input  wire        wb_rst_i,
    input  wire [31:0] wb_adr_i,   // Wishbone address bus
    input  wire [31:0] wb_dat_i,   // Data from CPU
    output reg  [31:0] wb_dat_o,   // Data to CPU
    input  wire        wb_we_i,    // Write Enable
    input  wire        wb_stb_i,   // Strobe
    input  wire        wb_cyc_i,   // Cycle
    output wire        wb_ack_o,   // Acknowledge
    output wire        wb_int_o,   // Interrupt to PLIC

    // I2C Open-Drain pins
    input  wire        sda_i,
    output wire        sda_o,
    output wire        sda_oe,
    input  wire        scl_i,
    output wire        scl_o,
    output wire        scl_oe
);

    // Standard Wishbone ACK (1 cycle delay)
    reg ack;
    assign wb_ack_o = ack;
    always @(posedge wb_clk_i) begin
        if (wb_rst_i) ack <= 1'b0;
        else ack <= wb_cyc_i & wb_stb_i & ~ack;
    end

    // Zephyr/SiFive Register Map
    reg [7:0] pre_lo, pre_hi;
    reg       ctrl_en, ctrl_ie;
    reg [7:0] txr, rxr;

    // Command / Status Flags
    reg cmd_start, cmd_stop, cmd_read, cmd_write, cmd_ack_val;
    reg stat_rxack, stat_busy, stat_al, stat_tip, stat_ip;
    wire tip_visible = stat_tip | cmd_start | cmd_stop | cmd_read | cmd_write;
    assign wb_int_o = ctrl_en & ctrl_ie & stat_ip;

    // FSM handshake
    reg fsm_cmd_done;

    // --- CPU WRITE ---
    always @(posedge wb_clk_i) begin
        if (wb_rst_i) begin
            pre_lo <= 8'hFF; pre_hi <= 8'hFF;
            ctrl_en <= 0; ctrl_ie <= 0;
            txr <= 0;
            cmd_start <= 0; cmd_stop <= 0; cmd_read <= 0; cmd_write <= 0; cmd_ack_val <= 0;
            stat_ip <= 0;
        end else begin
            if (wb_cyc_i && wb_stb_i && wb_we_i && ack) begin
                case (wb_adr_i[7:0])
                    8'h00: pre_lo <= wb_dat_i[7:0];
                    8'h04: pre_hi <= wb_dat_i[7:0];
                    8'h08: begin ctrl_en <= wb_dat_i[7]; ctrl_ie <= wb_dat_i[6]; end
                    8'h0C: begin
                        txr <= wb_dat_i[7:0];
`ifdef I2C_TRACE
                                                $display("[I2C] TXR <= 0x%02h", wb_dat_i[7:0]);
`endif
                    end
                    8'h10: begin
`ifdef I2C_TRACE
                        $display("[I2C] CR  <= 0x%02h", wb_dat_i[7:0]);
`endif
                        if (wb_dat_i[0]) stat_ip <= 1'b0; // IACK clears interrupt
                        if (wb_dat_i[7] || wb_dat_i[6] || wb_dat_i[5] || wb_dat_i[4]) begin
                            cmd_start   <= wb_dat_i[7];
                            cmd_stop    <= wb_dat_i[6];
                            cmd_read    <= wb_dat_i[5];
                            cmd_write   <= wb_dat_i[4];
                            cmd_ack_val <= wb_dat_i[3]; // 1 = NACK, 0 = ACK
                        end
                    end
                    default: ;
                endcase
            end

            // Clear command triggers when FSM finishes a task
            if (fsm_cmd_done) begin
                cmd_start <= 0; cmd_stop <= 0; cmd_read <= 0; cmd_write <= 0;
                stat_ip <= 1'b1; 
            end
            
            if (!ctrl_en) begin
                cmd_start <= 0; cmd_stop <= 0; cmd_read <= 0; cmd_write <= 0;
            end
        end
    end

    // --- CPU READ ---
    always @(*) begin
        wb_dat_o = 32'd0;
        case (wb_adr_i[7:0])
            8'h00: wb_dat_o[7:0] = pre_lo;
            8'h04: wb_dat_o[7:0] = pre_hi;
            8'h08: wb_dat_o[7:0] = {ctrl_en, ctrl_ie, 6'd0};
            8'h0C: wb_dat_o[7:0] = rxr;
            8'h10: wb_dat_o[7:0] = {stat_rxack, stat_busy, stat_al, 3'd0, tip_visible, stat_ip};
            default: wb_dat_o = 32'd0;
        endcase
    end

    // --------------------------------------------------------
    // I2C 4-Phase Core State Machine
    // --------------------------------------------------------
    reg [15:0] tick_cnt;
    wire       tick = (tick_cnt == 0);

    // Generate I2C bit phases based on Prescaler
    always @(posedge wb_clk_i) begin
        if (wb_rst_i || !ctrl_en) tick_cnt <= 16'd0;
        else if (tick) tick_cnt <= {pre_hi, pre_lo};
        else tick_cnt <= tick_cnt - 1;
    end

    reg [2:0] state;
    localparam S_IDLE  = 0, S_START = 1, S_DATA  = 2, S_ACK   = 3, S_STOP  = 4;

    reg [1:0] q; // Quarter-cycle phase (0 to 3)
    reg [2:0] bit_cnt; // 7 down to 0

    // Physical Pin Drivers (Open Drain: output 0, toggle Output Enable)
    reg scl_drive_low, sda_drive_low;
    assign scl_o = 1'b0; assign scl_oe = scl_drive_low;
    assign sda_o = 1'b0; assign sda_oe = sda_drive_low;

    // Clock stretching detection (we released SCL, but slave is holding it low)
    wire clock_stretching = !scl_drive_low && (scl_i == 1'b0);

    always @(posedge wb_clk_i) begin
        if (wb_rst_i || !ctrl_en) begin
            state <= S_IDLE; q <= 0; bit_cnt <= 7;
            scl_drive_low <= 0; sda_drive_low <= 0;
            stat_tip <= 0; stat_busy <= 0; stat_rxack <= 0; stat_al <= 0;
            fsm_cmd_done <= 0;
        end else begin
            fsm_cmd_done <= 0;

            case (state)
                S_IDLE: begin
                    q <= 0; bit_cnt <= 7;
                    if (!fsm_cmd_done && (cmd_start || cmd_stop || cmd_read || cmd_write)) begin
                        stat_tip <= 1'b1; // Transfer In Progress
                        if (cmd_start) state <= S_START;
                        else if (cmd_read || cmd_write) state <= S_DATA;
                        else if (cmd_stop) state <= S_STOP;
                    end else begin
                        stat_tip <= 0;
                    end
                end

                S_START: begin // Safe for Repeated START
                    stat_busy <= 1'b1;
                    if (tick) begin
                        if      (q == 0) begin scl_drive_low <= 1; sda_drive_low <= 0; q <= 1; end // SCL=0, SDA=1
                        else if (q == 1) begin scl_drive_low <= 0; sda_drive_low <= 0; q <= 2; end // SCL=1, SDA=1
                        else if (q == 2) begin scl_drive_low <= 0; sda_drive_low <= 1; q <= 3; end // SCL=1, SDA=0 (START condition)
                        else if (q == 3) begin
                            scl_drive_low <= 1; sda_drive_low <= 1; // SCL=0, SDA=0
                            q <= 0;
                            if (cmd_read || cmd_write) state <= S_DATA;
                            else if (cmd_stop) state <= S_STOP;
                            else begin fsm_cmd_done <= 1; state <= S_IDLE; end
                        end
                    end
                end

                S_DATA: begin
                    if (tick && !clock_stretching) begin
                        if      (q == 0) begin
                            scl_drive_low <= 1; // SCL=0
                            if (cmd_write) sda_drive_low <= ~txr[bit_cnt]; // 0 -> drive low, 1 -> release
                            else sda_drive_low <= 0; // Read mode -> release SDA
                            q <= 1;
                        end
                        else if (q == 1) begin scl_drive_low <= 0; q <= 2; end // SCL=1
                        else if (q == 2) begin
                            scl_drive_low <= 0; q <= 3;
                            if (cmd_read) rxr[bit_cnt] <= sda_i; // Sample SDA
                        end
                        else if (q == 3) begin
                            scl_drive_low <= 1; q <= 0; // SCL=0
                            if (bit_cnt == 0) begin bit_cnt <= 7; state <= S_ACK; end
                            else bit_cnt <= bit_cnt - 1;
                        end
                    end
                end

                S_ACK: begin
                    if (tick && !clock_stretching) begin
                        if      (q == 0) begin
                            scl_drive_low <= 1; // SCL=0
                            if (cmd_write) sda_drive_low <= 0; // Release SDA to read ACK
                            else sda_drive_low <= ~cmd_ack_val; // Send ACK(0->drive low) or NACK(1->release)
                            q <= 1;
                        end
                        else if (q == 1) begin scl_drive_low <= 0; q <= 2; end // SCL=1
                        else if (q == 2) begin
                            scl_drive_low <= 0; q <= 3;
                            if (cmd_write) stat_rxack <= sda_i; // Capture Slave ACK
                        end
                        else if (q == 3) begin
                            scl_drive_low <= 1; sda_drive_low <= 1; // Pull SDA low for safe transition
                            q <= 0;
                            if (cmd_stop) state <= S_STOP;
                            else begin fsm_cmd_done <= 1; state <= S_IDLE; end
                        end
                    end
                end

                S_STOP: begin
                    if (tick) begin
                        if      (q == 0) begin scl_drive_low <= 1; sda_drive_low <= 1; q <= 1; end // SCL=0, SDA=0
                        else if (q == 1) begin scl_drive_low <= 0; sda_drive_low <= 1; q <= 2; end // SCL=1, SDA=0
                        else if (q == 2) begin scl_drive_low <= 0; sda_drive_low <= 0; q <= 3; end // SCL=1, SDA=1 (STOP condition)
                        else if (q == 3) begin
                            stat_busy <= 0; fsm_cmd_done <= 1; state <= S_IDLE;
                        end
                    end
                end
            endcase
        end
    end
endmodule