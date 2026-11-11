`timescale 1ns/1ps
// =============================================================================
// spi_slave.v - Parameterized, fully synchronous SPI slave (all 4 modes)
//
// The slave runs on its own system clock 'clk'.  SCLK, CS_N and MOSI are
// treated as asynchronous inputs: they go through 2-FF synchronizers and the
// SPI edges are detected by comparing consecutive synchronized samples.
// There is exactly one clock domain, so the design synthesizes cleanly and
// closes timing without treating SCLK as a clock.
//
// REQUIREMENTS
//   * f_clk >= ~8 x f_sclk recommended (hard minimum is ~4x).  The slave needs
//     about 3 clk cycles to react to an SCLK edge, which must be well inside
//     half an SCLK period.
//   * CS_N must stay high for at least ~3 clk cycles between words.
//   * 'tx_data' must be stable when CS_N falls (it is latched then).
//   * One word per CS_N assertion; extra clocks after DATA_WIDTH bits are
//     ignored until CS_N is released.
//
// MISO is tri-stated while CS_N is high so several slaves can share a bus.
// =============================================================================
module spi_slave #(
    parameter DATA_WIDTH = 8,
    parameter CPOL       = 0,
    parameter CPHA       = 0
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // SPI bus
    input  wire                  sclk,
    input  wire                  cs_n,
    input  wire                  mosi,
    output wire                  miso,

    // user side (clk domain)
    input  wire [DATA_WIDTH-1:0] tx_data,    // word to send, latched when CS_N falls
    output reg  [DATA_WIDTH-1:0] rx_data,    // last word received
    output reg                   rx_valid    // 1-cycle pulse when rx_data is fresh
);

    localparam CPOL_B = (CPOL != 0);
    localparam CPHA_B = (CPHA != 0);
    localparam CNT_W  = $clog2(DATA_WIDTH + 1);
    /* verilator lint_off WIDTHTRUNC */
    localparam [CNT_W-1:0] N = DATA_WIDTH;
    /* verilator lint_on WIDTHTRUNC */

    // ------------------------------------------------------ input synchronizers
    reg [1:0] sclk_sync, cs_sync, mosi_sync;
    reg       sclk_d, cs_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_sync <= {2{CPOL_B}};
            cs_sync   <= 2'b11;
            mosi_sync <= 2'b00;
            sclk_d    <= CPOL_B;
            cs_d      <= 1'b1;
        end else begin
            sclk_sync <= {sclk_sync[0], sclk};
            cs_sync   <= {cs_sync[0],   cs_n};
            mosi_sync <= {mosi_sync[0], mosi};
            sclk_d    <= sclk_sync[1];
            cs_d      <= cs_sync[1];
        end
    end

    wire sclk_q    = sclk_sync[1];
    wire cs_q      = cs_sync[1];
    wire mosi_q    = mosi_sync[1];

    wire cs_fall   = cs_d & ~cs_q;
    wire sclk_rise = ~sclk_d &  sclk_q;
    wire sclk_fall =  sclk_d & ~sclk_q;

    wire lead_edge    = CPOL_B ? sclk_fall : sclk_rise;
    wire trail_edge   = CPOL_B ? sclk_rise : sclk_fall;
    wire sample_edge  = CPHA_B ? trail_edge : lead_edge;
    wire shift_edge   = CPHA_B ? lead_edge  : trail_edge;

    // ------------------------------------------------------------ shift engine
    /* verilator lint_off UNUSEDSIGNAL */
    reg [DATA_WIDTH-1:0] rx_sh;   // MSB is only a shift stage (rx_data is built from [N-2:0] + new bit)
    /* verilator lint_on UNUSEDSIGNAL */
    reg [DATA_WIDTH-1:0] tx_sh;
    reg [CNT_W-1:0]      cnt;          // bits sampled so far
    reg                  miso_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_data  <= {DATA_WIDTH{1'b0}};
            rx_valid <= 1'b0;
            rx_sh    <= {DATA_WIDTH{1'b0}};
            tx_sh    <= {DATA_WIDTH{1'b0}};
            cnt      <= {CNT_W{1'b0}};
            miso_r   <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            if (cs_q) begin
                // deselected: stay ready (also recovers from an aborted word)
                cnt <= {CNT_W{1'b0}};
            end else if (cs_fall) begin
                cnt <= {CNT_W{1'b0}};
                if (CPHA_B) begin
                    tx_sh <= tx_data;                                // 1st bit goes out on 1st edge
                end else begin
                    miso_r <= tx_data[DATA_WIDTH-1];                 // 1st bit must be ready now
                    tx_sh  <= {tx_data[DATA_WIDTH-2:0], 1'b0};
                end
            end else if (cnt != N) begin
                if (sample_edge) begin
                    rx_sh <= {rx_sh[DATA_WIDTH-2:0], mosi_q};
                    cnt   <= cnt + 1'b1;
                    if (cnt == N - 1'b1) begin
                        rx_data  <= {rx_sh[DATA_WIDTH-2:0], mosi_q};
                        rx_valid <= 1'b1;
                    end
                end else if (shift_edge) begin
                    miso_r <= tx_sh[DATA_WIDTH-1];
                    tx_sh  <= {tx_sh[DATA_WIDTH-2:0], 1'b0};
                end
            end
        end
    end

    assign miso = cs_n ? 1'bz : miso_r;

endmodule
