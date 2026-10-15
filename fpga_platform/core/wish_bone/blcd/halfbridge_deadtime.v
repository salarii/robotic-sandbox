// halfbridge_deadtime.v
module halfbridge_deadtime #(
    parameter integer DEADTIME = 3  // cycles of break-before-make
)(
    input  wire clk,
    input  wire rst,       // sync, active high
    input  wire target_h,  // desired high-side gate
    input  wire target_l,  // desired low-side gate
    output reg  gate_h,
    output reg  gate_l
);
    localparam [1:0] NONE=2'b00, WANT_H=2'b01, WANT_L=2'b10;
    reg [1:0] pend;
    reg [$clog2(DEADTIME+1)-1:0] dt_cnt;

    wire desire_h =  target_h & ~target_l; // safety: if both requested, treat as none
    wire desire_l =  target_l & ~target_h;

    always @(posedge clk) begin
        if (rst) begin
            gate_h <= 1'b0;
            gate_l <= 1'b0;
            pend   <= NONE;
            dt_cnt <= '0;
        end else begin
            if (dt_cnt != 0) begin
                dt_cnt <= dt_cnt - 1'b1;
                if (dt_cnt == 1) begin
                    // end of deadtime → enable pending side
                    if (pend == WANT_H) gate_h <= 1'b1;
                    if (pend == WANT_L) gate_l <= 1'b1;
                    pend <= NONE;
                end
            end else begin
                // Not in deadtime
                if (desire_h) begin
                    // Same-side PWM allowed without deadtime
                    if (gate_l) begin
                        gate_l <= 1'b0;  // switching sides → insert deadtime
                        gate_h <= 1'b0;
                        pend   <= WANT_H;
                        dt_cnt <= DEADTIME[$clog2(DEADTIME+1)-1:0];
                    end else begin
                        gate_h <= target_h;
                    end
                end else if (desire_l) begin
                    if (gate_h) begin
                        gate_h <= 1'b0;
                        gate_l <= 1'b0;
                        pend   <= WANT_L;
                        dt_cnt <= DEADTIME[$clog2(DEADTIME+1)-1:0];
                    end else begin
                        gate_l <= target_l;
                    end
                end else begin
                    // Tri-state / both off
                    gate_h <= 1'b0;
                    gate_l <= 1'b0;
                end
            end
        end
    end
endmodule
