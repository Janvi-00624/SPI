`timescale 1ns/1ps
// =============================================================================
// spi_master.v - Parameterized SPI master (all 4 modes, any data width >= 2)
//
//   CPOL = idle level of SCLK
//   CPHA = 0 : sample on leading edge,  shift on trailing edge
//   CPHA = 1 : shift  on leading edge,  sample on trailing edge
//   MSB first, one word per CS_N assertion.
//
//   SCLK frequency = f_clk / (2 * CLK_DIV)
//
//   Timeline of one transfer (all counts in system-clock cycles):
//
//     start -> CS_N low -> [CS_SETUP] -> [CLK_DIV] -> first SCLK edge
//     ... 2*DATA_WIDTH edges, CLK_DIV cycles apart ...
//     last edge -> [CLK_DIV] -> CS_N high -> [CS_GAP] -> done pulse, busy low
//
//   'start' is ignored while 'busy' is high.  'tx_data' is latched on start.
//   'rx_data' is valid when 'done' pulses (and holds until the next transfer).
// =============================================================================
module spi_master #(
    parameter DATA_WIDTH = 8,   // bits per word (>= 2)
    parameter CLK_DIV    = 4,   // sys-clk cycles per SCLK half period (>= 1)
    parameter CPOL       = 0,   // 0 or 1
    parameter CPHA       = 0,   // 0 or 1
    parameter CS_SETUP   = 4,   // cycles from CS_N fall to start of 1st half period (>= 1)
    parameter CS_GAP     = 4    // min cycles CS_N stays high between words (>= 1)
)(
    input  wire                  clk,
    input  wire                  rst_n,    // active-low, asynchronous assert
    input  wire                  start,    // 1-cycle pulse: begin a transfer
    input  wire [DATA_WIDTH-1:0] tx_data,
    output reg  [DATA_WIDTH-1:0] rx_data,
    output reg                   busy,
    output reg                   done,     // 1-cycle pulse when transfer completes

    output reg                   sclk,
    output reg                   mosi,
    input  wire                  miso,
    output reg                   cs_n
);

    // ---------------------------------------------------------------- constants
    localparam CPOL_B = (CPOL != 0);
    localparam CPHA_B = (CPHA != 0);

    localparam CNT_W  = (CLK_DIV > 1) ? $clog2(CLK_DIV) : 1;
    localparam AUX_W  = ((CS_SETUP > CS_GAP) ? $clog2(CS_SETUP + 1)
                                             : $clog2(CS_GAP   + 1)) + 1;
    localparam EDGE_W = $clog2(2 * DATA_WIDTH) + 1;

    // (constants are small by construction; widths are sized to hold them)
    /* verilator lint_off WIDTHTRUNC */
    localparam [CNT_W-1:0]  DIV_MAX   = CLK_DIV - 1;
    localparam [AUX_W-1:0]  SETUP_MAX = CS_SETUP - 1;
    localparam [AUX_W-1:0]  GAP_MAX   = CS_GAP - 1;
    localparam [EDGE_W-1:0] LAST_EDGE = 2 * DATA_WIDTH - 1;
    /* verilator lint_on WIDTHTRUNC */

    localparam [2:0] S_IDLE  = 3'd0,
                     S_LEAD  = 3'd1,   // CS asserted, waiting CS_SETUP
                     S_XFER  = 3'd2,   // toggling SCLK
                     S_TRAIL = 3'd3,   // last half period before CS release
                     S_GAP   = 3'd4;   // CS high, enforcing CS_GAP

    // ---------------------------------------------------------------- registers
    reg [2:0]            state;
    reg [CNT_W-1:0]      div_cnt;
    reg [AUX_W-1:0]      aux_cnt;      // CS_SETUP / CS_GAP counter
    reg [EDGE_W-1:0]     edge_cnt;
    reg [DATA_WIDTH-1:0] tx_sh;        // MSB = next bit to drive
    reg [DATA_WIDTH-1:0] rx_sh;

    wire tick         = (div_cnt == DIV_MAX);
    wire is_leading   = (sclk == CPOL_B);          // edge about to happen
    wire sample_edge  = CPHA_B ? ~is_leading : is_leading;
    wire last_edge    = (edge_cnt == LAST_EDGE);

    // ---------------------------------------------------------------- FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            sclk     <= CPOL_B;
            mosi     <= 1'b0;
            cs_n     <= 1'b1;
            busy     <= 1'b0;
            done     <= 1'b0;
            div_cnt  <= {CNT_W{1'b0}};
            aux_cnt  <= {AUX_W{1'b0}};
            edge_cnt <= {EDGE_W{1'b0}};
            tx_sh    <= {DATA_WIDTH{1'b0}};
            rx_sh    <= {DATA_WIDTH{1'b0}};
            rx_data  <= {DATA_WIDTH{1'b0}};
        end else begin
            done <= 1'b0;

            case (state)
                // ------------------------------------------------------- IDLE
                S_IDLE: begin
                    sclk <= CPOL_B;
                    if (start) begin
                        cs_n     <= 1'b0;
                        busy     <= 1'b1;
                        div_cnt  <= {CNT_W{1'b0}};
                        aux_cnt  <= {AUX_W{1'b0}};
                        edge_cnt <= {EDGE_W{1'b0}};
                        if (CPHA_B) begin
                            // first bit is driven on the first (leading) edge
                            tx_sh <= tx_data;
                        end else begin
                            // first bit must be valid before the first (sampling) edge
                            mosi  <= tx_data[DATA_WIDTH-1];
                            tx_sh <= {tx_data[DATA_WIDTH-2:0], 1'b0};
                        end
                        state <= S_LEAD;
                    end
                end

                // ------------------------------------------------------- LEAD
                S_LEAD: begin
                    if (aux_cnt == SETUP_MAX) state <= S_XFER;
                    else                      aux_cnt <= aux_cnt + 1'b1;
                end

                // ------------------------------------------------------- XFER
                S_XFER: begin
                    if (tick) begin
                        div_cnt <= {CNT_W{1'b0}};
                        sclk    <= ~sclk;

                        if (sample_edge) begin
                            rx_sh <= {rx_sh[DATA_WIDTH-2:0], miso};
                        end else if (!last_edge) begin
                            mosi  <= tx_sh[DATA_WIDTH-1];
                            tx_sh <= {tx_sh[DATA_WIDTH-2:0], 1'b0};
                        end

                        if (last_edge) state    <= S_TRAIL;
                        else           edge_cnt <= edge_cnt + 1'b1;
                    end else begin
                        div_cnt <= div_cnt + 1'b1;
                    end
                end

                // ------------------------------------------------------- TRAIL
                S_TRAIL: begin
                    if (tick) begin
                        div_cnt <= {CNT_W{1'b0}};
                        cs_n    <= 1'b1;
                        rx_data <= rx_sh;
                        aux_cnt <= {AUX_W{1'b0}};
                        state   <= S_GAP;
                    end else begin
                        div_cnt <= div_cnt + 1'b1;
                    end
                end

                // ------------------------------------------------------- GAP
                S_GAP: begin
                    if (aux_cnt == GAP_MAX) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        aux_cnt <= aux_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
