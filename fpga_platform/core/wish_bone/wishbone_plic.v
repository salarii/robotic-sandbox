`timescale 1ns/1ps

module wishbone_plic (
    input wire          clk,
    input wire          rst,

    // Wishbone Interface
    input wire          wb_cyc_i,
    input wire          wb_stb_i,
    input wire          wb_we_i,
    input wire [31:0]   wb_adr_i,
    input wire [31:0]   wb_dat_i,
    output reg [31:0]   wb_dat_o,
    output reg          wb_ack_o,

    // Interrupt sources
    input wire [7:0]    irq_sources,

    // CPU interrupt line
    output reg          irq_to_cpu
);

// Registers and internal signals
reg [2:0] priority0, priority1, priority2, priority3, priority4, priority5, priority6, priority7;

reg [7:0] pending;
reg [7:0] enable;
reg [2:0] threshold;

reg [3:0] claim_id;
reg [3:0] claim_next; 
integer i;
reg [2:0] max_priority;
// Wishbone classic handshake: one ACK per STB assertion
reg  served;
wire req     = wb_cyc_i & wb_stb_i;
wire ready   = 1'b1;                 // no wait states today
wire accept  = req & ready & ~served;
// Track in-service interrupts (claimed but not yet completed)
reg [7:0] in_service;

// Wishbone read/write
always @(posedge clk or posedge rst) begin
    if (rst) begin
        wb_dat_o <= 32'd0;
        wb_ack_o <= 1'b0;
        served   <= 1'b0;
        threshold <= 3'd0;
        in_service <= 8'd0;
        enable <= 8'd0;
        pending <= 8'd0;
        irq_to_cpu <= 1'b0;
        priority0 <= 3'd0;
        priority1 <= 3'd0;
        priority2 <= 3'd0;
        priority3 <= 3'd0;
        priority4 <= 3'd0;
        priority5 <= 3'd0;
        priority6 <= 3'd0;
        priority7 <= 3'd0;
        claim_id  <= 4'd0;
    end else begin
        // One-cycle ACK exactly when we accept a transfer
        wb_ack_o <= accept;
        if (!req)       served <= 1'b0;      // STB/CYC dropped → allow next
        else if (accept) served <= 1'b1;      // block re-ACK while STB held
 

        if (accept & wb_we_i) begin
            case (wb_adr_i)

                32'h0000_0004: priority0 <= wb_dat_i[2:0];
                32'h0000_0008: priority1 <= wb_dat_i[2:0];
                32'h0000_000C: priority2 <= wb_dat_i[2:0];
                32'h0000_0010: priority3 <= wb_dat_i[2:0];
                32'h0000_0014: priority4 <= wb_dat_i[2:0];
                32'h0000_0018: priority5 <= wb_dat_i[2:0];
                32'h0000_001C: priority6 <= wb_dat_i[2:0];
                32'h0000_0020: priority7 <= wb_dat_i[2:0];
                32'h0000_2000:
                    enable <= wb_dat_i[7:0];

                32'h0020_0000:
                    threshold <= wb_dat_i[2:0];

                32'h0020_0004: begin
                    // COMPLETE: writing ID clears in_service for that source
                    if (wb_dat_i[3:0] != 4'd0 && wb_dat_i[3:0] <= 4'd8) begin
                        in_service[wb_dat_i[3:0]-1] <= 1'b0;
                    end
                end
            endcase
        end else if (accept & ~wb_we_i) begin
            case (wb_adr_i)
                32'h0000_1000:
                    // pending bitmap read (PLIC style): bit0 is 0, bit id mirrors source id
                    wb_dat_o <= {23'd0, pending, 1'b0};

                // Optional readbacks for debug/consistency
                32'h0000_0004: wb_dat_o <= {29'd0, priority0};
                32'h0000_0008: wb_dat_o <= {29'd0, priority1};
                32'h0000_000C: wb_dat_o <= {29'd0, priority2};
                32'h0000_0010: wb_dat_o <= {29'd0, priority3};
                32'h0000_0014: wb_dat_o <= {29'd0, priority4};
                32'h0000_0018: wb_dat_o <= {29'd0, priority5};
                32'h0000_001C: wb_dat_o <= {29'd0, priority6};
                32'h0000_0020: wb_dat_o <= {29'd0, priority7};
                32'h0000_2000: wb_dat_o <= {24'd0, enable};
                32'h0020_0000: wb_dat_o <= {29'd0, threshold};


                32'h0020_0004: begin
                    // CLAIM: return winner; mark it in-service and clear pending
                    wb_dat_o <= {28'd0, claim_id};
                    if (claim_id != 4'd0) begin
                        in_service[claim_id - 1] <= 1'b1;
                        pending[claim_id - 1]    <= 1'b0;
                    end

                end

                default: wb_dat_o <= 32'd0;
            endcase
        end

        // Set pending interrupts
        for (i = 0; i < 8; i = i + 1) begin
            if (irq_sources[i] && !in_service[i])
                pending[i] <= 1'b1;       // set if line high and not already claimed
        end

              // Claim Logic (Highest Priority)
        claim_next   = 4'd0;
        max_priority = threshold;
        if (pending[0] && enable[0] && !in_service[0] && (priority0 > max_priority)) begin
            max_priority = priority0; claim_next = 4'd1;
        end
        if (pending[1] && enable[1] && !in_service[1] && (priority1 > max_priority)) begin
            max_priority = priority1; claim_next = 4'd2;
        end
        if (pending[2] && enable[2] && !in_service[2] && (priority2 > max_priority)) begin
            max_priority = priority2; claim_next = 4'd3;
        end
        if (pending[3] && enable[3] && !in_service[3] && (priority3 > max_priority)) begin
            max_priority = priority3; claim_next = 4'd4;
        end
        if (pending[4] && enable[4] && !in_service[4] && (priority4 > max_priority)) begin
            max_priority = priority4; claim_next = 4'd5;
        end
        if (pending[5] && enable[5] && !in_service[5] && (priority5 > max_priority)) begin
            max_priority = priority5; claim_next = 4'd6;
        end
        if (pending[6] && enable[6] && !in_service[6] && (priority6 > max_priority)) begin
            max_priority = priority6; claim_next = 4'd7;
        end
        if (pending[7] && enable[7] && !in_service[7] && (priority7 > max_priority)) begin
            max_priority = priority7; claim_next = 4'd8;
        end

        // Register the chosen winner and drive MEIP from the *new* winner
        claim_id   <= claim_next;
        irq_to_cpu <= (claim_next != 4'd0);

    end
end

endmodule
