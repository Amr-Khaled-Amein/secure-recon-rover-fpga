// ============================================================================
// tb_motion_detect : self-checking testbench for motion_detect (320x240).
//
// Synthetic frames: a textured static background with camera noise
// (|noise| <= 6, below PIX_THRESH) and an optional bright block.
// A reference model in the testbench keeps the previous frame and computes
// the expected changed-pixel count; count and motion flag must match exactly.
//   1. first frame after reset           -> motion = 0 (priming)
//   2. static scene with noise           -> count 0, motion = 0
//   3. block moves 40 px                 -> motion = 1
//   4. tiny 8x8 change (64 px)           -> below AREA_THRESH, motion = 0
//   5. block moves while suppress = 1    -> motion = 0, and the frame after
//   6. random gaps in pix_valid, eof after the last pixel
//   7. extra pixels beyond 76,800 ignored
// Prints TEST PASSED at the end; any mismatch stops with $fatal.
// ============================================================================
`timescale 1ns/1ps
module tb_motion_detect;

    localparam int W = 320, H = 240, NPIX = W * H;
    localparam int PIX_THRESH = 20, AREA_THRESH = 400;

    logic clk = 1'b0, rst = 1'b1;
    logic sof = 1'b0, pix_valid = 1'b0, eof = 1'b0, suppress = 1'b0;
    logic [7:0] pix = '0;
    wire        result_valid, motion;
    wire [16:0] motion_count;

    always #5 clk = ~clk;

    motion_detect #(.WIDTH(W), .HEIGHT(H), .PIX_THRESH(PIX_THRESH), .AREA_THRESH(AREA_THRESH)) dut (
        .clk(clk), .rst(rst), .sof(sof), .pix_valid(pix_valid), .pix(pix), .eof(eof),
        .suppress(suppress), .result_valid(result_valid), .motion(motion),
        .motion_count(motion_count)
    );

    initial begin : watchdog
        #200ms $fatal(1, "TIMEOUT");
    end

    byte unsigned frame [NPIX];
    byte unsigned prev  [NPIX];
    bit primed = 0, supp_prev = 0;
    int n_results = 0;

    always @(posedge clk) if (result_valid) n_results++;

    // background texture + noise + optional block of value 230
    function automatic void make_frame(int bx, int by, int bw, int bh, int noise);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) begin
                int v = 60 + ((x * 7 + y * 3) % 50);
                if (x >= bx && x < bx + bw && y >= by && y < by + bh) v = 230;
                if (noise > 0) v += $urandom_range(2 * noise) - noise;
                frame[y * W + x] = byte'(v);
            end
    endfunction

    // send the frame, check the result against the reference model
    task automatic send_frame(input string name, input int gap_pct, input bit supp,
                              input bit exp_motion, input int extra = 0);
        int exp_count = 0, d;
        int r0 = n_results;
        bit exp_m;
        for (int i = 0; i < NPIX; i++) begin
            d = int'(frame[i]) - int'(prev[i]);
            if (d < 0) d = -d;
            if (d > PIX_THRESH) exp_count++;
        end
        exp_m = primed && !supp && !supp_prev && (exp_count > AREA_THRESH);
        if (exp_m != exp_motion)
            $fatal(1, "[%s] test setup wrong: model says motion=%0d", name, exp_m);

        @(negedge clk);
        suppress = supp;
        sof = 1'b1;
        @(negedge clk);
        sof = 1'b0;
        for (int i = 0; i < NPIX + extra; i++) begin
            while ($urandom_range(99) < gap_pct) @(negedge clk);
            pix_valid = 1'b1;
            pix = (i < NPIX) ? frame[i] : 8'(~frame[i % NPIX]);
            @(negedge clk);
            pix_valid = 1'b0;
        end
        if (gap_pct > 0) repeat ($urandom_range(5)) @(negedge clk);
        eof = 1'b1;
        @(negedge clk);
        eof = 1'b0;
        suppress = 1'b0;            // suppress after eof would count for the next frame
        repeat (8) @(negedge clk);

        if (n_results != r0 + 1) $fatal(1, "[%s] result_valid pulsed %0d times", name, n_results - r0);
        if (primed && motion_count !== 17'(exp_count))
            $fatal(1, "[%s] count MISMATCH got %0d exp %0d", name, motion_count, exp_count);
        if (motion !== exp_m)
            $fatal(1, "[%s] motion MISMATCH got %0d exp %0d (count %0d)", name, motion, exp_m, motion_count);
        $display("PASS  count %5d  motion %0d  %s", motion_count, motion, name);

        prev = frame;
        primed = 1;
        supp_prev = supp;
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst = 1'b0;

        make_frame(100, 80, 40, 40, 0);
        send_frame("1 first frame (priming)", 0, 0, 0);
        make_frame(100, 80, 40, 40, 6);
        send_frame("2 static scene + noise", 0, 0, 0);
        make_frame(100, 80, 40, 40, 6);
        send_frame("2b static scene + noise, gaps", 30, 0, 0);
        make_frame(140, 80, 40, 40, 6);
        send_frame("3 block moves 40 px", 0, 0, 1);
        make_frame(180, 100, 40, 40, 6);
        send_frame("3b block moves, gaps", 30, 0, 1);
        make_frame(180, 100, 40, 40, 6);
        for (int y = 10; y < 18; y++) for (int x = 10; x < 18; x++) frame[y * W + x] = 8'd250;
        send_frame("4 tiny 8x8 change", 0, 0, 0);
        make_frame(20, 20, 60, 60, 6);
        send_frame("5 big change while suppress=1", 0, 1, 0);
        make_frame(200, 150, 60, 60, 6);
        send_frame("5b frame after suppress ignored", 0, 0, 0);
        make_frame(100, 150, 60, 60, 6);
        send_frame("5c detection works again", 0, 0, 1);
        make_frame(100, 150, 60, 60, 6);
        send_frame("7 100 extra pixels ignored", 0, 0, 0, 100);
        make_frame(10, 10, 60, 60, 6);
        send_frame("7b next frame still aligned", 0, 0, 1);

        // reset re-primes: the first frame after reset never reports motion
        @(negedge clk); rst = 1'b1; @(negedge clk); rst = 1'b0;
        primed = 0; supp_prev = 0;
        make_frame(250, 10, 60, 60, 6);
        send_frame("8 first frame after reset", 0, 0, 0);

        $display("TEST PASSED");
        $finish;
    end

endmodule
