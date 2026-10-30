// ============================================================================
// tb_fuzzy_extractor : self-checking testbench for fuzzy_extractor (R=5, NB=40).
//
//   enroll      : random x -> output = x, helper w_i = x_i xor x_0
//   reconstruct : x with 0..2 errors in every block -> output = x exactly,
//                 nerr = number of injected errors
//   limit       : 3 errors in one block -> that block decodes to the wrong
//                 codeword (complement), the others stay correct
//   done / finished after NB blocks; no more input accepted
//   Random gaps / back-pressure on every stream.
// Prints TEST PASSED at the end; any mismatch stops with $fatal.
// ============================================================================
`timescale 1ns/1ps
module tb_fuzzy_extractor;

    localparam int R = 5, NB = 40, N = R * NB;

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;
    initial begin : watchdog
        #10ms $fatal(1, "TIMEOUT");
    end

    // enrollment instance
    logic e_iv = 0, e_ib = 0, e_or = 0, e_qr = 0;
    wire  e_ir, e_ov, e_ob, e_qv, e_qb, e_done, e_fin, e_x;
    wire [15:0] e_nerr;
    fuzzy_extractor #(.R(R), .NB(NB), .ENROLL(1)) u_enr (
        .clk(clk), .rst(rst), .in_valid(e_iv), .in_ready(e_ir), .in_bit(e_ib),
        .off_in_valid(1'b0), .off_in_ready(e_x), .off_in_bit(1'b0),
        .off_out_valid(e_ov), .off_out_ready(e_or), .off_out_bit(e_ob),
        .out_valid(e_qv), .out_ready(e_qr), .out_bit(e_qb),
        .done(e_done), .finished(e_fin), .nerr(e_nerr)
    );

    // reconstruction instance
    logic c_iv = 0, c_ib = 0, c_wv = 0, c_wb = 0, c_qr = 0;
    wire  c_ir, c_wr, c_qv, c_qb, c_done, c_fin, c_x1, c_x2;
    wire [15:0] c_nerr;
    fuzzy_extractor #(.R(R), .NB(NB), .ENROLL(0)) u_rec (
        .clk(clk), .rst(rst), .in_valid(c_iv), .in_ready(c_ir), .in_bit(c_ib),
        .off_in_valid(c_wv), .off_in_ready(c_wr), .off_in_bit(c_wb),
        .off_out_valid(c_x1), .off_out_ready(1'b0), .off_out_bit(c_x2),
        .out_valid(c_qv), .out_ready(c_qr), .out_bit(c_qb),
        .done(c_done), .finished(c_fin), .nerr(c_nerr)
    );

    bit x [N];
    bit helper [$];

    task automatic do_reset();
        @(negedge clk); rst = 1'b1; @(negedge clk); rst = 1'b0;
    endtask

    // returns the output bits of the reconstruction instance for input xin
    task automatic reconstruct(input bit xin [N], output bit q [$]);
        q = {};
        fork
            for (int i = 0; i < N; i++) begin
                while ($urandom_range(99) < 20) @(negedge clk);
                c_iv = 1; c_ib = xin[i];
                while (!c_ir) @(negedge clk);
                @(negedge clk); c_iv = 0;
            end
            foreach (helper[i]) begin
                while ($urandom_range(99) < 20) @(negedge clk);
                c_wv = 1; c_wb = helper[i];
                while (!c_wr) @(negedge clk);
                @(negedge clk); c_wv = 0;
            end
            while (q.size() < N) begin
                @(negedge clk);
                c_qr = ($urandom_range(99) < 70);
                if (c_qv && c_qr) q.push_back(c_qb);
            end
        join
        @(negedge clk); c_qr = 0;
        repeat (3) @(negedge clk);
        if (!c_fin || c_ir || c_qv) $fatal(1, "not finished / still accepting after %0d blocks", NB);
    endtask

    initial begin
        bit q [$], xe [N];
        int injected = 0, ndone = 0;
        for (int i = 0; i < N; i++) x[i] = $urandom_range(1);
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // ---------------- enrollment ----------------
        fork
            for (int i = 0; i < N; i++) begin
                while ($urandom_range(99) < 20) @(negedge clk);
                e_iv = 1; e_ib = x[i];
                while (!e_ir) @(negedge clk);
                @(negedge clk); e_iv = 0;
            end
            while (q.size() < N || helper.size() < NB * (R - 1)) begin
                @(negedge clk);
                e_or = ($urandom_range(99) < 70);
                e_qr = ($urandom_range(99) < 70);
                if (e_ov && e_or) helper.push_back(e_ob);
                if (e_qv && e_qr) q.push_back(e_qb);
                if (e_done) ndone++;
            end
        join
        repeat (3) @(negedge clk);
        if (!e_fin) $fatal(1, "enroll: not finished");
        for (int i = 0; i < N; i++) if (q[i] != x[i]) $fatal(1, "enroll: output bit %0d != x", i);
        for (int b = 0; b < NB; b++)
            for (int i = 1; i < R; i++)
                if (helper[b*(R-1) + i-1] != (x[b*R+i] ^ x[b*R]))
                    $fatal(1, "enroll: helper bit block %0d i %0d wrong", b, i);
        $display("PASS  enroll: output = x, %0d helper bits = x_i xor x_0", helper.size());

        // ---------------- reconstruct, <= 2 errors per block ----------------
        xe = x;
        for (int b = 0; b < NB; b++) begin
            automatic int ne = b % 3;              // 0, 1, 2 errors
            automatic int pos [$] = {};
            for (int i = 0; i < R; i++) pos.push_back(i);
            pos.shuffle();
            for (int e = 0; e < ne; e++) xe[b*R + pos[e]] ^= 1'b1;
            injected += ne;
        end
        do_reset();
        reconstruct(xe, q);
        for (int i = 0; i < N; i++) if (q[i] != x[i]) $fatal(1, "reconstruct: bit %0d not corrected", i);
        if (c_nerr != injected) $fatal(1, "nerr = %0d, injected %0d", c_nerr, injected);
        $display("PASS  reconstruct: %0d errors (0-2 per block) all corrected, nerr = %0d", injected, c_nerr);

        // ---------------- 3 errors in block 7: beyond the code ----------------
        xe = x;
        xe[7*R+0] ^= 1; xe[7*R+2] ^= 1; xe[7*R+4] ^= 1;
        do_reset();
        reconstruct(xe, q);
        for (int i = 0; i < N; i++) begin
            bit exp = (i / R == 7) ? !x[i] : x[i];
            if (q[i] != exp) $fatal(1, "3-error block: bit %0d unexpected", i);
        end
        $display("PASS  3 errors in one block: that block fails (as expected for R=5), others correct");

        $display("TEST PASSED");
        $finish;
    end
endmodule
