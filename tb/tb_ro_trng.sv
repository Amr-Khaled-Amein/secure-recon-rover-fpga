// ============================================================================
// tb_ro_trng : self-checking testbench for ro_trng (behavioral RO model)
//              followed by trng_health.
//
// The model's per-half-period jitter is set to 3% so that the 4 ROs give
// usable randomness at DECIM = 64 in a short simulation. (Real jitter is far
// smaller; DECIM is set from hardware measurements in Phase 4.)
//   - exactly one raw bit per DECIM cycles while enabled, none while disabled
//   - 8,192 bits pass the SP 800-90B health tests
//   - ones between 45% and 55%, lag-1 serial correlation |r| < 0.1
// Prints TEST PASSED at the end; any failure stops with $fatal.
// ============================================================================
`timescale 1ns/1ps
module tb_ro_trng;
    import puf_sim_pkg::*;

    localparam int DECIM = 64, NBITS = 8192;

    logic clk = 1'b0, rst = 1'b1, enable = 1'b0;
    wire  raw_valid, raw_bit;
    wire  h_valid, h_bit, h_startup, h_fail, h_rct, h_apt;
    always #5 clk = ~clk;

    ro_trng #(.N_RO(4), .DECIM(DECIM), .SIM_RO(1)) dut (
        .clk(clk), .rst(rst), .enable(enable), .raw_valid(raw_valid), .raw_bit(raw_bit)
    );
    trng_health u_health (
        .clk(clk), .rst(rst), .in_valid(raw_valid), .in_bit(raw_bit),
        .out_valid(h_valid), .out_bit(h_bit), .startup_done(h_startup),
        .fail(h_fail), .rct_fail(h_rct), .apt_fail(h_apt)
    );

    initial begin : watchdog
        #50ms $fatal(1, "TIMEOUT");
    end

    bit bits [$];
    longint last_t = -1;
    int bad_spacing = 0;
    always @(posedge clk) if (raw_valid) begin
        if (last_t >= 0 && ($time - last_t) != DECIM * 10) bad_spacing++;
        last_t = $time;
        bits.push_back(raw_bit);
    end

    initial begin
        int ones = 0;
        real m, num = 0.0, den = 0.0, r;
        jit_ppm = 30000;
        chip = 1; run = 1;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        repeat (500) @(negedge clk);
        if (bits.size() != 0) $fatal(1, "bits produced while disabled");

        enable = 1'b1;
        wait (bits.size() == NBITS);
        @(negedge clk);
        enable = 1'b0;
        if (bad_spacing != 0) $fatal(1, "%0d raw bits not spaced by DECIM", bad_spacing);
        repeat (DECIM * 3) @(negedge clk);
        if (bits.size() != NBITS) $fatal(1, "bits produced after disable");
        $display("PASS  one raw bit every %0d cycles while enabled, none while disabled", DECIM);

        if (h_fail) $fatal(1, "health test failed on the model output (rct %0d apt %0d)", h_rct, h_apt);
        $display("PASS  %0d bits pass the SP 800-90B RCT/APT health tests", NBITS);

        foreach (bits[i]) ones += bits[i];
        m = real'(ones) / NBITS;
        for (int i = 0; i < NBITS - 1; i++) num += (bits[i] - m) * (bits[i+1] - m);
        foreach (bits[i]) den += (bits[i] - m) * (bits[i] - m);
        r = num / den;
        if (ones * 100 < NBITS * 45 || ones * 100 > NBITS * 55) $fatal(1, "ones = %0d of %0d", ones, NBITS);
        if (r > 0.1 || r < -0.1) $fatal(1, "serial correlation %f", r);
        $display("PASS  %.1f%% ones, lag-1 correlation %.3f", 100.0 * m, r);
        $display("TEST PASSED");
        $finish;
    end
endmodule
