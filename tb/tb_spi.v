`timescale 1ns/1ps
// =============================================================================
// tb_spi.v - Self-checking testbench for spi_master <-> spi_slave
//
// Override on the command line (see Makefile):
//   iverilog -P tb_spi.MODE=2 -P tb_spi.CLK_DIV=8 -P tb_spi.DATA_WIDTH=16 ...
//
// The slave runs on a different clock (7 ns) than the master (10 ns), so the
// synchronizers and edge detection are exercised against an unrelated clock.
//
// Checks per transfer: master rx, slave rx, exactly one slave rx_valid pulse,
// CS_N released, busy low, SCLK edge count == 2*DATA_WIDTH.
// Global checks: SCLK idles at CPOL while CS_N is high, done pulse count,
// start-while-busy ignored, reset mid-transfer recovery, watchdog timeout.
// =============================================================================
module tb_spi #(
    parameter DATA_WIDTH = 8,
    parameter CLK_DIV    = 4,
    parameter MODE       = 0,     // {CPOL, CPHA}
    parameter NUM_RANDOM = 50
);

    localparam CPOL     = (MODE >> 1) & 1;
    localparam CPHA     = MODE & 1;
    localparam DW       = DATA_WIDTH;
    localparam CS_SETUP = 4;
    localparam CS_GAP   = 4;
    localparam TIMEOUT_CYCLES = 2 * (CS_SETUP + (2 * DW + 4) * CLK_DIV + CS_GAP + 10);

    // ------------------------------------------------------------ clocks/signals
    reg clk = 1'b0;
    reg slave_clk = 1'b0;
    always #5   clk       = ~clk;       // 100 MHz
    always #3.5 slave_clk = ~slave_clk; // ~142.9 MHz, unrelated phase

    reg                 rst_n = 1'b0;
    reg                 start = 1'b0;
    reg  [DW-1:0]       master_tx_data = 0;
    wire [DW-1:0]       master_rx_data;
    wire                busy, done;

    wire                sclk, mosi, miso, cs_n;

    reg  [DW-1:0]       slave_tx_data = 0;
    wire [DW-1:0]       slave_rx_data;
    wire                slave_rx_valid;

    spi_master #(
        .DATA_WIDTH(DW), .CLK_DIV(CLK_DIV), .CPOL(CPOL), .CPHA(CPHA),
        .CS_SETUP(CS_SETUP), .CS_GAP(CS_GAP)
    ) u_master (
        .clk(clk), .rst_n(rst_n), .start(start), .tx_data(master_tx_data),
        .rx_data(master_rx_data), .busy(busy), .done(done),
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n)
    );

    spi_slave #(.DATA_WIDTH(DW), .CPOL(CPOL), .CPHA(CPHA)) u_slave (
        .clk(slave_clk), .rst_n(rst_n),
        .sclk(sclk), .cs_n(cs_n), .mosi(mosi), .miso(miso),
        .tx_data(slave_tx_data), .rx_data(slave_rx_data), .rx_valid(slave_rx_valid)
    );

    // ------------------------------------------------------------ bookkeeping
    integer errors        = 0;
    integer transfers     = 0;
    integer done_count    = 0;
    integer expected_done = 0;
    integer sclk_edges    = 0;
    integer slave_rx_count = 0;
    reg [DW-1:0] slave_rx_last = 0;

    // capture every slave rx_valid pulse (slave clock domain)
    always @(posedge slave_clk) begin
        if (slave_rx_valid) begin
            slave_rx_count <= slave_rx_count + 1;
            slave_rx_last  <= slave_rx_data;
        end
    end

    always @(posedge clk) if (done) done_count <= done_count + 1;

    // count SCLK edges while selected
    always @(sclk) if (cs_n === 1'b0) sclk_edges = sclk_edges + 1;

    // protocol monitor: SCLK must idle at CPOL whenever CS_N is high
    always @(negedge clk) begin
        if (rst_n && cs_n === 1'b1 && sclk !== CPOL[0]) begin
            $display("  ERROR [%0t]: SCLK not at idle level while CS_N high", $time);
            errors = errors + 1;
        end
    end

    task check(input cond, input [8*48-1:0] msg);
        begin
            if (!cond) begin
                $display("  ERROR [%0t]: %0s", $time, msg);
                errors = errors + 1;
            end
        end
    endtask

    // ------------------------------------------------------------ one transfer
    // Must be called at a negedge of clk.  Returns at the negedge where 'done'
    // is seen, so calling it again immediately gives a back-to-back transfer.
    task do_transfer(input [DW-1:0] m2s, input [DW-1:0] s2m);
        integer cyc;
        integer cnt_before;
        begin
            master_tx_data = m2s;
            slave_tx_data  = s2m;
            cnt_before     = slave_rx_count;
            sclk_edges     = 0;
            expected_done  = expected_done + 1;
            transfers      = transfers + 1;

            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            cyc = 0;
            while (!done && cyc < TIMEOUT_CYCLES) begin
                @(negedge clk);
                cyc = cyc + 1;
            end

            if (!done) begin
                $display("  ERROR [%0t]: TIMEOUT waiting for done (m2s=0x%0h)", $time, m2s);
                errors = errors + 1;
            end else begin
                $display("[%0t ns] M->S 0x%0h  S->M 0x%0h  |  master_rx=0x%0h  slave_rx=0x%0h",
                         $time, m2s, s2m, master_rx_data, slave_rx_last);
                check(master_rx_data === s2m,           "master_rx_data mismatch");
                check(slave_rx_last   === m2s,          "slave_rx_data mismatch");
                check(slave_rx_count  === cnt_before+1, "slave rx_valid pulse count != 1");
                check(cs_n === 1'b1,                    "CS_N not released at done");
                check(busy === 1'b0,                    "busy still high at done");
                check(sclk_edges === 2*DW,              "wrong number of SCLK edges");
            end
        end
    endtask

    task idle_cycles(input integer n);
        begin repeat (n) @(negedge clk); end
    endtask

    // 'start' pulsed again mid-transfer must be ignored
    task start_while_busy;
        reg [DW-1:0] m2s, s2m;
        integer cyc, cnt_before;
        begin
            m2s = $urandom; s2m = $urandom;
            master_tx_data = m2s; slave_tx_data = s2m;
            cnt_before = slave_rx_count;
            sclk_edges = 0;
            expected_done = expected_done + 1;
            transfers = transfers + 1;

            start = 1'b1; @(negedge clk); start = 1'b0;
            idle_cycles(CS_SETUP + 3 * CLK_DIV);
            master_tx_data = ~m2s;            // must not affect the running transfer
            start = 1'b1; @(negedge clk); start = 1'b0;

            cyc = 0;
            while (!done && cyc < TIMEOUT_CYCLES) begin @(negedge clk); cyc = cyc + 1; end
            $display("[%0t ns] start-while-busy: master_rx=0x%0h (exp 0x%0h) slave_rx=0x%0h (exp 0x%0h)",
                     $time, master_rx_data, s2m, slave_rx_last, m2s);
            check(done,                              "start-while-busy: TIMEOUT");
            check(master_rx_data === s2m,            "start-while-busy: master_rx mismatch");
            check(slave_rx_last  === m2s,            "start-while-busy: slave_rx mismatch");
            check(slave_rx_count === cnt_before + 1, "start-while-busy: extra transfer started");
            idle_cycles(TIMEOUT_CYCLES / 2);
            check(done_count === expected_done,      "start-while-busy: extra done pulse");
        end
    endtask

    // reset in the middle of a word, then make sure everything recovers
    task reset_mid_transfer;
        begin
            master_tx_data = {DW{1'b1}}; slave_tx_data = {DW{1'b0}};
            start = 1'b1; @(negedge clk); start = 1'b0;
            idle_cycles(CS_SETUP + 5 * CLK_DIV);
            rst_n = 1'b0;
            idle_cycles(2);
            check(cs_n === 1'b1 && busy === 1'b0 && sclk === CPOL[0],
                  "outputs not idle during reset");
            rst_n = 1'b1;
            idle_cycles(20);
            $display("[%0t ns] reset mid-transfer: done, checking recovery", $time);
        end
    endtask

    // ------------------------------------------------------------ main sequence
    integer i;
    reg [8*128-1:0] vcdfile;

    initial begin
        $timeformat(-9, 0, "", 0);   // print %t in ns
        if (!$value$plusargs("VCD=%s", vcdfile)) vcdfile = "sim/spi_tb.vcd";
        $dumpfile(vcdfile);
        $dumpvars(0, tb_spi);
        $display("=== tb_spi: MODE=%0d (CPOL=%0d CPHA=%0d)  DATA_WIDTH=%0d  CLK_DIV=%0d ===",
                 MODE, CPOL, CPHA, DW, CLK_DIV);

        // reset
        rst_n = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);

        // directed patterns (all back-to-back)
        do_transfer({DW{1'b0}},  {DW{1'b1}});
        do_transfer({DW{1'b1}},  {DW{1'b0}});
        do_transfer({DW{2'b10}}, {DW{2'b01}});
        do_transfer({DW{2'b01}}, {DW{2'b10}});
        do_transfer({DW{1'b1}},  {DW{1'b1}});
        do_transfer({DW{1'b0}},  {DW{1'b0}});

        // walking ones / zeros
        for (i = 0; i < DW; i = i + 1)
            do_transfer(1 << i, ~(1 << i));

        // behaviour checks
        idle_cycles(10);
        start_while_busy;
        idle_cycles(10);
        reset_mid_transfer;
        do_transfer({DW{2'b10}}, {DW{2'b01}});   // must work right after reset

        // random traffic with random idle gaps (0 gap = back-to-back)
        for (i = 0; i < NUM_RANDOM; i = i + 1) begin
            do_transfer($urandom, $urandom);
            if ($urandom % 3 == 0) idle_cycles($urandom % 40);
        end

        idle_cycles(TIMEOUT_CYCLES / 2);
        check(done_count === expected_done, "done pulse count mismatch");

        $display("-------------------------------------------------------------");
        $display("MODE=%0d DATA_WIDTH=%0d CLK_DIV=%0d : %0d transfers, %0d error(s)",
                 MODE, DW, CLK_DIV, transfers, errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $finish;
    end

    // watchdog: never hang the simulator
    initial begin
        #50_000_000;
        $display("RESULT: FAIL (watchdog timeout)");
        $finish;
    end

endmodule