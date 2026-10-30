// ============================================================================
// tb_puf_hash : self-checking testbench for puf_hash (Davies-Meyer AES).
//
// Expected keys come from the Python model (model/gen_puf_vectors.py,
// `cryptography` AES). Three instances: NBITS = 680 (5 full blocks + 40-bit
// partial), 128 (exactly one block) and 50 (one partial block).
// Random gaps on in_valid. Checks key_valid/done, in_ready drops after the
// last bit, and that a reset clears the key.
// Prints TEST PASSED at the end; any mismatch stops with $fatal.
// ============================================================================
`timescale 1ns/1ps
module tb_puf_hash;

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    initial begin : watchdog
        #20ms $fatal(1, "TIMEOUT");
    end

    // one DUT per length
    logic         v680 = 0, v128 = 0, v50 = 0;
    logic         b680 = 0, b128 = 0, b50 = 0;
    wire          r680, r128, r50, kv680, kv128, kv50, d680, d128, d50;
    wire  [127:0] k680, k128, k50;

    puf_hash #(.NBITS(680)) dut680 (.clk(clk), .rst(rst), .in_valid(v680), .in_ready(r680), .in_bit(b680),
                                    .key(k680), .key_valid(kv680), .done(d680));
    puf_hash #(.NBITS(128)) dut128 (.clk(clk), .rst(rst), .in_valid(v128), .in_ready(r128), .in_bit(b128),
                                    .key(k128), .key_valid(kv128), .done(d128));
    puf_hash #(.NBITS(50))  dut50  (.clk(clk), .rst(rst), .in_valid(v50),  .in_ready(r50),  .in_bit(b50),
                                    .key(k50),  .key_valid(kv50),  .done(d50));

    int ndone = 0;
    always @(posedge clk) ndone += d680 + d128 + d50;

    task automatic do_reset();
        @(negedge clk); rst = 1'b1; @(negedge clk); @(negedge clk); rst = 1'b0;
        if (kv680 || kv128 || kv50 || k680 != 0) $fatal(1, "key not cleared by reset");
    endtask

    task automatic run_file(input string path, input int nbits);
        int fd, r, cnt = 0;
        logic [1023:0] bits;
        logic [127:0]  exp, got;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "cannot open %s", path);
        while (!$feof(fd)) begin
            int d0;
            r = $fscanf(fd, "%h %h\n", bits, exp);
            if (r != 2) break;
            do_reset();
            d0 = ndone;
            for (int i = nbits - 1; i >= 0; i--) begin
                while ($urandom_range(99) < 30) @(negedge clk);
                case (nbits)
                    680: begin v680 = 1; b680 = bits[i]; while (!r680) @(negedge clk); @(negedge clk); v680 = 0; end
                    128: begin v128 = 1; b128 = bits[i]; while (!r128) @(negedge clk); @(negedge clk); v128 = 0; end
                    50:  begin v50  = 1; b50  = bits[i]; while (!r50)  @(negedge clk); @(negedge clk); v50  = 0; end
                endcase
            end
            repeat (20) @(negedge clk);
            case (nbits)
                680: begin got = k680; if (!kv680 || r680) $fatal(1, "680: key_valid/in_ready wrong"); end
                128: begin got = k128; if (!kv128 || r128) $fatal(1, "128: key_valid/in_ready wrong"); end
                50:  begin got = k50;  if (!kv50  || r50)  $fatal(1, "50: key_valid/in_ready wrong"); end
            endcase
            if (ndone != d0 + 1) $fatal(1, "done pulsed %0d times", ndone - d0);
            if (got !== exp) $fatal(1, "NBITS=%0d vector %0d: K MISMATCH got %h exp %h", nbits, cnt, got, exp);
            cnt++;
        end
        $fclose(fd);
        if (cnt == 0) $fatal(1, "%s: no vectors", path);
        $display("PASS  NBITS=%0d: %0d keys match the Python model", nbits, cnt);
    endtask

    initial begin
        string dir;
        if (!$value$plusargs("VEC_DIR=%s", dir)) dir = "C:/AES_128/model/vectors";
        repeat (3) @(negedge clk);
        rst = 1'b0;
        run_file({dir, "/puf_hash_680.txt"}, 680);
        run_file({dir, "/puf_hash_128.txt"}, 128);
        run_file({dir, "/puf_hash_50.txt"}, 50);
        $display("TEST PASSED");
        $finish;
    end
endmodule
