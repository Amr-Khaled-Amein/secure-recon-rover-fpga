// ============================================================================
// tb_session_kdf : self-checking testbench for session_kdf on a real aes_gcm.
//
// Vectors from the Python model (model/gen_session_vectors.py):
//   kdf.txt  : K_s = AES_K(N_rover || N_base)
//   gmac.txt : GMAC tags incl. the exact rover / base HELLO layouts;
//              generate -> tag matches; verify -> match = 1; corrupted tag ->
//              match = 0
//   cond.txt : CBC-MAC conditioning of 4 x 128 TRNG bits
// Also: no random bits are drawn outside OP_NONCE, and a blocked TRNG
// (health failure) stalls OP_NONCE without a result.
// The GCM IV-reuse monitor runs with FATAL = 1.
// Prints TEST PASSED at the end; any mismatch stops with $fatal.
// ============================================================================
`timescale 1ns/1ps
module tb_session_kdf;

    logic clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;
    initial begin : watchdog
        #20ms $fatal(1, "TIMEOUT");
    end

    // command side
    logic         cmd_valid = 0, cmd_verify = 0;
    logic [1:0]   cmd_op = 0;
    logic [127:0] cmd_key = 0, cmd_tag = 0;
    logic [95:0]  cmd_iv = 0;
    logic [383:0] cmd_aad = 0;
    logic [5:0]   cmd_aad_len = 0;
    logic [63:0]  cmd_nr = 0, cmd_nb = 0;
    wire          cmd_ready, res_valid, res_match;
    wire  [127:0] res_data;
    logic         rnd_valid = 0, rnd_bit = 0;
    wire          rnd_ready;

    // engine wiring
    wire g_start, g_decrypt, g_ecb, g_ready, g_in_valid, g_in_ready, g_out_valid, g_out_ready;
    wire g_done, g_tag_match;
    wire [127:0] g_key, g_in_data, g_tag, g_tag_in, g_out_data;
    wire [95:0]  g_iv;
    wire [15:0]  g_aad_len, g_txt_len;

    session_kdf dut (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_op(cmd_op), .cmd_verify(cmd_verify),
        .cmd_key(cmd_key), .cmd_iv(cmd_iv), .cmd_aad(cmd_aad), .cmd_aad_len(cmd_aad_len),
        .cmd_tag(cmd_tag), .cmd_nr(cmd_nr), .cmd_nb(cmd_nb),
        .res_valid(res_valid), .res_data(res_data), .res_match(res_match),
        .rnd_valid(rnd_valid), .rnd_ready(rnd_ready), .rnd_bit(rnd_bit),
        .g_start(g_start), .g_decrypt(g_decrypt), .g_ecb(g_ecb), .g_key(g_key), .g_iv(g_iv),
        .g_aad_len(g_aad_len), .g_txt_len(g_txt_len), .g_ready(g_ready),
        .g_in_valid(g_in_valid), .g_in_ready(g_in_ready), .g_in_data(g_in_data),
        .g_out_valid(g_out_valid), .g_out_ready(g_out_ready), .g_done(g_done),
        .g_tag(g_tag), .g_tag_in(g_tag_in), .g_tag_match(g_tag_match)
    );

    aes_gcm u_gcm (
        .clk(clk), .rst(rst), .start(g_start), .decrypt(g_decrypt), .ecb(g_ecb), .key(g_key),
        .iv(g_iv), .aad_len(g_aad_len), .txt_len(g_txt_len), .ready(g_ready),
        .in_valid(g_in_valid), .in_ready(g_in_ready), .in_data(g_in_data),
        .out_valid(g_out_valid), .out_ready(g_out_ready), .out_data(g_out_data),
        .done(g_done), .tag(g_tag), .tag_in(g_tag_in), .tag_match(g_tag_match)
    );

    gcm_iv_monitor #(.FATAL(1), .NAME("session_kdf")) mon (
        .clk(clk), .start(g_start), .ready(g_ready), .decrypt(g_decrypt), .ecb(g_ecb),
        .key(g_key), .iv(g_iv)
    );

    int drawn = 0;
    always @(posedge clk) if (rnd_valid && rnd_ready) drawn++;

    // issue one command, wait for the result
    task automatic command(input logic [1:0] op);
        while (!cmd_ready) @(negedge clk);
        cmd_valid = 1; cmd_op = op;
        @(negedge clk);
        cmd_valid = 0;
        cmd_key = 'x; cmd_iv = 'x; cmd_aad = 'x; cmd_tag = 'x; cmd_nr = 'x; cmd_nb = 'x;  // must be latched
        while (!res_valid) @(negedge clk);
    endtask

    initial begin
        string dir;
        int fd, n;
        logic [127:0] k, exp, tag;
        logic [95:0]  iv;
        logic [63:0]  nr, nb;
        logic [383:0] aad;
        logic [511:0] raw;
        int alen, ok, d0;

        if (!$value$plusargs("VEC_DIR=%s", dir)) dir = "C:/AES_128/model/vectors";
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // ---- KDF ----
        fd = $fopen({dir, "/kdf.txt"}, "r"); n = 0;
        if (fd == 0) $fatal(1, "cannot open kdf.txt");
        while ($fscanf(fd, "%h %h %h %h\n", k, nr, nb, exp) == 4) begin
            cmd_key = k; cmd_nr = nr; cmd_nb = nb;
            command(1);
            if (res_data !== exp) $fatal(1, "KDF MISMATCH got %h exp %h", res_data, exp);
            n++;
        end
        $fclose(fd);
        if (n == 0) $fatal(1, "no KDF vectors");
        $display("PASS  KDF: %0d K_s values match AES_K(N_rover || N_base)", n);

        // ---- GMAC ----
        fd = $fopen({dir, "/gmac.txt"}, "r"); n = 0;
        if (fd == 0) $fatal(1, "cannot open gmac.txt");
        while ($fscanf(fd, "%h %h %d %h %h %d\n", k, iv, alen, aad, tag, ok) == 6) begin
            if (ok) begin
                cmd_key = k; cmd_iv = iv; cmd_aad = aad; cmd_aad_len = alen; cmd_verify = 0;
                command(2);
                if (res_data !== tag) $fatal(1, "GMAC %0d: tag MISMATCH got %h exp %h", n, res_data, tag);
            end
            cmd_key = k; cmd_iv = iv; cmd_aad = aad; cmd_aad_len = alen; cmd_verify = 1; cmd_tag = tag;
            command(2);
            if (res_match !== ok[0]) $fatal(1, "GMAC %0d: verify gave %0d, expected %0d", n, res_match, ok);
            n++;
        end
        $fclose(fd);
        if (n == 0) $fatal(1, "no GMAC vectors");
        $display("PASS  GMAC: %0d vectors (HELLO layouts, random AAD 1-48 B, corrupted tags rejected)", n);
        if (drawn != 0) $fatal(1, "random bits drawn outside OP_NONCE");

        // ---- NONCE conditioning ----
        fd = $fopen({dir, "/cond.txt"}, "r"); n = 0;
        if (fd == 0) $fatal(1, "cannot open cond.txt");
        while ($fscanf(fd, "%h %h\n", raw, exp) == 2) begin
            d0 = drawn;
            fork
                command(0);
                for (int i = 511; i >= 0; i--) begin
                    while ($urandom_range(99) < 30) @(negedge clk);
                    rnd_valid = 1; rnd_bit = raw[i];
                    while (!rnd_ready) @(negedge clk);
                    @(negedge clk); rnd_valid = 0;
                end
            join
            if (res_data !== exp) $fatal(1, "NONCE MISMATCH got %h exp %h", res_data, exp);
            if (drawn - d0 != 512) $fatal(1, "NONCE drew %0d bits, expected 512", drawn - d0);
            n++;
        end
        $fclose(fd);
        $display("PASS  NONCE: %0d conditioned values match the CBC-MAC model (512 bits each)", n);

        // ---- blocked TRNG: no result ----
        while (!cmd_ready) @(negedge clk);
        cmd_valid = 1; cmd_op = 0; @(negedge clk); cmd_valid = 0;
        for (int i = 0; i < 200; i++) begin
            rnd_valid = 1; rnd_bit = i[0];
            @(negedge clk);
        end
        rnd_valid = 0;
        repeat (5000) @(negedge clk);
        if (res_valid || cmd_ready) $fatal(1, "NONCE finished without enough random bits");
        $display("PASS  TRNG blocked (health failure): nonce request stalls, no result");

        $display("TEST PASSED");
        $finish;
    end
endmodule
