// Minimal RISC-V DMI → VexRiscv DebugPlugin bridge
// - DMI 41b window (two-scan rule)
// - Subset DM regs: dmcontrol/dmstatus/abstractcs/command/data0
// - Access Register (read-only) for GPRs (x0..x31)
// - Memory read ("SBA-lite"): sbaddress0 + sbdata0 (read-only)
// - Halt/Step/Continue using DebugPlugin control page
//
// NOTE: This is intended for *simulation* bring-up.
//       It relies on VexRiscv DebugPlugin semantics:
//         - Control page at addr[7:2]==6'h00 (use 0x00)
//         - Injection page at addr[7:2]==6'h01 (use 0x04)
//         - Readback: last write-back value via READ at 0x04 (sample next cycle)

`timescale 1ns/1ps

module rv_dm_bridge #(
  parameter XLEN = 32
)(
  input  wire         clk,
  input  wire         reset,

  // ---------- DMI scan window ----------
  // Request presented each scan; response must be valid on the *next* scan.
  input  wire [40:0]  dmi_req,    // {addr[40:34], data[33:2], op[1:0]}
  output reg  [40:0]  dmi_rsp,    // response to previous request
  input  wire         dmi_req_stb // 1-pulse per scan (advance pipeline)
  // You can tie dmi_req_stb=1'b1 if you call this once per scan cycle.
  ,

  // ---------- VexRiscv DebugPlugin mini-bus ----------
  output reg          debug_bus_cmd_valid,
  input  wire         debug_bus_cmd_ready,
  output reg          debug_bus_cmd_payload_wr,
  output reg  [7:0]   debug_bus_cmd_payload_address,
  output reg  [31:0]  debug_bus_cmd_payload_data,
  input  wire [31:0]  debug_bus_rsp_data
);

  // --------------------------------------------
  // DMI decode
  // --------------------------------------------
  wire [6:0]  dmi_addr  = dmi_req[40:34];
  wire [31:0] dmi_wdata = dmi_req[33:2];
  wire [1:0]  dmi_op    = dmi_req[1:0];   // 2'b00 NOP, 2'b01 READ, 2'b10 WRITE

  // Pipeline previous response (two-scan rule)
  reg [31:0]  resp_data_q;
  reg [1:0]   resp_op_q;

  // Default: return previous latched response
  always @(*) begin
    dmi_rsp = { dmi_addr, resp_data_q, resp_op_q };
  end

  // --------------------------------------------
  // Minimal DM registers (shadows)
  // --------------------------------------------
  reg dmactive;
  reg haltreq;     // sticky request; we action it then clear
  reg resumereq;   // sticky request; we action it then clear

  // Abstract CS
  reg        abs_busy;
  reg [2:0]  cmderr;     // write-1-to-clear bits [10:8] via abstractcs

  // Data registers
  reg [31:0] data0;

  // SBA-lite
  reg [31:0] sbaddress0;
  reg        sba_pending;  // pending memory read transaction
  reg        sba_busy;     // running the microsequence

reg [31:0] sbdata0;       // holds last written data word
reg        sba_wr_pending;
reg        sba_is_write;

  // Simple hart state shadow (best-effort)
  reg hart_halted;         // set when we assert halt or after stepping; cleared on resume

  // --------------------------------------------
  // Micro-engine to drive VexRiscv DebugPlugin
  // --------------------------------------------
  // Control and injection addresses
  localparam [7:0] CTRL_ADDR   = 8'h00; // [7:2]==0
  localparam [7:0] INJ_ADDR    = 8'h04; // [7:2]==1

  // Control bits (write to CTRL_ADDR)
  localparam [31:0] CTRL_STEP   = 32'h0000_0010; // bit4
  localparam [31:0] CTRL_HALT   = 32'h0002_0000; // bit17 set
  localparam [31:0] CTRL_RESUME = 32'h0200_0000; // bit25 clear-halt

  // Small FSM to sequence: write, wait one cycle, optional ready, etc.
  localparam [3:0]
    ME_IDLE    = 4'd0,
    ME_INJ_WR  = 4'd1,
    ME_INJ_WR2 = 4'd2,
    ME_STEP1   = 4'd3,
    ME_STEP2   = 4'd4,
    ME_RDWB0   = 4'd5,
    ME_RDWB1   = 4'd6,
    ME_DONE    = 4'd7,
    ME_ERR     = 4'd8;

  reg [3:0]  me_state;
  reg [31:0] me_instr;        // instruction to inject
  reg        me_do_readback;  // whether to capture wb value
  reg [31:0] me_wb;           // captured write-back

  // Helpers to fire one DebugPlugin write/read transaction
  reg dp_kick, dp_is_write;
  reg [7:0]  dp_addr;
  reg [31:0] dp_wdata;
  reg dp_wait_ready;
  reg dp_done;      // single-cycle pulse when issued

  // Issue one-cycle VALID and then hold until READY if requested
  // We'll keep it simple: VALID stays high until READY is seen once.
  reg dp_active;
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      debug_bus_cmd_valid            <= 1'b0;
      debug_bus_cmd_payload_wr       <= 1'b0;
      debug_bus_cmd_payload_address  <= 8'h00;
      debug_bus_cmd_payload_data     <= 32'h0;
      dp_active                      <= 1'b0;
      dp_done                        <= 1'b0;
    end else begin
      dp_done <= 1'b0;
      if (!dp_active) begin
        if (dp_kick) begin
          debug_bus_cmd_payload_address <= dp_addr;
          debug_bus_cmd_payload_data    <= dp_wdata;
          debug_bus_cmd_payload_wr      <= dp_is_write;
          debug_bus_cmd_valid           <= 1'b1;
          dp_active                     <= 1'b1;
        end
      end else begin
        // At least one cycle with VALID=1
        if (debug_bus_cmd_ready) begin
          // One acceptance edge seen; deassert
          debug_bus_cmd_valid <= 1'b0;
          debug_bus_cmd_payload_wr <= 1'b0;
          dp_active <= 1'b0;
          dp_done <= 1'b1;
        end
      end
    end
  end

  // Micro-engine for single instruction + step + optional readback
  reg me_start;
  reg me_busy;
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      me_state       <= ME_IDLE;
      dp_kick        <= 1'b0;
      me_busy        <= 1'b0;
      me_wb          <= 32'h0;
    end else begin
      dp_kick  <= 1'b0;

      case (me_state)
        ME_IDLE: begin
          me_busy <= 1'b0;
          if (me_start) begin
            me_busy  <= 1'b1;
            me_state <= ME_INJ_WR;
          end
        end

        // Write instruction into injection port (addr 0x04)
        ME_INJ_WR: begin
          dp_is_write <= 1'b1;
          dp_addr     <= INJ_ADDR;
          dp_wdata    <= me_instr;
          dp_kick     <= 1'b1;
          me_state    <= ME_INJ_WR2;
        end

        ME_INJ_WR2: begin
          // wait for dp_done pulse
          if (dp_done) begin
            me_state <= ME_STEP1;
          end
        end

        // Step one instruction: write STEP|RESUME to control,
        // letting exactly one instruction in, then the plugin re-halts.
        ME_STEP1: begin
          dp_is_write <= 1'b1;
          dp_addr     <= CTRL_ADDR;
          dp_wdata    <= (CTRL_STEP | CTRL_RESUME);
          dp_kick     <= 1'b1;
          me_state    <= ME_STEP2;
        end

        ME_STEP2: begin
          if (dp_done) begin
            // Optionally read back last write-back (READ at 0x04)
            if (me_do_readback) begin
              dp_is_write <= 1'b0;
              dp_addr     <= INJ_ADDR; // READ page 1
              dp_wdata    <= 32'h0;
              dp_kick     <= 1'b1;
              me_state    <= ME_RDWB0;
            end else begin
              me_state <= ME_DONE;
            end
          end
        end

        ME_RDWB0: begin
          if (dp_done) begin
            // The debug bus read data is valid on the *next* cycle
            me_state <= ME_RDWB1;
          end
        end

        ME_RDWB1: begin
          me_wb   <= debug_bus_rsp_data;
          me_state <= ME_DONE;
        end

        ME_DONE: begin
          me_busy <= 1'b0;
          me_state <= ME_IDLE;
        end

        default: begin
          me_state <= ME_IDLE;
        end
      endcase
    end
  end

  // --------------------------------------------
  // Tiny assembler helpers (RV32I)
  // --------------------------------------------
  function [31:0] ins_addi; // ADDI rd, rs1, imm12
    input [4:0] rd, rs1;
    input [11:0] imm;
    reg   [31:0] r;
    begin
      r = { {20{imm[11]}}, imm } ; // sign-extend in exec, but we encode below
      // Encoding: imm[11:0] | rs1 | funct3=000 | rd | opcode=0010011
      ins_addi = { imm[11:0], rs1[4:0], 3'b000, rd[4:0], 7'b0010011 };
    end
  endfunction

  function [31:0] ins_lui; // LUI rd, imm20
    input [4:0] rd;
    input [19:0] imm20;
    begin
      ins_lui = { imm20, rd, 7'b0110111 };
    end
  endfunction

  function [31:0] ins_lw; // LW rd, imm12(rs1)
    input [4:0] rd, rs1;
    input [11:0] imm;
    begin
      ins_lw = { imm[11:0], rs1, 3'b010, rd, 7'b0000011 };
    end
  endfunction

function [31:0] ins_sw; // SW rs2, imm(rs1)  (S-type)
  input [4:0] rs2, rs1;
  input [11:0] imm;
  reg [6:0] immhi; 
  reg [4:0] immlo;
begin
  // imm[11:5] at [31:25], imm[4:0] at [11:7]
  immhi = imm[11:5];
  immlo = imm[4:0];
  ins_sw = { immhi, rs2, rs1, 3'b010, immlo, 7'b0100011 }; // funct3=010
end
endfunction

function [31:0] ins_fencei; // FENCE.I
begin
  ins_fencei = 32'b0000_0000_0000_0000_0000_0001_0000_1111; // opcode=SYSTEM, funct3=001
end
endfunction


  // Copy xN -> x31 : ADDI x31,xN,0
  function [31:0] ins_mv_to_x31;
    input [4:0] rs;
    begin
      ins_mv_to_x31 = ins_addi(5'd31, rs, 12'h000);
    end
  endfunction

  // --------------------------------------------
  // Access Register micro-sequencer (read-only)
  // command fields: aarsize[22:20]==2, transfer[18]==1, write[17]==0, regno
  // GPR xN = regno 0x1000+N
  // --------------------------------------------
  reg        ar_pending;
  reg [15:0] ar_regno;

  // --------------------------------------------
  // SBA-lite micro-sequence control (read-only)
  // Read sbdata0 triggers: x31:=addr, x31:=LW 0(x31), readback
  // --------------------------------------------
  reg sba_fire_read;

  // --------------------------------------------
  // DM register decode constants
  // --------------------------------------------
  localparam [6:0] A_DATA0      = 7'h04;
  localparam [6:0] A_DMCONTROL  = 7'h10;
  localparam [6:0] A_DMSTATUS   = 7'h11;
  localparam [6:0] A_ABSTRACTCS = 7'h16;
  localparam [6:0] A_COMMAND    = 7'h17;
  localparam [6:0] A_SBADDRESS0 = 7'h39;
  localparam [6:0] A_SBDATA0    = 7'h3C;

  // --------------------------------------------
  // DMI request handling + response pipeline
  // --------------------------------------------
  // Default response: OK, zero data
  wire [31:0] dmstatus_wire = 32'h0000_0000
                          | (hart_halted ? (1<<8)  : 0)   // anyhalted
                          | (hart_halted ? (1<<9)  : 0)   // allhalted
                          | (!hart_halted ? (1<<10) : 0)  // anyrunning
                          | (!hart_halted ? (1<<11) : 0)  // allrunning
                          | 32'h0000_0002;                // version=2

  wire [31:0] abstractcs_wire = (abs_busy ? (1<<12): 0)
                              | ({29'h0, cmderr}) << 8
                              | (32'h0000_0001)          // datacount=1
                              | (32'h0000_2000);         // progbufsize=2 (fake)

  // RESP mux
  reg [31:0] next_resp_data;
  reg [1:0]  next_resp_op;
reg [2:0]  sba_wr_stage;
  // Process request on each scan strobe
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      resp_data_q  <= 32'h0;
      resp_op_q    <= 2'b00;
      dmactive     <= 1'b0;
      haltreq      <= 1'b0;
      resumereq    <= 1'b0;
      abs_busy     <= 1'b0;
      cmderr       <= 3'b000;
      data0        <= 32'h0;
      hart_halted  <= 1'b0;
      sbaddress0   <= 32'h0;
      sba_pending  <= 1'b0;
       sbdata0      <= 32'h0;
       sba_wr_pending <= 1'b0;
       sba_is_write <= 1'b0;
       sba_wr_stage <= 3'd0;
      ar_pending   <= 1'b0;
      sba_fire_read<= 1'b0;
      me_start     <= 1'b0;
      me_instr     <= 32'h0;
      me_do_readback <= 1'b0;
      next_resp_data<= 32'h0;
      next_resp_op  <= 2'b00;
    end else begin
      // Default response to NOP
      next_resp_data <= 32'h0;
      next_resp_op   <= 2'b00;

      // Clear one-shot flags
      me_start      <= 1'b0;
      sba_fire_read <= 1'b0;

      // Complete micro-ops → update data0
      if (me_state == ME_DONE && me_busy == 1'b0) begin
        if (ar_pending) begin
          data0      <= me_wb; // result of Access Register read
          ar_pending <= 1'b0;
          abs_busy   <= 1'b0;
        end
        if (sba_busy) begin
          data0      <= me_wb; // also reflect into data0
          sba_busy   <= 1'b0;
        end
        hart_halted <= 1'b1;   // stepping re-halts core
      end

      // Action halt/resume requests (from dmcontrol)
      if (haltreq) begin
        // Drive halt
        dp_is_write <= 1'b1;
        dp_addr     <= CTRL_ADDR;
        dp_wdata    <= CTRL_HALT;
        dp_kick     <= 1'b1;
        haltreq     <= 1'b0;
        hart_halted <= 1'b1;
      end else
      if (resumereq) begin
        dp_is_write <= 1'b1;
        dp_addr     <= CTRL_ADDR;
        dp_wdata    <= CTRL_RESUME;
        dp_kick     <= 1'b1;
        resumereq   <= 1'b0;
        hart_halted <= 1'b0;
      end

      // SBA read launch (one per request)
      if (sba_fire_read && !sba_busy) begin
        // Build sequence: x31 := addr (LUI/ADDI), then LW x31,0(x31), with readback
        // Split 32-bit addr into upper20/lower12 (signed)
        // Note: lower12 is taken as signed immediate by ADDI/LW encodings
        reg [19:0] upper20;
        reg [11:0] lower12;
        reg [31:0] lw_ins;
        // Compute immediates
        upper20 = sbaddress0[31:12];
        lower12 = sbaddress0[11:0];
        // First: LUI x31, upper20
        me_instr      <= ins_lui(5'd31, upper20);
        me_do_readback<= 1'b0;
        me_start      <= 1'b1;
        sba_busy      <= 1'b1;
      end else if (sba_busy && me_state==ME_IDLE && !me_busy) begin
        // After LUI, issue ADDI x31,x31,lower12
        me_instr      <= ins_addi(5'd31, 5'd31, sbaddress0[11:0]);
        me_do_readback<= 1'b0;
        me_start      <= 1'b1;
      end else if (sba_busy && me_state==ME_IDLE && !me_busy) begin
        // (this branch will be optimized out; keeping for clarity)
        ;
      end

      // DMI request arrival → compute response for *next* scan
      if (dmi_req_stb) begin
        case (dmi_op)
          2'b00: begin // NOP
            next_resp_op   <= 2'b00;
            next_resp_data <= 32'h0;
          end

          2'b01: begin // READ
            case (dmi_addr)
              A_DMCONTROL:  begin next_resp_data <= { haltreq, resumereq, 30'h0 } | {31'h0, dmactive}; end
              A_DMSTATUS:   begin next_resp_data <= dmstatus_wire; end
              A_ABSTRACTCS: begin next_resp_data <= abstractcs_wire; end
              A_COMMAND:    begin next_resp_data <= 32'h0; end
              A_DATA0:      begin next_resp_data <= data0; end
              A_SBADDRESS0: begin next_resp_data <= sbaddress0; end
              A_SBDATA0: begin
                  if (sba_busy || me_busy) begin
                      next_resp_op <= 2'b10; // BUSY
                  end else if (sba_is_write) begin
                      // Last op was a write — return latched sbdata0 immediately
                      next_resp_data <= sbdata0;
                      next_resp_op   <= 2'b00; // OK
                  end else begin
                      // Kick a new read sequence; report BUSY this scan.
                      sba_fire_read <= 1'b1;
                      next_resp_op  <= 2'b10; // BUSY now; host should poll again
                  end

              end

              default: begin next_resp_data <= 32'h0; end
            endcase
          end

          2'b10: begin // WRITE
            case (dmi_addr)
              A_DMCONTROL: begin
                dmactive  <= dmi_wdata[0];
                // We *edge* the requests
                if (dmi_wdata[31]) haltreq  <= 1'b1;
                if (dmi_wdata[30]) resumereq<= 1'b1;
              end
              A_ABSTRACTCS: begin
                // W1C cmderr in [10:8]
                if (dmi_wdata[10]) cmderr[2] <= 1'b0;
                if (dmi_wdata[9])  cmderr[1] <= 1'b0;
                if (dmi_wdata[8])  cmderr[0] <= 1'b0;
              end
              A_DATA0: begin
                // read-only path here; ignore writes (or store for future extension)
                // data0 <= dmi_wdata;
              end
              A_COMMAND: begin
                // Only Access Register READ supported
                // Decode fields
                // [22:20] aarsize must be 2 (32-bit), [18]=1 transfer, [17]=write (must be 0)
                // regno[15:0]
                if (dmi_wdata[22:20] != 3'd2 || !dmi_wdata[18]) begin
                  cmderr  <= 3'd2; // not supported
                end else if (dmi_wdata[17]) begin
                  cmderr  <= 3'd2; // write not supported (per request)
                end else begin
                  // GPR read: regno 0x1000+N
                  ar_regno <= dmi_wdata[15:0];
                  if (dmi_wdata[15:5] == 11'h20) begin
                    // Issue "ADDI x31, xN, 0"; step; readback
                    me_instr       <= ins_mv_to_x31(dmi_wdata[4:0]);
                    me_do_readback <= 1'b1;
                    me_start       <= 1'b1;
                    abs_busy       <= 1'b1;
                    ar_pending     <= 1'b1;
                  end else begin
                    cmderr <= 3'd2; // only GPRs supported in this minimal version
                  end
                end
              end
              A_SBADDRESS0: begin
                sbaddress0 <= dmi_wdata;
                next_resp_op   <= 2'b00;
              end

              // ----- New: writing SBDATA0 initiates SBA write -----
              A_SBDATA0: begin
                sbdata0        <= dmi_wdata;
                sba_wr_pending <= 1'b1;     // arm the microsequence
                next_resp_op   <= 2'b00;
              end
              default: begin
                // ignore
              end
            endcase
          end

          default: begin
            // 2'b11: error/unsupported
            next_resp_op <= 2'b11;
          end
        endcase

        // Latch response for next scan
        resp_data_q <= next_resp_data;
        resp_op_q   <= next_resp_op;
      end

      // SBA microsequence continuation (after LUI/ADDI)
      // NOTE: We need a tiny controller to chain the three instructions.
      // We'll piggyback on me_engine by launching three times in a row:
      //   1) LUI x31, upper20
      //   2) ADDI x31, x31, lower12
      //   3) LW x31, 0(x31) with readback
      // For brevity, we do it inline using me_engine idle checks:
      if (sba_busy && me_state==ME_IDLE && !me_busy) begin
        // If last injected was LUI, next is ADDI; if last was ADDI, next is LW+readback
        // We'll detect stage by comparing me_instr (cheap heuristic).
        if (me_instr[6:0] == 7'b0110111) begin
          // Just did LUI; now ADDI
          me_instr       <= ins_addi(5'd31, 5'd31, sbaddress0[11:0]);
          me_do_readback <= 1'b0;
          me_start       <= 1'b1;
        end else if (me_instr[6:0] == 7'b0010011) begin
          // Just did ADDI; now LW with readback
          me_instr       <= ins_lw(5'd31, 5'd31, 12'h000);
          me_do_readback <= 1'b1;
          me_start       <= 1'b1;
        end
      end
      // ----- Initiate SBA write when armed -----
      if (sba_wr_pending && !sba_busy && me_state==ME_IDLE && !me_busy) begin
        // If hart is not considered halted, request a halt (best-effort)
        if (!hart_halted) begin
          haltreq <= 1'b1;
        end
        // Begin the write sequence regardless; DebugPlugin will single-step us
        sba_is_write  <= 1'b1;
        sba_busy      <= 1'b1;
        sba_wr_stage  <= 3'd0;

        // Stage 0: LUI x31, upper20(addr)
        me_instr       <= ins_lui(5'd31, sbaddress0[31:12]);
        me_do_readback <= 1'b0;
        me_start       <= 1'b1;
        sba_wr_pending <= 1'b0; // consume the request
      end

      // ----- Progress the SBA write sequence -----
      if (sba_busy && sba_is_write && me_state==ME_IDLE && !me_busy) begin
        case (sba_wr_stage)
          3'd0: begin
            // Stage 1: ADDI x31, x31, lower12(addr)
            me_instr       <= ins_addi(5'd31, 5'd31, sbaddress0[11:0]);
            me_do_readback <= 1'b0;
            me_start       <= 1'b1;
            sba_wr_stage   <= 3'd1;
          end
          3'd1: begin
            // Stage 2: LUI x30, upper20(data)
            me_instr       <= ins_lui(5'd30, sbdata0[31:12]);
            me_do_readback <= 1'b0;
            me_start       <= 1'b1;
            sba_wr_stage   <= 3'd2;
          end
          3'd2: begin
            // Stage 3: ADDI x30, x30, lower12(data)
            me_instr       <= ins_addi(5'd30, 5'd30, sbdata0[11:0]);
            me_do_readback <= 1'b0;
            me_start       <= 1'b1;
            sba_wr_stage   <= 3'd3;
          end
          3'd3: begin
            // Stage 4: SW x30, 0(x31)
            me_instr       <= ins_sw(5'd30, 5'd31, 12'h000);
            me_do_readback <= 1'b0;
            me_start       <= 1'b1;
            sba_wr_stage   <= 3'd4;
          end
          3'd4: begin
            // Stage 5: FENCE.I to make code patch visible to i-fetch
            me_instr       <= ins_fencei();
            me_do_readback <= 1'b0;
            me_start       <= 1'b1;
            sba_wr_stage   <= 3'd5;
          end
          3'd5: begin
            // Done
            sba_busy     <= 1'b0;
            sba_is_write <= 1'b0;
            // Keep hart_halted asserted in our shadow; debugger decides resume
            hart_halted  <= 1'b1;
          end
          default: begin
            // safe recovery to idle
            sba_busy     <= 1'b0;
            sba_is_write <= 1'b0;
            sba_wr_stage <= 3'd0;
          end
        endcase
      end

    end
  end

endmodule
