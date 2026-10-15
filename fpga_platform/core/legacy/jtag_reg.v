/* jtag_reg.v
 *
 * Generic JTAG Data Register
 *
 *------------------------------------------------------------------------------
 *
 * Copyright 2018 Christopher Parish
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

`timescale 1ns/1ps

module jtag_reg #(
        parameter IR_LEN = 5,
        parameter DR_LEN = 8,
        parameter [IR_LEN-1:0] USER_OPCODE   = 5'b10010,       // USER instruction
        parameter [IR_LEN-1:0] BYPASS_OPCODE = {IR_LEN{1'b1}},
        parameter [IR_LEN-1:0] IDCODE_OPCODE = 5'b00001,     // pick what your TAP uses
        parameter [31:0]       IDCODE_VALUE = 32'h12345671
        ) (
        input tck,
        input trst,
        input tdi,
        output  tdo,
        input state_tlr,
        input state_capturedr,
        input state_shiftdr,
        input state_updatedr,
        input[IR_LEN-1:0] ir_reg,
        input[DR_LEN-1:0] dr_dataIn,
        output reg[DR_LEN-1:0] dr_dataOut,
        output reg dr_dataOutReady
    );

    reg[DR_LEN-1:0] dr_reg;
    reg bypass_reg;
    reg [31:0]          idcode_reg;    

    wire is_bypass = (ir_reg == BYPASS_OPCODE);
    wire is_idcode = (ir_reg == IDCODE_OPCODE);
    wire is_user   = (ir_reg == USER_OPCODE);


    always @(posedge tck or negedge trst) begin
        if (~trst)  begin
            dr_reg <= 0;
            dr_dataOut <= 0;
            idcode_reg      <= IDCODE_VALUE;
            dr_dataOutReady <= 0;
            bypass_reg <= 0;
        end else if (state_tlr) begin
            // SYNC reset when entering Test-Logic-Reset (on posedge tck)
            dr_reg          <= {DR_LEN{1'b0}};
            dr_dataOut      <= {DR_LEN{1'b0}};
            idcode_reg      <= IDCODE_VALUE;
            dr_dataOutReady <= 1'b0;
            bypass_reg      <= 1'b0;
        end else begin
            dr_dataOutReady <= 0;
            if (state_capturedr) begin
                
                if (is_bypass) begin
                    bypass_reg <= 0;
                end
                else if (is_idcode) begin
                    idcode_reg      <= IDCODE_VALUE;
                end
                else if (is_user)  begin
                    dr_reg <= dr_dataIn;
                end
                 
            end
            else if(state_shiftdr) begin
                if(is_user) begin
                    if(DR_LEN == 1) dr_reg[0] <= tdi;
                    else dr_reg <= {tdi, dr_reg[DR_LEN-1:1]};
                end
                else if (is_bypass) begin
                    bypass_reg <= tdi;
                end
                else if (is_idcode) begin
                    idcode_reg <= {tdi, idcode_reg[31:1]};
                end
            end 
            else if(state_updatedr) begin
                if (is_user) begin
                        dr_dataOut <= dr_reg;
                        dr_dataOutReady <= 1;
                end

            end
        end
    end


    reg tdo_dr_bit;
    always @(*) begin
    if (is_idcode)      tdo_dr_bit = idcode_reg[0];
    else if (is_user)   tdo_dr_bit = dr_reg[0];
    else /* BYPASS */   tdo_dr_bit = bypass_reg;
    end

    // 2) Register on negedge so it's stable for next device's rising-edge sample
    reg tdo_dr_q;
    always @(negedge tck or negedge trst) begin
    if (~trst)                  tdo_dr_q <= 1'b0;
    else if (state_shiftdr)     tdo_dr_q <= tdo_dr_bit;
    // else: hold last value; top-level will tri-state when not shifting
    end

    // 3) Drive the module's TDO (no tri-state here)
    assign tdo = tdo_dr_q;


endmodule
