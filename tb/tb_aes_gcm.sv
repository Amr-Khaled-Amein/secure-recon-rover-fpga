// ============================================================================
// tb_aes_gcm : self-checking testbench for aes_gcm (and ghash, aes128_core).
//
// Vector files (model/vectors/, made by model/gen_gcm_vectors.py with the
// Python `cryptography` library as golden model):
//   gcm_kat.txt         McGrew-Viega test cases 1-4
//   gcm_random.txt      random vectors incl. 18 B AAD + 640 B packets, and
//                       tampered tag / ciphertext / AAD (must be rejected)
//   gcm_wycheproof.txt  Wycheproof AES-GCM (128-bit key, 96-bit IV, 128-bit tag)
// Valid vectors: encrypt -> ciphertext and tag must match; decrypt ->
// plaintext must match and tag_match = 1. Invalid vectors: tag_match = 0.
// Random gaps on in_valid and stalls on out_ready test the handshakes, and
// bytes past the end of the last block are fed as garbage.
// Also checks that the IV-reuse monitor fires on a deliberate reuse.
//
// Vector folder: +VEC_DIR=<path>  (default C:/AES_128/model/vectors)
// Prints TEST PASSED at the end; any mismatch stops with $fatal.
// ============================================================================
`timescale 1ns/1ps
module tb_aes_gcm;

    localparam int MAXB = 1024;
    typedef byte unsigned bytes_t[];

    logic         clk = 1'b0;
    logic         rst = 1'b1;
    logic         start = 1'b0, decrypt = 1'b0, ecb = 1'b0;
    logic [127:0] key = '0;
    logic [95:0]  iv = '0;
    logic [15:0]  aad_len = '0, txt_len = '0;
    logic         in_valid = 1'b0, out_ready = 1'b0;
    logic [127:0] in_data = '0, tag_in = '0;
    wire          ready, in_ready, out_valid, done, tag_match;
    wire  [127:0] out_data, tag;

    always #5 clk = ~clk;

    aes_gcm #(.LEN_W(16)) dut (
        .clk(clk), .rst(rst), .start(start), .decrypt(decrypt), .ecb(ecb), .key(key), .iv(iv),
        .aad_len(aad_len), .txt_len(txt_len), .ready(ready),
        .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
        .done(done), .tag(tag), .tag_in(tag_in), .tag_match(tag_match)
    );

    gcm_iv_monitor #(.FATAL(0), .NAME("tb_aes_gcm")) mon (
        .clk(clk), .start(start), .ready(ready), .decrypt(decrypt), .ecb(ecb), .key(key), .iv(iv)
    );

    int gap_pct = 0, stall_pct = 0;
    int done_count = 0, n_ops = 0, n_vec = 0, n_rejected = 0;
    longint cyc = 0;
    always @(posedge clk) begin
        cyc++;
        if (done) done_count++;
    end

    initial begin : watchdog
        #50ms $fatal(1, "TIMEOUT");
    end

    function automatic string hexs(bytes_t b);
        string s = "";
        foreach (b[i]) s = {s, $sformatf("%02x", b[i])};
        return (b.size() == 0) ? "(empty)" : s;
    endfunction

    // One GCM operation through the handshakes.
    task automatic gcm_op(input bit dec, input logic [127:0] k, input logic [95:0] v,
                          input bytes_t aad, input bytes_t txt, input logic [127:0] exp_tag,
                          output bytes_t res, output logic [127:0] got_tag, output bit match);
        int na = (aad.size() + 15) / 16;
        int nt = (txt.size() + 15) / 16;
        int d0 = done_count;
        bytes_t r = new[txt.size()];

        while (!ready) @(negedge clk);
        start = 1'b1; decrypt = dec; key = k; iv = v;
        aad_len = aad.size(); txt_len = txt.size(); tag_in = exp_tag;
        @(negedge clk);
        start = 1'b0;
        key = $urandom; iv = $urandom;          // must have been latched

        fork
            begin : feeder
                for (int b = 0; b < na + nt; b++) begin
                    logic [127:0] blk;
                    for (int j = 0; j < 16; j++) begin
                        int idx = (b < na) ? 16*b + j : 16*(b-na) + j;
                        int len = (b < na) ? aad.size() : txt.size();
                        byte unsigned val = (idx < len) ? ((b < na) ? aad[idx] : txt[idx]) : 8'($urandom);
                        blk[127-8*j -: 8] = val;
                    end
                    while ($urandom_range(99) < gap_pct) @(negedge clk);
                    in_valid = 1'b1; in_data = blk;
                    while (!in_ready) @(negedge clk);
                    @(negedge clk);
                    in_valid = 1'b0; in_data = 'x;
                end
            end
            begin : collector
                int b = 0;
                while (b < nt) begin
                    @(negedge clk);
                    out_ready = ($urandom_range(99) >= stall_pct);
                    if (out_valid && out_ready) begin
                        for (int j = 0; j < 16; j++) begin
                            int idx = 16*b + j;
                            if (idx < txt.size()) r[idx] = out_data[127-8*j -: 8];
                            else if (out_data[127-8*j -: 8] !== 8'h00)
                                $fatal(1, "out_data byte past the end is not zero");
                        end
                        b++;
                    end
                end
                @(negedge clk);
                out_ready = 1'b0;
            end
        join

        while (!ready) @(negedge clk);
        @(negedge clk);                         // let the done counter see the pulse
        if (done_count != d0 + 1) $fatal(1, "done pulsed %0d times", done_count - d0);
        if (out_valid) $fatal(1, "extra output block");
        res = r; got_tag = tag; match = tag_match;
        n_ops++;
    endtask

    function automatic bytes_t to_bytes(input logic [8*MAXB-1:0] vec, input int n);
        bytes_t b = new[n];
        for (int j = 0; j < n; j++) b[j] = vec[8*(n-1-j) +: 8];
        return b;
    endfunction

    task automatic run_file(input string dir, input string name, input int gap, input int stall);
        string path = {dir, "/", name};
        int fd, r, alen, plen, valid;
        string id;
        logic [127:0] k, tg, got_tag;
        logic [95:0] v;
        logic [8*MAXB-1:0] av, pv, cv;
        bytes_t a, p, c, res;
        bit match;
        int cnt = 0;

        gap_pct = gap; stall_pct = stall;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "cannot open %s (set +VEC_DIR=...)", path);
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%s %h %h %d %d %h %h %h %h %d\n", id, k, v, alen, plen, av, pv, cv, tg, valid);
            if (r != 10) begin
                if (r <= 0) break;
                $fatal(1, "%s: bad line (fields read: %0d)", path, r);
            end
            a = to_bytes(av, alen); p = to_bytes(pv, plen); c = to_bytes(cv, plen);
            if (valid) begin
                mon.clear();
                gcm_op(1'b0, k, v, a, p, '0, res, got_tag, match);
                if (res != c)
                    $fatal(1, "[%s] ENCRYPT ciphertext MISMATCH\n  got %s\n  exp %s", id, hexs(res), hexs(c));
                if (got_tag !== tg)
                    $fatal(1, "[%s] ENCRYPT tag MISMATCH got %h exp %h", id, got_tag, tg);
                gcm_op(1'b1, k, v, a, c, tg, res, got_tag, match);
                if (res != p)
                    $fatal(1, "[%s] DECRYPT plaintext MISMATCH\n  got %s\n  exp %s", id, hexs(res), hexs(p));
                if (!match) $fatal(1, "[%s] DECRYPT valid tag rejected", id);
            end else begin
                gcm_op(1'b1, k, v, a, c, tg, res, got_tag, match);
                if (match) $fatal(1, "[%s] DECRYPT forged/tampered message ACCEPTED", id);
                n_rejected++;
            end
            cnt++;
        end
        $fclose(fd);
        if (cnt == 0) $fatal(1, "%s: no vectors", path);
        n_vec += cnt;
        $display("PASS  %-20s %4d vectors (gaps %0d%%, stalls %0d%%)", name, cnt, gap, stall);
    endtask

    initial begin
        string dir;
        bytes_t res, msg, z18;
        logic [127:0] t1, t2;
        bit m;
        longint c0;

        if (!$value$plusargs("VEC_DIR=%s", dir)) dir = "C:/AES_128/model/vectors";
        z18 = new[18];
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        run_file(dir, "gcm_kat.txt", 0, 0);
        run_file(dir, "gcm_kat.txt", 40, 40);
        run_file(dir, "gcm_random.txt", 30, 30);
        run_file(dir, "gcm_wycheproof.txt", 10, 10);

        // ECB mode (used by session_kdf): FIPS-197 C.1, and the IV monitor ignores it
        begin
            int r0 = mon.reuse_count;
            for (int rep = 0; rep < 2; rep++) begin
                while (!ready) @(negedge clk);
                start = 1'b1; ecb = 1'b1; key = 128'h000102030405060708090a0b0c0d0e0f; iv = '0;
                @(negedge clk);
                start = 1'b0; ecb = 1'b0; key = '0;
                in_valid = 1'b1; in_data = 128'h00112233445566778899aabbccddeeff;
                while (!in_ready) @(negedge clk);
                @(negedge clk);
                in_valid = 1'b0;
                while (!ready) @(negedge clk);
                if (tag !== 128'h69c4e0d86a7b0430d8cdb78070b4c55a) $fatal(1, "ECB MISMATCH: %h", tag);
                if (out_valid) $fatal(1, "ECB produced an output block");
                @(negedge clk);                 // let the done counter see the pulse
            end
            if (mon.reuse_count != r0) $fatal(1, "IV monitor counted ECB calls");
            $display("PASS  ECB mode: FIPS-197 C.1");
        end

        // Throughput of one video packet (18 B AAD + 640 B), no stalls
        gap_pct = 0; stall_pct = 0;
        msg = new[640];
        mon.clear();
        c0 = cyc;
        gcm_op(1'b0, 128'h1, 96'h1, z18, msg, '0, res, t1, m);
        $display("INFO  one 674-byte packet: %0d cycles = %.1f us at 100 MHz", cyc - c0, (cyc - c0) / 100.0);

        // The IV-reuse monitor must catch a deliberate reuse ...
        mon.clear();
        msg = new[16];
        gcm_op(1'b0, 128'h55, 96'h77, z18, msg, '0, res, t1, m);
        gcm_op(1'b0, 128'h55, 96'h78, z18, msg, '0, res, t1, m);
        if (mon.reuse_count != 0) $fatal(1, "IV monitor fired without reuse");
        gcm_op(1'b0, 128'h55, 96'h77, z18, msg, '0, res, t2, m);
        if (mon.reuse_count != 1) $fatal(1, "IV monitor MISSED a reuse");
        // ... and ignore decryptions of the same packet
        gcm_op(1'b1, 128'h55, 96'h77, z18, msg, '0, res, t2, m);
        gcm_op(1'b1, 128'h55, 96'h77, z18, msg, '0, res, t2, m);
        if (mon.reuse_count != 1) $fatal(1, "IV monitor counted a decryption");
        $display("PASS  IV-reuse monitor catches a reuse, ignores decryptions");

        // reset in the middle of an operation, then a clean KAT
        fork
            begin
                msg = new[64];
                gcm_op(1'b0, 128'h9, 96'h9, z18, msg, '0, res, t1, m);
            end
            begin
                repeat (300) @(negedge clk);
                rst = 1'b1;
            end
        join_any
        disable fork;
        in_valid = 1'b0; out_ready = 1'b0; start = 1'b0;
        @(negedge clk); rst = 1'b0; @(negedge clk);
        if (!ready || out_valid) $fatal(1, "not idle after reset");
        run_file(dir, "gcm_kat.txt", 0, 0);
        $display("PASS  reset in the middle of a packet");

        $display("%0d vectors, %0d GCM operations, %0d tampered messages rejected", n_vec, n_ops, n_rejected);
        $display("TEST PASSED");
        $finish;
    end

endmodule
