// ============================================================================
// tb_puf_keygen : end-to-end PUF key generation with the behavioral RO model
//                 (Phase 0 acceptance: "sim model with injected bias and bit
//                 errors gives a stable key").
//
//   1. chip 1, enrollment (ENROLL=1 instance) -> helper data + K1
//   2. chip 1, 6 power-ups with fresh noise (ENROLL=0 instance + helper)
//      -> K = K1 every time; raw-bit error rate and corrections reported
//   3. chip 2 with chip 1's helper data -> K != K1, raw HD ~50%
//   4. chip 3 with strong injected bias (~28% ones): enroll + 4 power-ups
//      -> stable key; debiased bits ~unbiased
//   5. NB too large for the available bits -> err = 1
// Small sizes for simulation speed (N_RO = 640, R = 5, NB = 10); the real
// sizing is in docs/puf_entropy.md.
// Prints TEST PASSED at the end; any failure stops with $fatal.
// ============================================================================
`timescale 1ns/1ps
module tb_puf_keygen;
    import puf_sim_pkg::*;

    localparam int N_RO = 640, WINDOW = 128, VOTES = 5, R = 5, NB = 10;
    localparam int NPAIR = N_RO / 2;

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;
    initial begin : watchdog
        #2s $fatal(1, "TIMEOUT");
    end

    // ---------------- enrollment instance ----------------
    logic e_start = 0;
    wire  e_mv, e_mb, e_ov, e_ob, e_kv, e_err, e_x1, e_x2;
    wire [127:0] e_key;
    wire [15:0]  e_nerr;
    puf_keygen #(.ENROLL(1), .N_RO(N_RO), .WINDOW(WINDOW), .VOTES(VOTES), .SETTLE(4),
                 .R(R), .NB(NB), .SIM_RO(1)) u_enr (
        .clk(clk), .rst(rst), .start(e_start),
        .mask_in_valid(1'b0), .mask_in_ready(e_x1), .mask_in_bit(1'b0),
        .mask_out_valid(e_mv), .mask_out_ready(1'b1), .mask_out_bit(e_mb),
        .off_in_valid(1'b0), .off_in_ready(e_x2), .off_in_bit(1'b0),
        .off_out_valid(e_ov), .off_out_ready(1'b1), .off_out_bit(e_ob),
        .key(e_key), .key_valid(e_kv), .err(e_err), .nerr(e_nerr)
    );

    // ---------------- deployed (reconstruction) instance ----------------
    logic c_start = 0, c_mv = 0, c_mb = 0, c_ov = 0, c_ob = 0;
    wire  c_mr, c_or, c_kv, c_err, c_x1, c_x2, c_x3, c_x4;
    wire [127:0] c_key;
    wire [15:0]  c_nerr;
    puf_keygen #(.ENROLL(0), .N_RO(N_RO), .WINDOW(WINDOW), .VOTES(VOTES), .SETTLE(4),
                 .R(R), .NB(NB), .SIM_RO(1)) u_rec (
        .clk(clk), .rst(rst), .start(c_start),
        .mask_in_valid(c_mv), .mask_in_ready(c_mr), .mask_in_bit(c_mb),
        .mask_out_valid(c_x1), .mask_out_ready(1'b0), .mask_out_bit(c_x2),
        .off_in_valid(c_ov), .off_in_ready(c_or), .off_in_bit(c_ob),
        .off_out_valid(c_x3), .off_out_ready(1'b0), .off_out_bit(c_x4),
        .key(c_key), .key_valid(c_kv), .err(c_err), .nerr(c_nerr)
    );

    // ---------------- too-large NB: must report err ----------------
    logic s_start = 0;
    wire  s_mv, s_mb, s_ov, s_ob, s_kv, s_err, s_x1, s_x2;
    wire [127:0] s_key;
    wire [15:0]  s_nerr;
    puf_keygen #(.ENROLL(1), .N_RO(64), .WINDOW(64), .VOTES(1), .SETTLE(4),
                 .R(R), .NB(20), .SIM_RO(1)) u_small (
        .clk(clk), .rst(rst), .start(s_start),
        .mask_in_valid(1'b0), .mask_in_ready(s_x1), .mask_in_bit(1'b0),
        .mask_out_valid(s_mv), .mask_out_ready(1'b1), .mask_out_bit(s_mb),
        .off_in_valid(1'b0), .off_in_ready(s_x2), .off_in_bit(1'b0),
        .off_out_valid(s_ov), .off_out_ready(1'b1), .off_out_bit(s_ob),
        .key(s_key), .key_valid(s_kv), .err(s_err), .nerr(s_nerr)
    );

    // helper data and raw-bit taps
    bit mask [$], offs [$];
    bit raw_e [$], raw_c [$], deb_e [$];
    always @(posedge clk) begin
        if (e_mv) mask.push_back(e_mb);
        if (e_ov) offs.push_back(e_ob);
        if (u_enr.raw_valid && u_enr.raw_ready) raw_e.push_back(u_enr.raw_bit);
        if (u_enr.deb_valid && u_enr.deb_ready) deb_e.push_back(u_enr.deb_bit);
        if (u_rec.raw_valid && u_rec.raw_ready) raw_c.push_back(u_rec.raw_bit);
    end

    task automatic power_up();
        @(negedge clk); rst = 1'b1; @(negedge clk); @(negedge clk); rst = 1'b0;
    endtask

    task automatic enroll(output logic [127:0] k);
        mask = {}; offs = {}; raw_e = {}; deb_e = {};
        power_up();
        @(negedge clk); e_start = 1; @(negedge clk); e_start = 0;
        while (!e_kv && !e_err) @(negedge clk);
        if (e_err) $fatal(1, "enrollment: out of PUF bits");
        if (offs.size() != NB * (R - 1)) $fatal(1, "enrollment: %0d offset bits", offs.size());
        k = e_key;
    endtask

    // regenerate K from helper data; returns K, corrections, raw-bit errors vs enrollment
    task automatic regenerate(output logic [127:0] k, output int ncorr, output int rawdiff);
        raw_c = {};
        power_up();
        @(negedge clk); c_start = 1; @(negedge clk); c_start = 0;
        fork
            foreach (mask[i]) begin
                c_mv = 1; c_mb = mask[i];
                while (!c_mr) @(negedge clk);
                @(negedge clk); c_mv = 0;
            end
            foreach (offs[i]) begin
                c_ov = 1; c_ob = offs[i];
                while (!c_or) @(negedge clk);
                @(negedge clk); c_ov = 0;
            end
            while (!c_kv) @(negedge clk);
        join
        k = c_key;
        ncorr = c_nerr;
        rawdiff = 0;
        foreach (raw_c[i]) if (i < raw_e.size()) rawdiff += (raw_c[i] != raw_e[i]);
    endtask

    function automatic real pct(int a, int b);
        return 100.0 * a / b;
    endfunction

    initial begin
        logic [127:0] k1, k;
        int ncorr, rawdiff, ones;
        int tot_corr = 0, tot_raw = 0, tot_n = 0;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // ---- 1. enrollment, chip 1 ----
        chip = 1; run = 1; bias_ppm = 0;
        enroll(k1);
        ones = 0; foreach (raw_e[i]) ones += raw_e[i];
        $display("PASS  chip 1 enrolled: K1 = %h", k1);
        $display("      %0d raw bits (%.1f%% ones), %0d mask bits, %0d offset bits", raw_e.size(),
                 pct(ones, raw_e.size()), mask.size(), offs.size());

        // ---- 2. regenerate on chip 1 ----
        for (int r = 2; r <= 7; r++) begin
            run = r;
            regenerate(k, ncorr, rawdiff);
            if (k !== k1) $fatal(1, "chip 1 power-up %0d: K MISMATCH %h", r, k);
            tot_corr += ncorr; tot_raw += rawdiff; tot_n += raw_c.size();
            $display("PASS  chip 1 power-up %0d: K = K1 (%0d raw bits differ, %0d bits corrected)", r, rawdiff, ncorr);
        end
        $display("      intra-chip raw HD %.2f%% (after TMV), 0%% after correction", pct(tot_raw, tot_n));

        // ---- 3. other chip, same helper ----
        chip = 2; run = 50;
        regenerate(k, ncorr, rawdiff);
        if (k === k1) $fatal(1, "chip 2 produced chip 1's key");
        if (rawdiff < raw_c.size() * 35 / 100 || rawdiff > raw_c.size() * 65 / 100)
            $fatal(1, "inter-chip raw HD %0d of %0d not ~50%%", rawdiff, raw_c.size());
        $display("PASS  chip 2 with chip 1's helper: K differs; inter-chip raw HD %.1f%%",
                 pct(rawdiff, raw_c.size()));

        // ---- 4. strongly biased chip ----
        chip = 3; run = 60; bias_ppm = 8000;
        enroll(k1);
        ones = 0; foreach (raw_e[i]) ones += raw_e[i];
        if (ones * 100 > raw_e.size() * 40) $fatal(1, "bias injection did not work (%0d ones)", ones);
        begin
            int dones = 0;
            foreach (deb_e[i]) dones += deb_e[i];
            if (dones * 100 < deb_e.size() * 30 || dones * 100 > deb_e.size() * 70)
                $fatal(1, "debiased bits still biased: %0d of %0d ones", dones, deb_e.size());
            $display("PASS  chip 3 (biased) enrolled: raw %.1f%% ones -> debiased %.1f%% ones (%0d bits)",
                     pct(ones, raw_e.size()), pct(dones, deb_e.size()), deb_e.size());
        end
        for (int r = 61; r <= 64; r++) begin
            run = r;
            regenerate(k, ncorr, rawdiff);
            if (k !== k1) $fatal(1, "biased chip power-up %0d: K MISMATCH", r);
            $display("PASS  chip 3 power-up %0d: K stable (%0d raw bits differ, %0d corrected)", r, rawdiff, ncorr);
        end
        bias_ppm = 0;

        // ---- 5. not enough PUF bits -> err ----
        chip = 4; run = 70;
        power_up();
        @(negedge clk); s_start = 1; @(negedge clk); s_start = 0;
        while (!s_err && !s_kv) @(negedge clk);
        if (!s_err || s_kv) $fatal(1, "out-of-bits not reported");
        $display("PASS  too few PUF bits for NB*R -> err = 1, no key");

        $display("TEST PASSED");
        $finish;
    end
endmodule
