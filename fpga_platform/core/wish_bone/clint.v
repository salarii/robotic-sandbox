`timescale 1ns/1ps

module clint #(
    // Document the clocking and timebase explicitly.
    parameter integer CLK_HZ       = 50_000_000,
    parameter integer TIMEBASE_HZ  = 50_000_000
) (
    input  wire         clk,
    input  wire         rst,

    // Wishbone (expects OFFSET addresses; base decode is done in SoC top)
    input  wire         wb_cyc_i,
    input  wire         wb_stb_i,
    input  wire         wb_we_i,
    input  wire [31:0]  wb_adr_i,   // byte address, local to CLINT (offset)
    input  wire [31:0]  wb_dat_i,
    output reg  [31:0]  wb_dat_o,
    output reg          wb_ack_o,

    // Interrupt outputs to hart
    output reg          msip,       // software interrupt
    output reg          mtip        // timer interrupt
);

    // ---- Local address map (OFFSETS) ----
    localparam [31:0] MSIP_OFF         = 32'h0000_0000;
    localparam [31:0] MTIMECMP_LO_OFF  = 32'h0000_4000;
    localparam [31:0] MTIMECMP_HI_OFF  = 32'h0000_4004;
    localparam [31:0] MTIME_LO_OFF     = 32'h0000_BFF8;
    localparam [31:0] MTIME_HI_OFF     = 32'h0000_BFFC;

    // ---- Registers ----
    reg        msip_reg;
    reg [63:0] mtime;
    reg [63:0] mtimecmp;

    // ---- Prescaler for TIMEBASE_HZ ----
    localparam integer DIV = (CLK_HZ / TIMEBASE_HZ) < 1 ? 1 : (CLK_HZ / TIMEBASE_HZ);
    localparam integer DIVW = (DIV <= 1) ? 1 : $clog2(DIV);
    reg [DIVW-1:0] divcnt;

    wire do_tick = (DIV == 1) ? 1'b1 : (divcnt == DIV-1);

    // ---- Wishbone ack pulse (1 cycle) ----
    reg  served;                              // remembers we've acked current request
    wire req     = wb_cyc_i & wb_stb_i;       // a request is present
    wire ready   = 1'b1;                      // or your internal ready condition
    wire accept  = req & ready & ~served;     // 1-cycle pulse when we take this request

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wb_ack_o <= 1'b0;
            served   <= 1'b0;
        end else begin
            wb_ack_o <= accept;               // ACK exactly when we accept
            if (!req)       served <= 1'b0;   // STB/CYC dropped → allow next request
            else if (accept) served <= 1'b1;  // block re-ACK while STB remains high
        end
    end

    // ---- Writes (on ack) ----
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            msip_reg <= 1'b0;
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF; // disabled until programmed
        end else begin
            if (accept && wb_we_i) begin
                case (wb_adr_i & 32'hFFFF_FFFC)  // word-align
                    MSIP_OFF: begin
                        msip_reg <= wb_dat_i[0];
                    end
                    MTIMECMP_LO_OFF: begin
                        mtimecmp[31:0] <= wb_dat_i;
                    end
                    MTIMECMP_HI_OFF: begin
                        mtimecmp[63:32] <= wb_dat_i;
                    end
                    MTIME_LO_OFF: begin
                        mtime[31:0] <= wb_dat_i;  // optional: allow writing mtime
                    end
                    MTIME_HI_OFF: begin
                        mtime[63:32] <= wb_dat_i;
                    end
                    default: /* no-op */;
                endcase
            end

            // Prescaled mtime tick
            if (DIV == 1) begin
                mtime <= mtime + 1;
            end else begin
                if (do_tick) begin
                    mtime  <= mtime + 1;
                end
            end
        end
    end

    // ---- Prescaler counter ----
    generate
        if (DIV > 1) begin : g_div
            always @(posedge clk or posedge rst) begin
                if (rst) divcnt <= {DIVW{1'b0}};
                else if (do_tick) divcnt <= {DIVW{1'b0}};
                else if (accept && wb_we_i &&
                        (((wb_adr_i & 32'hFFFF_FFFC)==MTIME_LO_OFF) ||
                        ((wb_adr_i & 32'hFFFF_FFFC)==MTIME_HI_OFF)))
                    divcnt <= {DIVW{1'b0}}; // keep behavior sane if mtime is written
                else divcnt <= divcnt + 1'b1;
            end
        end else begin : g_no_div
            always @* divcnt = {DIVW{1'b0}}; // unused
        end
    endgenerate


    // ---- Read mux (combinational) ----
    always @* begin
        case (wb_adr_i & 32'hFFFF_FFFC)
            MSIP_OFF:         wb_dat_o = {31'd0, msip_reg};
            MTIMECMP_LO_OFF:  wb_dat_o = mtimecmp[31:0];
            MTIMECMP_HI_OFF:  wb_dat_o = mtimecmp[63:32];
            MTIME_LO_OFF:     wb_dat_o = mtime[31:0];
            MTIME_HI_OFF:     wb_dat_o = mtime[63:32];
            default:          wb_dat_o = 32'd0;
        endcase
    end

    // ---- Interrupt outputs ----
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            msip <= 1'b0;
            mtip <= 1'b0;
        end else begin
            msip <= msip_reg;
            mtip <= (mtime >= mtimecmp);
        end
    end

endmodule
