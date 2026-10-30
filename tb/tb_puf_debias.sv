// ============================================================================
// tb_puf_debias : self-checking testbench for puf_debias.
//
//   enroll (ENROLL=1): 4000 raw bits with bias P(1) = 0.75. The mask and the
//       kept bits must equal a Von Neumann reference model, and the kept
//       bits must be unbiased (between 45% and 55% ones).
//   reconstruct (ENROLL=0): same raw bits with 5% bit errors + the stored
//       mask -> output = noisy r0 of every kept pair (exact model match).
//   bypass (ENABLE=0): output = input.
//   Random gaps / back-pressure on every stream.
// Prints TEST PASSED at the end; any mismatch stops with $fatal.
// ============================================================================
`timescale 1ns/1ps
module tb_puf_debias;

    localparam int NRAW = 4000;

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;
    initial begin : watchdog
        #20ms $fatal(1, "TIMEOUT");
    end

    // enrollment instance
    logic e_rv = 0, e_rb = 0, e_mr = 0, e_dr = 0;
    wire  e_rr, e_mv, e_mb, e_dv, e_db, e_mir_unused;
    puf_debias #(.ENROLL(1)) u_enr (
        .clk(clk), .rst(rst), .raw_valid(e_rv), .raw_ready(e_rr), .raw_bit(e_rb),
        .mask_in_valid(1'b0), .mask_in_ready(e_mir_unused), .mask_in_bit(1'b0),
        .mask_out_valid(e_mv), .mask_out_ready(e_mr), .mask_out_bit(e_mb),
        .deb_valid(e_dv), .deb_ready(e_dr), .deb_bit(e_db)
    );

    // reconstruction instance
    logic c_rv = 0, c_rb = 0, c_mv = 0, c_mb = 0, c_dr = 0;
    wire  c_rr, c_mr, c_dv, c_db, c_mov_unused, c_mob_unused;
    puf_debias #(.ENROLL(0)) u_rec (
        .clk(clk), .rst(rst), .raw_valid(c_rv), .raw_ready(c_rr), .raw_bit(c_rb),
        .mask_in_valid(c_mv), .mask_in_ready(c_mr), .mask_in_bit(c_mb),
        .mask_out_valid(c_mov_unused), .mask_out_ready(1'b0), .mask_out_bit(c_mob_unused),
        .deb_valid(c_dv), .deb_ready(c_dr), .deb_bit(c_db)
    );

    // bypass instance
    logic p_rv = 0, p_rb = 0, p_dr = 0;
    wire  p_rr, p_dv, p_db, p_x1, p_x2, p_x3;
    puf_debias #(.ENROLL(0), .ENABLE(0)) u_byp (
        .clk(clk), .rst(rst), .raw_valid(p_rv), .raw_ready(p_rr), .raw_bit(p_rb),
        .mask_in_valid(1'b0), .mask_in_ready(p_x1), .mask_in_bit(1'b0),
        .mask_out_valid(p_x2), .mask_out_ready(1'b0), .mask_out_bit(p_x3),
        .deb_valid(p_dv), .deb_ready(p_dr), .deb_bit(p_db)
    );

    bit raw [NRAW], noisy [NRAW];
    bit exp_mask [$], exp_kept [$], exp_rec [$];
    bit got_mask [$], got_kept [$], got_rec [$], got_byp [$];

    initial begin
        int ones = 0, nerr = 0;
        for (int i = 0; i < NRAW; i++) begin
            raw[i]   = ($urandom_range(99) < 75);
            noisy[i] = raw[i] ^ ($urandom_range(99) < 5);
            nerr += (noisy[i] != raw[i]);
        end
        for (int p = 0; p < NRAW / 2; p++) begin
            bit k = raw[2*p] != raw[2*p+1];
            exp_mask.push_back(k);
            if (k) begin
                exp_kept.push_back(raw[2*p]);
                exp_rec.push_back(noisy[2*p]);
            end
        end

        repeat (3) @(negedge clk);
        rst = 1'b0;

        fork
            // ---- enrollment ----
            for (int i = 0; i < NRAW; i++) begin
                while ($urandom_range(99) < 20) @(negedge clk);
                e_rv = 1; e_rb = raw[i];
                while (!e_rr) @(negedge clk);
                @(negedge clk); e_rv = 0;
            end
            forever begin
                @(negedge clk);
                e_mr = ($urandom_range(99) < 70);
                e_dr = ($urandom_range(99) < 70);
                if (e_mv && e_mr) got_mask.push_back(e_mb);
                if (e_dv && e_dr) got_kept.push_back(e_db);
            end
            // ---- reconstruction ----
            for (int i = 0; i < NRAW; i++) begin
                while ($urandom_range(99) < 20) @(negedge clk);
                c_rv = 1; c_rb = noisy[i];
                while (!c_rr) @(negedge clk);
                @(negedge clk); c_rv = 0;
            end
            for (int p = 0; p < NRAW / 2; p++) begin
                while ($urandom_range(99) < 20) @(negedge clk);
                c_mv = 1; c_mb = exp_mask[p];
                while (!c_mr) @(negedge clk);
                @(negedge clk); c_mv = 0;
            end
            forever begin
                @(negedge clk);
                c_dr = ($urandom_range(99) < 70);
                if (c_dv && c_dr) got_rec.push_back(c_db);
            end
            // ---- bypass ----
            for (int i = 0; i < 200; i++) begin
                p_rv = 1; p_rb = raw[i];
                do begin
                    @(negedge clk);
                    p_dr = ($urandom_range(99) < 50);
                end while (!(p_dv && p_dr));
                got_byp.push_back(p_db);
                @(posedge clk); #1 p_rv = 0;
            end
        join_any
        wait (got_mask.size() == exp_mask.size() && got_kept.size() == exp_kept.size()
              && got_rec.size() == exp_rec.size() && got_byp.size() == 200);
        repeat (50) @(negedge clk);          // catch any extra output
        disable fork;

        if (got_mask != exp_mask) $fatal(1, "enroll mask MISMATCH (%0d vs %0d bits)", got_mask.size(), exp_mask.size());
        if (got_kept != exp_kept) $fatal(1, "enroll kept bits MISMATCH (%0d vs %0d bits)", got_kept.size(), exp_kept.size());
        foreach (got_kept[i]) ones += got_kept[i];
        if (ones * 100 < got_kept.size() * 45 || ones * 100 > got_kept.size() * 55)
            $fatal(1, "debiased bits still biased: %0d ones of %0d", ones, got_kept.size());
        $display("PASS  enroll: %0d raw bits (75%% ones) -> %0d kept bits, %.1f%% ones", NRAW, got_kept.size(),
                 100.0 * ones / got_kept.size());
        if (got_rec != exp_rec) $fatal(1, "reconstruct MISMATCH (%0d vs %0d bits)", got_rec.size(), exp_rec.size());
        $display("PASS  reconstruct with %0d raw bit errors: same pairs selected, %0d bits", nerr, got_rec.size());
        for (int i = 0; i < 200; i++) if (got_byp[i] != raw[i]) $fatal(1, "bypass MISMATCH at %0d", i);
        $display("PASS  bypass (ENABLE=0)");
        $display("TEST PASSED");
        $finish;
    end
endmodule
