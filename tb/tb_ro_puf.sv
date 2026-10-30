// ============================================================================
// tb_ro_puf : self-checking testbench for ro_puf with the behavioral RO model.
//
//   - one bit per pair, in order, bit_idx correct, done after the last pair
//   - only the two ROs of the pair being measured ever run (batches)
//   - every bit whose pair differs by > 0.3% in period matches the model
//     (faster RO 2p -> bit 1); >= 90% of all bits match
//   - a second power-up (new noise) gives nearly the same bits
//   - a different chip gives ~50% different bits
//   - random back-pressure on bit_ready
// Prints TEST PASSED at the end; any failure stops with $fatal.
// ============================================================================
`timescale 1ns/1ps
module tb_ro_puf;
    import puf_sim_pkg::*;

    localparam int N_RO = 128, NPAIR = N_RO / 2;
    localparam real NOM_PS = 4000.0;

    logic clk = 1'b0, rst = 1'b1, start = 1'b0, bit_ready = 1'b0;
    wire  busy, bit_valid, bit_out, done;
    wire [15:0] bit_idx;

    always #5 clk = ~clk;

    ro_puf #(.N_RO(N_RO), .WINDOW(512), .VOTES(5), .SETTLE(4), .SIM_RO(1)) dut (
        .clk(clk), .rst(rst), .start(start), .busy(busy),
        .bit_valid(bit_valid), .bit_ready(bit_ready), .bit_out(bit_out),
        .bit_idx(bit_idx), .done(done)
    );

    initial begin : watchdog
        #100ms $fatal(1, "TIMEOUT");
    end

    // at most two ROs running, and only the selected pair
    wire [N_RO-1:0] ens;
    genvar gi;
    generate
        for (gi = 0; gi < N_RO; gi++) begin : g_en
            assign ens[gi] = dut.g_ro[gi].en;
        end
    endgenerate
    always @(ens) begin
        if ($countones(ens) > 2) $fatal(1, "more than two ROs running: %b", ens);
        if ($countones(ens) == 2 && !(ens[{dut.pair, 1'b0}] && ens[{dut.pair, 1'b1}]))
            $fatal(1, "running ROs are not the selected pair");
    end

    bit bits [NPAIR];

    task automatic measure(input int ready_pct);
        int n = 0, d0;
        @(negedge clk); start = 1'b1; @(negedge clk); start = 1'b0;
        while (n < NPAIR) begin
            @(negedge clk);
            bit_ready = ($urandom_range(99) < ready_pct);
            if (bit_valid && bit_ready) begin
                if (bit_idx != n) $fatal(1, "bit_idx %0d, expected %0d", bit_idx, n);
                bits[n] = bit_out;
                n++;
            end
        end
        @(negedge clk);
        bit_ready = 1'b0;
        if (busy) $fatal(1, "still busy after the last bit");
    endtask

    initial begin
        bit first [NPAIR];
        int match = 0, n_strong = 0, intra = 0, inter = 0;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        chip = 1; run = 1;
        measure(60);
        first = bits;
        for (int p = 0; p < NPAIR; p++) begin
            automatic real pa = ro_period_ps(2*p, NOM_PS), pb = ro_period_ps(2*p+1, NOM_PS);
            automatic bit  exp = (pa < pb);
            automatic real rel = (pa > pb ? pa - pb : pb - pa) / NOM_PS;
            if (bits[p] == exp) match++;
            else if (rel > 0.003)
                $fatal(1, "pair %0d: bit %0d but RO periods %.1f / %.1f ps differ by %.2f%%",
                       p, bits[p], pa, pb, 100.0 * rel);
            if (rel > 0.003) n_strong++;
        end
        if (match < NPAIR * 9 / 10) $fatal(1, "only %0d of %0d bits match the model", match, NPAIR);
        $display("PASS  chip 1: %0d/%0d bits match the model (%0d pairs differ by > 0.3%%, all match)",
                 match, NPAIR, n_strong);

        chip = 1; run = 2;
        measure(100);
        foreach (bits[p]) intra += (bits[p] != first[p]);
        if (intra > NPAIR / 10) $fatal(1, "same chip, new power-up: %0d bits differ", intra);
        $display("PASS  chip 1 again (new noise): %0d of %0d bits differ (%.1f%%)", intra, NPAIR, 100.0 * intra / NPAIR);

        chip = 2; run = 3;
        measure(100);
        foreach (bits[p]) inter += (bits[p] != first[p]);
        if (inter < NPAIR * 3 / 10 || inter > NPAIR * 7 / 10)
            $fatal(1, "other chip: %0d of %0d bits differ (expected ~50%%)", inter, NPAIR);
        $display("PASS  chip 2: %0d of %0d bits differ from chip 1 (%.1f%%)", inter, NPAIR, 100.0 * inter / NPAIR);

        $display("TEST PASSED");
        $finish;
    end
endmodule
