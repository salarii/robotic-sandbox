// pwm3_to_bldc.v
module pwm3_to_bldc #(
    parameter integer DEADTIME = 3
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [2:0]  pwm_i,       // {C,B,A} or [2]=C,[1]=B,[0]=A
    input  wire [2:0]  sector_i,    // 0..5
    output wire        ah_o, al_o,
    output wire        bh_o, bl_o,
    output wire        ch_o, cl_o
);
    // Decode which phase is positive and which is negative in this sector.
    // Six-step table:
    // 0: A+ B-   1: A+ C-   2: B+ C-   3: B+ A-   4: C+ A-   5: C+ B-
    reg pos_a, neg_a, pos_b, neg_b, pos_c, neg_c;
    always @(*) begin
        pos_a=0; neg_a=0; pos_b=0; neg_b=0; pos_c=0; neg_c=0;
        case (sector_i)
            3'd0: begin pos_a=1; neg_b=1; end
            3'd1: begin pos_a=1; neg_c=1; end
            3'd2: begin pos_b=1; neg_c=1; end
            3'd3: begin pos_b=1; neg_a=1; end
            3'd4: begin pos_c=1; neg_a=1; end
            3'd5: begin pos_c=1; neg_b=1; end
            default: ; // all off
        endcase
    end

    // Desired raw gates: modulate only the "active" side with that phase's PWM.
    wire ta_h = pos_a ? pwm_i[0] : 1'b0;
    wire ta_l = neg_a ? pwm_i[0] : 1'b0;
    wire tb_h = pos_b ? pwm_i[1] : 1'b0;
    wire tb_l = neg_b ? pwm_i[1] : 1'b0;
    wire tc_h = pos_c ? pwm_i[2] : 1'b0;
    wire tc_l = neg_c ? pwm_i[2] : 1'b0;

    halfbridge_deadtime #(.DEADTIME(DEADTIME)) A (.clk(clk), .rst(rst), .target_h(ta_h), .target_l(ta_l), .gate_h(ah_o), .gate_l(al_o));
    halfbridge_deadtime #(.DEADTIME(DEADTIME)) B (.clk(clk), .rst(rst), .target_h(tb_h), .target_l(tb_l), .gate_h(bh_o), .gate_l(bl_o));
    halfbridge_deadtime #(.DEADTIME(DEADTIME)) C (.clk(clk), .rst(rst), .target_h(tc_h), .target_l(tc_l), .gate_h(ch_o), .gate_l(cl_o));
endmodule
