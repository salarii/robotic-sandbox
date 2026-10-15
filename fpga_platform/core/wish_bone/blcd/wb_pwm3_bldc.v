// wb_pwm3_bldc.v
module wb_pwm3_bldc #(
    parameter integer TIMER_WIDTH   = 16,
    parameter [TIMER_WIDTH-1:0] RELOAD_RESET = 16'd1000,
    parameter integer DEADTIME = 3
)(
    // Wishbone
    input  wire        wb_clk_i,
    input  wire        wb_rst_i,
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    input  wire        wb_we_i,
    input  wire [3:0]  wb_sel_i,
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    output wire [31:0] wb_dat_o,
    output wire        wb_ack_o,

    // Commutation sector (0..5). Drive from your commutator / firmware.
    input  wire [2:0]  sector_i,

    // BLDC gate outputs
    output wire        ah_o, al_o,
    output wire        bh_o, bl_o,
    output wire        ch_o, cl_o
);
    wire [2:0] pwm;

    wb_pwm3 #(
        .TIMER_WIDTH(TIMER_WIDTH),
        .RELOAD_RESET(RELOAD_RESET)
    ) u_pwm (
        .wb_clk_i, .wb_rst_i, .wb_cyc_i, .wb_stb_i, .wb_we_i, .wb_sel_i, .wb_adr_i, .wb_dat_i,
        .wb_dat_o, .wb_ack_o,
        .pwm_o(pwm)
    );

    pwm3_to_bldc #(.DEADTIME(DEADTIME)) u_map (
        .clk(wb_clk_i), .rst(wb_rst_i),
        .pwm_i(pwm),
        .sector_i(sector_i),
        .ah_o, .al_o, .bh_o, .bl_o, .ch_o, .cl_o
    );
endmodule
