`timescale 1ns/1ps

module jtag_top #(
    parameter IR_LEN = 5,
    parameter DR_LEN = 41,
    parameter USER = 5'b10001,
    parameter IDCODE_OPCODE = 5'b00001
)(
    input  tck,
    input  tms,
    input  trst,
    input  tdi,
    input  clk_cpu,
    input  rst_cpu,
    output  tdo,
    input  [DR_LEN-1:0] dr_dataIn,
    output [DR_LEN-1:0] dr_dataOut,
    output dr_dataOutReady

`ifdef STATE_TEST
  , output [3:0]          dbg_state,
    output [IR_LEN-1:0]   dbg_ir_reg,
    output                dbg_state_shiftir,
    output                dbg_state_shiftdr
`endif
);

    // JTAG state machine signals
    wire state_tlr;
    wire state_capturedr;
    wire state_captureir;
    wire state_shiftdr;
    wire state_shiftir;
    wire state_updatedr;
    wire state_updateir;
    wire rst_tck_ah = ~trst;

    // --- JTAG State Machine Instance ---
    jtag_state_machine jtag_sm (
        .tck(tck),
        .tms(tms),
        .trst(trst),
        .state_tlr(state_tlr),
        .state_capturedr(state_capturedr),
        .state_captureir(state_captureir),
        .state_shiftdr(state_shiftdr),
        .state_shiftir(state_shiftir),
        .state_updatedr(state_updatedr),
        .state_updateir(state_updateir)
`ifdef STATE_TEST
      , .state(dbg_state) // relies on jtag_state_machine's `STATE_TEST` path exposing .state
`endif
    );

    reg [IR_LEN-1:0] ir_reg;     // The active IR value (holds current instruction)
    reg [IR_LEN-1:0] ir_shift;   // The shift register for IR (when shifting IR)
    wire tdo_ir;                 // TDO value when shifting IR
    wire tdo_dr;                 // TDO from DR (already from your jtag_reg)
    reg tdo_mux;                 // Output TDO (selected between IR and DR)

    // IR Register Logic
    always @(posedge tck or negedge trst) begin
        if (~trst) begin
            ir_reg   <= IDCODE_OPCODE;
            ir_shift <= IDCODE_OPCODE;
        end else if (state_tlr) begin
            ir_reg   <= IDCODE_OPCODE;
            ir_shift <= IDCODE_OPCODE;
        end else begin
            if (state_captureir) begin
                ir_shift <=  { {(IR_LEN-2){1'b0}}, 2'b01 };
            end else if (state_shiftir) begin
                ir_shift <= {tdi, ir_shift[IR_LEN-1:1]};
            end else if (state_updateir) begin
                ir_reg <= ir_shift;
            end
        end
end


    // --------- JTAG<->CPU command/response wires (through sync bridge) ----------
    // JTAG -> CPU (commands)
    wire [DR_LEN-1:0] cmd_from_jtag;      // 41-bit from jtag_reg
    wire              cmd_from_jtag_valid;
    // CPU -> JTAG (responses)
    wire [31:0]       rsp_to_jtag;
    wire              rsp_to_jtag_valid;
    // Bridge <-> CPU adapter (CPU-domain) signals
    wire [40:0] cmd_out_cpu;
    wire        cmd_valid_cpu;
    wire [31:0] rsp_in_cpu;
    wire        rsp_valid_cpu;
    // Pack 32-bit response into DR_LEN bits for jtag_reg (top bits zero)
    wire [DR_LEN-1:0] rsp_packed_for_dr = {{(DR_LEN-32){1'b0}}, rsp_to_jtag};

    // Latch response into jtag_reg input only when valid (TCK domain)
    reg  [DR_LEN-1:0] dr_dataIn_jtag;
    always @(posedge tck or negedge trst) begin
        if (~trst) begin
            dr_dataIn_jtag <= {DR_LEN{1'b0}};
        end else if (rsp_to_jtag_valid) begin
            dr_dataIn_jtag <= rsp_packed_for_dr;
        end
    end


    jtag_reg #(
        .IR_LEN(IR_LEN),
        .DR_LEN(DR_LEN),
        .USER_OPCODE(USER)
    ) jtag_register (
        .tck(tck),
        .trst(trst),
        .tdi(tdi),
        .tdo(tdo_dr),
        .state_tlr(state_tlr),
        .state_capturedr(state_capturedr),
        .state_shiftdr(state_shiftdr),
        .state_updatedr(state_updatedr),
        .ir_reg(ir_reg),
        .dr_dataIn(dr_dataIn_jtag),        // now fed from CPU response via bridge
        .dr_dataOut(cmd_from_jtag),        // command produced by JTAG side
        .dr_dataOutReady(cmd_from_jtag_valid)
    );

    // Decode 41-bit command coming into CPU domain:
    //   [40]      = wr (1=write, 0=read)
    //   [39:32]   = address
    //   [31:0]    = data (write data or ignored on read)
    wire        dbg_wr_cmd   = cmd_out_cpu[40];
    wire [7:0]  dbg_addr_cmd = cmd_out_cpu[39:32];
    wire [31:0] dbg_wdat_cmd = cmd_out_cpu[31:0];

    // Tiny adapter: hold a command until VexRiscv asserts ready,
    // then emit rsp_valid_cpu (and data for reads).
    reg         db_cmd_valid_r;
    wire        db_cmd_ready_w;
    reg  [7:0]  db_addr_r;
    reg  [31:0] db_wdata_r;
    reg         db_wr_r;
    wire [31:0] db_rsp_data_w;
    reg         busy_r;

    reg  [31:0] rsp_in_cpu_r;
    reg         rsp_valid_cpu_r;
    assign      rsp_in_cpu  = rsp_in_cpu_r;
    assign      rsp_valid_cpu = rsp_valid_cpu_r;

    always @(posedge clk_cpu or posedge rst_cpu) begin
        if (rst_cpu) begin
            db_cmd_valid_r   <= 1'b0;
            db_addr_r        <= 8'd0;
            db_wdata_r       <= 32'd0;
            db_wr_r          <= 1'b0;
            busy_r           <= 1'b0;
            rsp_in_cpu_r     <= 32'd0;
            rsp_valid_cpu_r  <= 1'b0;
        end else begin
            rsp_valid_cpu_r <= 1'b0; // default: one-cycle pulse when a txn completes

            if (!busy_r) begin
                // latch a new command from JTAG bridge (1-cycle pulse)
                if (cmd_valid_cpu) begin
                    db_wr_r        <= dbg_wr_cmd;
                    db_addr_r      <= dbg_addr_cmd;
                    db_wdata_r     <= dbg_wdat_cmd;
                    db_cmd_valid_r <= 1'b1;   // drive valid until ready
                    busy_r         <= 1'b1;
                end else begin
                    db_cmd_valid_r <= 1'b0;
                end
            end else begin
                // waiting for VexRiscv to accept the command
                if (db_cmd_ready_w) begin
                    db_cmd_valid_r <= 1'b0;
                    // For reads, capture returned data; for writes, return 0/OK
                    rsp_in_cpu_r    <= (db_wr_r) ? 32'd0 : db_rsp_data_w;
                    rsp_valid_cpu_r <= 1'b1;
                    busy_r          <= 1'b0;
                end
            end
        end
    end

    // ---------------------------- VexRiscv CPU ----------------------------
/* verilator lint_off PINMISSING */
VexRiscv u_cpu (
    // Debug bus hookup
    .debug_bus_cmd_valid           (db_cmd_valid_r),
    .debug_bus_cmd_ready           (db_cmd_ready_w),
    .debug_bus_cmd_payload_wr      (db_wr_r),
    .debug_bus_cmd_payload_address (db_addr_r),
    .debug_bus_cmd_payload_data    (db_wdata_r),
    .debug_bus_rsp_data            (db_rsp_data_w),
    .clk                           (clk_cpu),
    .reset                         (rst_cpu),

    // Unused/ignored or tied-off stuff
    .iBus_cmd_valid                (),         // output
    .iBus_cmd_ready                (1'b0),     // input
    .iBus_cmd_payload_pc           (),         // output
    .iBus_rsp_valid                (1'b0),     // input
    .iBus_rsp_payload_error        (1'b0),     // input
    .iBus_rsp_payload_inst         (32'd0),    // input

    .timerInterrupt                (1'b0),     // input
    .softwareInterrupt             (1'b0),     // input
    .externalInterruptArray        (1'b0),     // input[0:0]

    .debug_resetOut                (),         // output

    .dBus_cmd_valid                (),         // output
    .dBus_cmd_ready                (1'b0),     // input
    .dBus_cmd_payload_wr           (),         // output
    .dBus_cmd_payload_mask         (),         // output [3:0]
    .dBus_cmd_payload_address      (),         // output [31:0]
    .dBus_cmd_payload_data         (),         // output [31:0]
    .dBus_cmd_payload_size         (),         // output [1:0]
    .dBus_rsp_ready                (1'b0),     // input
    .dBus_rsp_error                (1'b0),     // input
    .dBus_rsp_data                 (32'd0)     // input
);
/* verilator lint_on PINMISSING */


    jtag_cpu_sync_bridge u_sync (
        .clk            (clk_cpu),
        .rst_clk        (rst_cpu),
        .tck            (tck),
        .rst_tck        (rst_tck_ah),
        // JTAG -> CPU (commands)
        .cmd_in_jtag    (cmd_from_jtag[40:0]),
        .cmd_valid_jtag (cmd_from_jtag_valid),
        .cmd_out_cpu    (cmd_out_cpu),
        .cmd_valid_cpu  (cmd_valid_cpu),
        .rsp_in_cpu     (rsp_in_cpu),
        .rsp_valid_cpu  (rsp_valid_cpu),
        .rsp_out_jtag   (rsp_to_jtag),
        .rsp_valid_jtag (rsp_to_jtag_valid)
    );
    assign dr_dataOut       = cmd_out_cpu;     // keep original top-level ports
    assign dr_dataOutReady  = cmd_valid_cpu;
    // Already have: ir_shift updated on posedge
// Already have: ir_shift updated on posedge
wire tdo_ir_bit = ir_shift[0];

// Register IR TDO on negedge
reg tdo_ir_q;
always @(negedge tck or negedge trst) begin
    if (~trst)              tdo_ir_q <= 1'b0;
    else if (state_shiftir) tdo_ir_q <= tdo_ir_bit;
end

// Mux the *registered* sources
wire tdo_mux_data = state_shiftir ? tdo_ir_q : tdo_dr;  // tdo_dr is jtag_reg's output

// Single tri-state at the pad, only when actually shifting
wire shift_enable = state_shiftdr | state_shiftir;
//

`ifndef STATE_TEST
    assign tdo = shift_enable ? tdo_mux_data : 1'bz;
`endif

`ifdef STATE_TEST
    assign tdo = tdo_mux_data;
    assign dbg_ir_reg        = ir_reg;
    assign dbg_state_shiftir = state_shiftir;
    assign dbg_state_shiftdr = state_shiftdr;
`endif
endmodule
