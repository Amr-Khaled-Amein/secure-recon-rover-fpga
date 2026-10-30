// ============================================================================
// tb_trng_health : self-checking testbench for trng_health (SP 800-90B RCT/APT)
//
//   1. good random input: no failure in 200,000 samples; output starts after
//      exactly one APT window; output bit = input bit
//   2. stuck-at-0 and stuck-at-1: RCT trips on exactly the 41st identical
//      sample; nothing is output from that sample on; fail stays set
//   3. long runs of 40 (just under the cutoff): RCT does not trip
//   4. 90% ones: APT trips; 68% ones (just below 2^-0.5 = 70.7%, the bias the
//      cutoff was set for): no alarm in 50 windows
//   5. failure during start-up: never any output
//   6. reset clears the failure
// Prints TEST PASSED at the end; any mismatch stops with $fatal.
// ============================================================================
`timescale 1ns/1ps
module tb_trng_health;

    logic clk = 1'b0, rst = 1'b1, in_valid = 1'b0, in_bit = 1'b0;
    wire  out_valid, out_bit, startup_done, fail, rct_fail, apt_fail;
    always #5 clk = ~clk;

    trng_health #(.RCT_C(41), .APT_W(1024), .APT_C(793)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_bit(in_bit),
        .out_valid(out_valid), .out_bit(out_bit), .startup_done(startup_done),
        .fail(fail), .rct_fail(rct_fail), .apt_fail(apt_fail)
    );

    initial begin : watchdog
        #50ms $fatal(1, "TIMEOUT");
    end

    int n_in = 0, n_out = 0;
    bit last_in;

    // feed one sample; check the output of the previous sample
    task automatic sample(input bit b);
        @(negedge clk);
        in_valid = 1'b1; in_bit = b;
        @(negedge clk);
        in_valid = 1'b0;
        n_in++;
        if (out_valid) begin
            n_out++;
            if (out_bit !== b) $fatal(1, "out_bit != in_bit");
        end
    endtask

    task automatic do_reset();
        @(negedge clk); rst = 1'b1; @(negedge clk); rst = 1'b0;
        n_in = 0; n_out = 0;
        if (fail || startup_done) $fatal(1, "reset did not clear the flags");
    endtask

    initial begin
        int first_out;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // ---- 1. good input ----
        first_out = -1;
        for (int i = 0; i < 200000; i++) begin
            sample($urandom_range(1));
            if (out_valid && first_out < 0) first_out = i;
        end
        if (fail) $fatal(1, "false alarm on good input (rct %0d apt %0d)", rct_fail, apt_fail);
        if (first_out != 1024) $fatal(1, "first output at sample %0d, expected 1024", first_out);
        $display("PASS  good input: 200000 samples, no alarm; output starts after the 1024-sample start-up window");

        // ---- 2. stuck at 0 / 1 ----
        for (int v = 0; v < 2; v++) begin
            automatic int trip = -1;
            for (int i = 0; i < 60; i++) begin
                sample(v);
                if (rct_fail && trip < 0) trip = i + 1;
                if (rct_fail && out_valid) $fatal(1, "output after RCT failure");
            end
            // the run may include the last random sample(s) n_before it
            if (trip < 1 || trip > 41) $fatal(1, "stuck-at-%0d: RCT tripped after %0d samples", v, trip);
            begin
                automatic int n_before = n_out;
                for (int i = 0; i < 2000; i++) sample($urandom_range(1));
                if (!fail || n_out != n_before) $fatal(1, "failure not sticky / output resumed");
            end
            $display("PASS  stuck-at-%0d: RCT tripped after %0d identical samples, output blocked, flag sticky", v, trip);
            do_reset();
            for (int i = 0; i < 1100; i++) sample($urandom_range(1));
        end

        // exact cutoff: after a 0, exactly 41 ones
        do_reset();
        for (int i = 0; i < 1100; i++) sample($urandom_range(1));
        sample(0);
        for (int i = 1; i <= 41; i++) begin
            sample(1);
            if (rct_fail != (i == 41)) $fatal(1, "RCT state wrong after %0d ones (fail=%0d)", i, rct_fail);
        end
        $display("PASS  RCT trips on exactly the 41st identical sample");

        // ---- 3. runs of 40 never trip ----
        do_reset();
        for (int k = 0; k < 40; k++) begin
            for (int i = 0; i < 40; i++) sample(k % 2);
        end
        if (rct_fail) $fatal(1, "RCT tripped on runs of 40");
        $display("PASS  runs of 40 identical samples: no RCT alarm");

        // ---- 4. bias ----
        do_reset();
        for (int i = 0; i < 1024 * 50; i++) sample($urandom_range(99) < 68);
        if (fail) $fatal(1, "APT false alarm at 68%% ones");
        $display("PASS  68%% ones for 50 windows: no APT alarm");
        do_reset();
        begin
            automatic int trip = -1;
            for (int i = 0; i < 4096; i++) begin
                sample($urandom_range(99) < 90);
                if (apt_fail && trip < 0) trip = i;
            end
            if (!apt_fail) $fatal(1, "APT did not trip at 90%% ones");
            $display("PASS  90%% ones: APT tripped at sample %0d", trip);
        end

        // ---- 5. failure during start-up: never any output ----
        do_reset();
        for (int i = 0; i < 50; i++) sample(1'b1);
        for (int i = 0; i < 3000; i++) sample($urandom_range(1));
        if (n_out != 0 || startup_done) $fatal(1, "output after a start-up failure");
        $display("PASS  failure during start-up: no output at all");

        // ---- 6. reset clears ----
        do_reset();
        for (int i = 0; i < 1100; i++) sample($urandom_range(1));
        if (fail || !startup_done || n_out == 0) $fatal(1, "not working after reset");
        $display("PASS  reset clears the failure");

        $display("TEST PASSED");
        $finish;
    end
endmodule
