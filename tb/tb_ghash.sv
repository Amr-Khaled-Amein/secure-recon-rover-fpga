// ============================================================================
// tb_ghash : self-checking testbench for ghash.
//
// Vectors from the Python GHASH model (model/gen_ghash_vectors.py), which is
// itself checked against the `cryptography` library's GCM tags. Includes
// H = 0 and H = 1 (0x80 00..00 in GCM bit order: Y = Y xor X).
//   - y after every block matches the model (chained steps)
//   - done exactly 128 cycles after start; ready low while busy
//   - start ignored while busy; clear resets Y
// Prints TEST PASSED at the end; any mismatch stops with $fatal.
// ============================================================================
`timescale 1ns/1ps
module tb_ghash;

    logic clk = 1'b0, rst = 1'b1, clear = 1'b0, start = 1'b0;
    logic [127:0] x = '0, h = '0;
    wire ready, done;
    wire [127:0] y;
    always #5 clk = ~clk;

    ghash dut (.clk(clk), .rst(rst), .clear(clear), .start(start), .x(x), .h(h),
               .ready(ready), .done(done), .y(y));

    initial begin : watchdog
        #10ms $fatal(1, "TIMEOUT");
    end

    task automatic step(input logic [127:0] xi, input logic [127:0] hi);
        int cyc = 0;
        while (!ready) @(negedge clk);
        start = 1; x = xi; h = hi;
        @(negedge clk);
        start = 0; x = $urandom; h = $urandom;        // must have been sampled
        // a start while busy must be ignored
        start = 1; @(negedge clk); start = 0;
        cyc = 1;
        while (!done) begin
            if (ready) $fatal(1, "ready while busy");
            @(negedge clk); cyc++;
        end
        if (cyc != 128) $fatal(1, "done after %0d cycles, expected 128", cyc);
    endtask

    initial begin
        string dir;
        int fd, n, cnt = 0;
        logic [127:0] hv, xs [8], ys [8];
        if (!$value$plusargs("VEC_DIR=%s", dir)) dir = "C:/AES_128/model/vectors";
        repeat (3) @(negedge clk);
        rst = 0;
        fd = $fopen({dir, "/ghash.txt"}, "r");
        if (fd == 0) $fatal(1, "cannot open ghash.txt");
        while ($fscanf(fd, "%h %d", hv, n) == 2) begin
            for (int i = 0; i < n; i++) void'($fscanf(fd, "%h", xs[i]));
            for (int i = 0; i < n; i++) void'($fscanf(fd, "%h", ys[i]));
            while (!ready) @(negedge clk);
            clear = 1; @(negedge clk); clear = 0;
            if (y !== 128'd0) $fatal(1, "clear did not reset y");
            for (int i = 0; i < n; i++) begin
                step(xs[i], hv);
                if (y !== ys[i]) $fatal(1, "vector %0d block %0d: y MISMATCH got %h exp %h", cnt, i, y, ys[i]);
            end
            cnt++;
        end
        $fclose(fd);
        if (cnt == 0) $fatal(1, "no vectors");
        $display("PASS  %0d GHASH chains match the model (128 cycles per block)", cnt);
        $display("TEST PASSED");
        $finish;
    end
endmodule
