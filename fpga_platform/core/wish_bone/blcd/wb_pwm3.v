// wb_pwm3.v
// Simple 3-channel PWM with Wishbone interface
// Outputs high when setLow < timer < setHigh
// MIT License

module wb_pwm3 #(
    parameter integer TIMER_WIDTH   = 16,         // width of timer and compare values (<=32)
    parameter [TIMER_WIDTH-1:0] RELOAD_RESET = 16'd1000 // default period on reset
)(
    // Wishbone Classic signals (B4-friendly, single-cycle ack)
    input  wire                 wb_clk_i,
    input  wire                 wb_rst_i,   // synchronous, active-high
    input  wire                 wb_cyc_i,
    input  wire                 wb_stb_i,
    input  wire                 wb_we_i,
    input  wire [3:0]           wb_sel_i,
    input  wire [31:0]          wb_adr_i,   // byte address; word at [4:2]
    input  wire [31:0]          wb_dat_i,
    output reg  [31:0]          wb_dat_o,
    output reg                  wb_ack_o,

    // PWM outputs
    output wire [2:0]           pwm_o
);

    // ----------------------------
    // Address decode (word address)
    // ----------------------------
    localparam REG_PWM0_LOW   = 3'd0; // 0x00
    localparam REG_PWM0_HIGH  = 3'd1; // 0x04
    localparam REG_PWM1_LOW   = 3'd2; // 0x08
    localparam REG_PWM1_HIGH  = 3'd3; // 0x0C
    localparam REG_PWM2_LOW   = 3'd4; // 0x10
    localparam REG_PWM2_HIGH  = 3'd5; // 0x14
    localparam REG_RELOAD     = 3'd6; // 0x18

    wire [2:0] word_addr = wb_adr_i[4:2];

    // ----------------------------
    // Registers (store as 32-bit; use low TIMER_WIDTH bits)
    // ----------------------------
    reg [31:0] pwm_low [0:2];
    reg [31:0] pwm_high[0:2];
    reg [31:0] reload_reg;

    // Timer
    reg [TIMER_WIDTH-1:0] timer;

    // ----------------------------
    // Write helpers (byte enables)
    // ----------------------------
    function [31:0] apply_sel_write;
        input [31:0] oldv;
        input [31:0] newv;
        input [3:0]  sel;
        begin
            apply_sel_write = oldv;
            if (sel[0]) apply_sel_write[7:0]   = newv[7:0];
            if (sel[1]) apply_sel_write[15:8]  = newv[15:8];
            if (sel[2]) apply_sel_write[23:16] = newv[23:16];
            if (sel[3]) apply_sel_write[31:24] = newv[31:24];
        end
    endfunction

    // ----------------------------
    // Wishbone ACK (single-cycle)
    // ----------------------------
    wire wb_access = wb_cyc_i & wb_stb_i;
    always @(posedge wb_clk_i) begin
        if (wb_rst_i) begin
            wb_ack_o <= 1'b0;
        end else begin
            // Pulse ack for each access
            wb_ack_o <= wb_access & ~wb_ack_o;
        end
    end

    // ----------------------------
    // Register read mux
    // ----------------------------
    always @(*) begin
        case (word_addr)
            REG_PWM0_LOW:   wb_dat_o = pwm_low[0];
            REG_PWM0_HIGH:  wb_dat_o = pwm_high[0];
            REG_PWM1_LOW:   wb_dat_o = pwm_low[1];
            REG_PWM1_HIGH:  wb_dat_o = pwm_high[1];
            REG_PWM2_LOW:   wb_dat_o = pwm_low[2];
            REG_PWM2_HIGH:  wb_dat_o = pwm_high[2];
            REG_RELOAD:     wb_dat_o = reload_reg;
            default:        wb_dat_o = 32'h0000_0000;
        endcase
    end

    // ----------------------------
    // Writes and reset defaults
    // ----------------------------
    integer i;
    always @(posedge wb_clk_i) begin
        if (wb_rst_i) begin
            // Safe defaults: all thresholds 0, reload to RELOAD_RESET
            for (i = 0; i < 3; i = i + 1) begin
                pwm_low[i]  <= 32'd0;
                pwm_high[i] <= 32'd0;
            end
            reload_reg <= {{(32-TIMER_WIDTH){1'b0}}, RELOAD_RESET};
        end else if (wb_access && wb_we_i && ~wb_ack_o) begin
            case (word_addr)
                REG_PWM0_LOW:   pwm_low[0]  <= apply_sel_write(pwm_low[0],  wb_dat_i, wb_sel_i);
                REG_PWM0_HIGH:  pwm_high[0] <= apply_sel_write(pwm_high[0], wb_dat_i, wb_sel_i);
                REG_PWM1_LOW:   pwm_low[1]  <= apply_sel_write(pwm_low[1],  wb_dat_i, wb_sel_i);
                REG_PWM1_HIGH:  pwm_high[1] <= apply_sel_write(pwm_high[1], wb_dat_i, wb_sel_i);
                REG_PWM2_LOW:   pwm_low[2]  <= apply_sel_write(pwm_low[2],  wb_dat_i, wb_sel_i);
                REG_PWM2_HIGH:  pwm_high[2] <= apply_sel_write(pwm_high[2], wb_dat_i, wb_sel_i);
                REG_RELOAD:     reload_reg  <= apply_sel_write(reload_reg,  wb_dat_i, wb_sel_i);
                default: /* no-op */;
            endcase
        end
    end

    // ----------------------------
    // Timer increment & wrap
    // Wrap when timer >= reload
    // ----------------------------
    always @(posedge wb_clk_i) begin
        if (wb_rst_i) begin
            timer <= {TIMER_WIDTH{1'b0}};
        end else begin
            if (timer >= reload_reg[TIMER_WIDTH-1:0]) begin
                timer <= {TIMER_WIDTH{1'b0}};
            end else begin
                timer <= timer + {{(TIMER_WIDTH-1){1'b0}}, 1'b1};
            end
        end
    end

    // ----------------------------
    // PWM outputs: 1 if (low < timer < high)
    // ----------------------------
    wire [TIMER_WIDTH-1:0] low0  = pwm_low[0] [TIMER_WIDTH-1:0];
    wire [TIMER_WIDTH-1:0] high0 = pwm_high[0][TIMER_WIDTH-1:0];
    wire [TIMER_WIDTH-1:0] low1  = pwm_low[1] [TIMER_WIDTH-1:0];
    wire [TIMER_WIDTH-1:0] high1 = pwm_high[1][TIMER_WIDTH-1:0];
    wire [TIMER_WIDTH-1:0] low2  = pwm_low[2] [TIMER_WIDTH-1:0];
    wire [TIMER_WIDTH-1:0] high2 = pwm_high[2][TIMER_WIDTH-1:0];

    assign pwm_o[0] = (timer > low0)  & (timer < high0);
    assign pwm_o[1] = (timer > low1)  & (timer < high1);
    assign pwm_o[2] = (timer > low2)  & (timer < high2);

endmodule
