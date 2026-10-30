// ============================================================================
// tb_hello_fsm : rover + base session setup, end to end (project brief §5.2, §10.8)
//
// Each side: hello_fsm + session_kdf + aes_gcm, with a FATAL gcm_iv_monitor
// (the IV-reuse assertion; it must never fire, also across reboots).
// A testbench "channel" carries HELLO messages and can drop, forge and replay
// them. A simple packet-layer model sends video (rover -> base) and commands
// (base -> rover) every 2,000 cycles: a packet "verifies" at the receiver iff
// the receiver holds the same K_s for that session_id, which drives
// confirm_pend / confirm_cur.
//
//   1. normal handshake: same K_s and session_id on both sides, both
//      established after key confirmation
//   2. forged rover HELLO (bad tag): ignored, no pending session
//   3. replayed rover HELLO: pending session never confirmed, expires;
//      the running session is untouched
//   4. link loss: rover restarts after T_LINK; a replayed old base reply is
//      rejected (wrong N_rover echo); new session after the link returns
//   5. base reboot: base sends HELLO_REQ, rover re-handshakes, new K_s
//   6. rover reboot: new HELLO; the base keeps the old session until the new
//      one is confirmed
//   7. wrong K at the base: no session, rover keeps retrying
//   8. rover TRNG blocked: no HELLO is ever sent
// Prints TEST PASSED at the end; any failure stops with $fatal.
// ============================================================================
`timescale 1ns/1ps

`define WAIT_FOR(COND, N, MSG) \
    begin wcnt = 0; \
        while (!(COND)) begin @(negedge clk); wcnt++; if (wcnt > (N)) $fatal(1, "timeout waiting for: %s", MSG); end \
    end

module tb_hello_fsm;

    localparam int T_REPLY = 20000, T_CONFIRM = 20000, T_LINK = 30000,
                   T_REQ_HOLD = 10000, T_REQ_PERIOD = 8000, T_TRAFFIC = 2000;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    initial begin : watchdog
        #200ms $fatal(1, "TIMEOUT");
    end

    // message = {hdr(144), plen(5), nr(64), nb(64), tag(128)}
    typedef logic [404:0] msg_t;

    // =====================================================================
    // One side = hello_fsm + session_kdf + aes_gcm (+ IV monitor)
    // =====================================================================
    logic         rst_r = 1'b1, rst_b = 1'b1;
    logic [127:0] k_r = 128'h2b7e151628aed2a6abf7158809cf4f3c;   // rover's PUF key
    logic [127:0] k_b = 128'h2b7e151628aed2a6abf7158809cf4f3c;   // base's enrolled copy
    logic         kv_r = 1'b0, kv_b = 1'b0;
    logic         rndv_r = 1'b1, rndv_b = 1'b1;

    // rx / confirm drives
    logic         rxv_r = 0, rxv_b = 0;
    logic [143:0] rxh_r, rxh_b;
    logic [4:0]   rxp_r, rxp_b;
    logic [63:0]  rxnr_r, rxnr_b, rxnb_r, rxnb_b;
    logic [127:0] rxt_r, rxt_b;
    logic         cp_r = 0, cc_r = 0, cp_b = 0, cc_b = 0;

    // ---- rover ----
    wire          r_cv, r_cr, r_cver, r_rv, r_rm, r_txv;
    wire [1:0]    r_cop;
    wire [127:0]  r_ckey, r_ctag, r_rd, r_txtag, r_cur_ks, r_pend_ks;
    wire [95:0]   r_civ;
    wire [383:0]  r_caad;
    wire [5:0]    r_calen;
    wire [63:0]   r_cnr, r_cnb, r_txnr, r_txnb;
    wire [143:0]  r_txhdr;
    wire [4:0]    r_txplen;
    wire          r_cur_v, r_pend_v;
    wire [23:0]   r_cur_sid, r_pend_sid;
    wire [15:0]   r_restarts;
    wire          r_rndr;

    hello_fsm #(.ROLE(0), .T_REPLY(T_REPLY), .T_CONFIRM(T_CONFIRM), .T_LINK(T_LINK),
                .T_REQ_HOLD(T_REQ_HOLD), .T_REQ_PERIOD(T_REQ_PERIOD)) rover (
        .clk(clk), .rst(rst_r), .k(k_r), .k_valid(kv_r),
        .c_valid(r_cv), .c_ready(r_cr), .c_op(r_cop), .c_verify(r_cver), .c_key(r_ckey), .c_iv(r_civ),
        .c_aad(r_caad), .c_aad_len(r_calen), .c_tag(r_ctag), .c_nr(r_cnr), .c_nb(r_cnb),
        .r_valid(r_rv), .r_data(r_rd), .r_match(r_rm),
        .tx_valid(r_txv), .tx_ready(1'b1), .tx_hdr(r_txhdr), .tx_plen(r_txplen), .tx_nr(r_txnr),
        .tx_nb(r_txnb), .tx_tag(r_txtag),
        .rx_valid(rxv_r), .rx_hdr(rxh_r), .rx_plen(rxp_r), .rx_nr(rxnr_r), .rx_nb(rxnb_r),
        .rx_tag(rxt_r), .confirm_pend(cp_r), .confirm_cur(cc_r),
        .cur_valid(r_cur_v), .cur_ks(r_cur_ks), .cur_sid(r_cur_sid),
        .pend_valid(r_pend_v), .pend_ks(r_pend_ks), .pend_sid(r_pend_sid), .restarts(r_restarts)
    );
    side_crypto #(.NAME("rover")) r_crypto (
        .clk(clk), .rst(rst_r), .rnd_en(rndv_r),
        .c_valid(r_cv), .c_ready(r_cr), .c_op(r_cop), .c_verify(r_cver), .c_key(r_ckey), .c_iv(r_civ),
        .c_aad(r_caad), .c_aad_len(r_calen), .c_tag(r_ctag), .c_nr(r_cnr), .c_nb(r_cnb),
        .r_valid(r_rv), .r_data(r_rd), .r_match(r_rm)
    );

    // ---- base ----
    wire          b_cv, b_cr, b_cver, b_rv, b_rm, b_txv;
    wire [1:0]    b_cop;
    wire [127:0]  b_ckey, b_ctag, b_rd, b_txtag, b_cur_ks, b_pend_ks;
    wire [95:0]   b_civ;
    wire [383:0]  b_caad;
    wire [5:0]    b_calen;
    wire [63:0]   b_cnr, b_cnb, b_txnr, b_txnb;
    wire [143:0]  b_txhdr;
    wire [4:0]    b_txplen;
    wire          b_cur_v, b_pend_v;
    wire [23:0]   b_cur_sid, b_pend_sid;
    wire [15:0]   b_restarts;

    hello_fsm #(.ROLE(1), .T_REPLY(T_REPLY), .T_CONFIRM(T_CONFIRM), .T_LINK(T_LINK),
                .T_REQ_HOLD(T_REQ_HOLD), .T_REQ_PERIOD(T_REQ_PERIOD)) base (
        .clk(clk), .rst(rst_b), .k(k_b), .k_valid(kv_b),
        .c_valid(b_cv), .c_ready(b_cr), .c_op(b_cop), .c_verify(b_cver), .c_key(b_ckey), .c_iv(b_civ),
        .c_aad(b_caad), .c_aad_len(b_calen), .c_tag(b_ctag), .c_nr(b_cnr), .c_nb(b_cnb),
        .r_valid(b_rv), .r_data(b_rd), .r_match(b_rm),
        .tx_valid(b_txv), .tx_ready(1'b1), .tx_hdr(b_txhdr), .tx_plen(b_txplen), .tx_nr(b_txnr),
        .tx_nb(b_txnb), .tx_tag(b_txtag),
        .rx_valid(rxv_b), .rx_hdr(rxh_b), .rx_plen(rxp_b), .rx_nr(rxnr_b), .rx_nb(rxnb_b),
        .rx_tag(rxt_b), .confirm_pend(cp_b), .confirm_cur(cc_b),
        .cur_valid(b_cur_v), .cur_ks(b_cur_ks), .cur_sid(b_cur_sid),
        .pend_valid(b_pend_v), .pend_ks(b_pend_ks), .pend_sid(b_pend_sid), .restarts(b_restarts)
    );
    side_crypto #(.NAME("base")) b_crypto (
        .clk(clk), .rst(rst_b), .rnd_en(rndv_b),
        .c_valid(b_cv), .c_ready(b_cr), .c_op(b_cop), .c_verify(b_cver), .c_key(b_ckey), .c_iv(b_civ),
        .c_aad(b_caad), .c_aad_len(b_calen), .c_tag(b_ctag), .c_nr(b_cnr), .c_nb(b_cnb),
        .r_valid(b_rv), .r_data(b_rd), .r_match(b_rm)
    );

    // =====================================================================
    // Channel: records every HELLO, forwards it unless blocked
    // =====================================================================
    bit   fwd_r2b = 1, fwd_b2r = 1;
    msg_t to_base [$], to_rover [$], log_r [$], log_b [$];
    int   n_req = 0;

    always @(posedge clk) begin
        if (r_txv) begin
            log_r.push_back({r_txhdr, r_txplen, r_txnr, r_txnb, r_txtag});
            if (fwd_r2b) to_base.push_back({r_txhdr, r_txplen, r_txnr, r_txnb, r_txtag});
        end
        if (b_txv) begin
            log_b.push_back({b_txhdr, b_txplen, b_txnr, b_txnb, b_txtag});
            if (b_txhdr[127:120] == 8'h06) n_req++;
            if (fwd_b2r) to_rover.push_back({b_txhdr, b_txplen, b_txnr, b_txnb, b_txtag});
        end
    end

    initial forever begin
        @(negedge clk);
        rxv_b = 1'b0;
        if (to_base.size() > 0) begin {rxh_b, rxp_b, rxnr_b, rxnb_b, rxt_b} = to_base.pop_front(); rxv_b = 1'b1; end
    end
    initial forever begin
        @(negedge clk);
        rxv_r = 1'b0;
        if (to_rover.size() > 0) begin {rxh_r, rxp_r, rxnr_r, rxnb_r, rxt_r} = to_rover.pop_front(); rxv_r = 1'b1; end
    end

    // =====================================================================
    // Packet-layer model: video rover -> base, commands base -> rover
    // =====================================================================
    int           wcnt;
    logic [127:0] t_key;
    logic [23:0]  t_sid;
    bit traffic = 1;
    int video_ok = 0, cmd_ok = 0;
    initial forever begin
        repeat (T_TRAFFIC) @(negedge clk);
        cp_r = 0; cc_r = 0; cp_b = 0; cc_b = 0;
        if (traffic) begin
            // video under the rover's key (current if established, else pending)
            if (r_cur_v || r_pend_v) begin
                t_key = r_cur_v ? r_cur_ks  : r_pend_ks;
                t_sid = r_cur_v ? r_cur_sid : r_pend_sid;
                if (b_pend_v && b_pend_sid == t_sid && b_pend_ks == t_key)    begin cp_b = 1; video_ok++; end
                else if (b_cur_v && b_cur_sid == t_sid && b_cur_ks == t_key)  begin cc_b = 1; video_ok++; end
            end
            // command under the base's current key
            if (b_cur_v) begin
                if (r_pend_v && r_pend_sid == b_cur_sid && r_pend_ks == b_cur_ks)    begin cp_r = 1; cmd_ok++; end
                else if (r_cur_v && r_cur_sid == b_cur_sid && r_cur_ks == b_cur_ks) begin cc_r = 1; cmd_ok++; end
            end
        end
        @(negedge clk);
        cp_r = 0; cc_r = 0; cp_b = 0; cc_b = 0;
    end

    function automatic bit both_established();
        return r_cur_v && b_cur_v && r_cur_ks == b_cur_ks && r_cur_sid == b_cur_sid;
    endfunction

    // =====================================================================
    // Tests
    // =====================================================================
    initial begin
        logic [127:0] ks1, ks2;
        logic [23:0]  sid1;
        msg_t old_hello, old_reply, forged;
        int r0;

        repeat (3) @(negedge clk);
        rst_r = 0; rst_b = 0;
        kv_r = 1; kv_b = 1;

        // ---- 1. normal handshake ----
        `WAIT_FOR(r_pend_v && b_pend_v, 200000, "both pending")
        if (r_pend_ks !== b_pend_ks || r_pend_sid !== b_pend_sid) $fatal(1, "K_s differs between rover and base");
        if (r_cur_v || b_cur_v) $fatal(1, "established before key confirmation");
        if (r_pend_sid !== log_r[0][255:232]) $fatal(1, "session_id is not the first 3 bytes of N_rover");
        `WAIT_FOR(both_established(), 10 * T_TRAFFIC, "both established")
        ks1 = r_cur_ks; sid1 = r_cur_sid;
        old_hello = log_r[log_r.size()-1]; old_reply = log_b[log_b.size()-1];
        $display("PASS  1 handshake: K_s = %h, session_id = %h on both sides, confirmed", ks1, sid1);

        // ---- 2. forged rover HELLO ----
        r0 = b_restarts;
        forged = old_hello;
        forged[255:192] = 64'hdeadbeefcafef00d; forged[380:357] = 24'hdeadbe;   // nr, session_id
        forged[127:0] = 128'h0123456789abcdef0123456789abcdef;               // tag
        to_base.push_back(forged);
        repeat (5000) @(negedge clk);
        if (b_pend_v || b_restarts != r0) $fatal(1, "forged HELLO accepted by the base");
        if (b_cur_ks !== ks1 || !both_established()) $fatal(1, "forged HELLO disturbed the session");
        $display("PASS  2 forged HELLO (bad tag): ignored");

        // ---- 3. replayed rover HELLO ----
        fwd_b2r = 0;                      // the attacker sees the reply but cannot use it
        to_base.push_back(old_hello);
        `WAIT_FOR(b_pend_v, 5000, "base pending after replay")
        fwd_b2r = 1;
        `WAIT_FOR(!b_pend_v, T_CONFIRM + 5000, "replayed pending session expires")
        if (b_cur_ks !== ks1 || !both_established()) $fatal(1, "replayed HELLO changed the running session");
        $display("PASS  3 replayed HELLO: pending session never confirmed, expired; running session kept");

        // ---- 4. link loss, replayed old base reply ----
        traffic = 0;
        fwd_r2b = 0;                      // the rover's new HELLOs do not reach the base
        `WAIT_FOR(!r_cur_v, T_LINK + 5000, "rover drops the session after link loss")
        `WAIT_FOR(r_txv, 100000, "rover sends a new HELLO")
        @(negedge clk);
        to_rover.push_back(old_reply);    // old reply: echoes an old N_rover
        repeat (5000) @(negedge clk);
        if (r_pend_v || r_cur_v) $fatal(1, "rover accepted a replayed base reply");
        $display("PASS  4 link loss: rover restarted after T_LINK; replayed old base reply rejected");
        fwd_r2b = 1; traffic = 1;
        `WAIT_FOR(both_established(), 10 * T_REPLY, "new session after the link returns")
        ks2 = r_cur_ks;
        if (ks2 === ks1) $fatal(1, "new session reused the old K_s");
        $display("PASS  4 link back: new session established, new K_s");

        // ---- 5. base reboot ----
        ks1 = ks2;
        @(negedge clk); rst_b = 1; @(negedge clk); rst_b = 0;
        r0 = n_req;
        `WAIT_FOR(n_req > r0, 4 * T_REQ_PERIOD, "base sends HELLO_REQ")
        `WAIT_FOR(both_established() && r_cur_ks !== ks1, 20 * T_REPLY, "new session after base reboot")
        $display("PASS  5 base reboot: HELLO_REQ -> rover re-handshake -> new K_s");

        // ---- 6. rover reboot ----
        ks1 = b_cur_ks;
        traffic = 0;
        @(negedge clk); rst_r = 1; @(negedge clk); rst_r = 0;
        `WAIT_FOR(b_pend_v, 100000, "base pending after rover reboot")
        if (!b_cur_v || b_cur_ks !== ks1) $fatal(1, "base dropped the old session before confirmation");
        traffic = 1;
        `WAIT_FOR(both_established() && b_cur_ks !== ks1, 10 * T_TRAFFIC, "new session after rover reboot")
        $display("PASS  6 rover reboot: base kept the old session until the new one was confirmed");

        // ---- 7. wrong K at the base ----
        k_b = ~k_b;
        @(negedge clk); rst_r = 1; rst_b = 1; @(negedge clk); rst_r = 0; rst_b = 0;
        r0 = log_r.size();
        repeat (3 * T_REPLY + 20000) @(negedge clk);
        if (r_pend_v || r_cur_v || b_pend_v || b_cur_v) $fatal(1, "session with mismatched K");
        if (log_r.size() - r0 < 3) $fatal(1, "rover did not retry its HELLO");
        $display("PASS  7 wrong K at base: no session; rover retried %0d times with fresh nonces", log_r.size() - r0);
        k_b = ~k_b;

        // ---- 8. rover TRNG blocked ----
        rndv_r = 0;
        @(negedge clk); rst_r = 1; rst_b = 1; @(negedge clk); rst_r = 0; rst_b = 0;
        r0 = log_r.size();
        repeat (3 * T_REPLY) @(negedge clk);
        if (log_r.size() != r0 || r_pend_v) $fatal(1, "HELLO sent without TRNG output");
        $display("PASS  8 rover TRNG blocked: no HELLO sent");
        rndv_r = 1;
        `WAIT_FOR(both_established(), 20 * T_REPLY, "recovers when the TRNG works again")

        $display("      %0d rover HELLOs, %0d base replies/requests, %0d video and %0d command packets verified",
                 log_r.size(), log_b.size(), video_ok, cmd_ok);
        $display("      GCM IV-reuse monitors: rover %0d, base %0d tag computations, no reuse",
                 r_crypto.mon.enc_count, b_crypto.mon.enc_count);
        $display("TEST PASSED");
        $finish;
    end
endmodule

// ----------------------------------------------------------------------------
// session_kdf + aes_gcm + IV monitor, random bits from $urandom when rnd_en
// ----------------------------------------------------------------------------
module side_crypto #(parameter string NAME = "side") (
    input  logic         clk, rst, rnd_en,
    input  logic         c_valid,
    output logic         c_ready,
    input  logic [1:0]   c_op,
    input  logic         c_verify,
    input  logic [127:0] c_key,
    input  logic [95:0]  c_iv,
    input  logic [383:0] c_aad,
    input  logic [5:0]   c_aad_len,
    input  logic [127:0] c_tag,
    input  logic [63:0]  c_nr, c_nb,
    output logic         r_valid,
    output logic [127:0] r_data,
    output logic         r_match
);
    wire g_start, g_decrypt, g_ecb, g_ready, g_in_valid, g_in_ready, g_out_valid, g_out_ready;
    wire g_done, g_tag_match, rnd_ready;
    wire [127:0] g_key, g_in_data, g_tag, g_tag_in, g_out_data;
    wire [95:0]  g_iv;
    wire [15:0]  g_aad_len, g_txt_len;
    logic rnd_bit;
    always @(posedge clk) rnd_bit <= $urandom_range(1);

    session_kdf u_kdf (
        .clk(clk), .rst(rst),
        .cmd_valid(c_valid), .cmd_ready(c_ready), .cmd_op(c_op), .cmd_verify(c_verify),
        .cmd_key(c_key), .cmd_iv(c_iv), .cmd_aad(c_aad), .cmd_aad_len(c_aad_len),
        .cmd_tag(c_tag), .cmd_nr(c_nr), .cmd_nb(c_nb),
        .res_valid(r_valid), .res_data(r_data), .res_match(r_match),
        .rnd_valid(rnd_en), .rnd_ready(rnd_ready), .rnd_bit(rnd_bit),
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
    gcm_iv_monitor #(.FATAL(1), .NAME(NAME)) mon (
        .clk(clk), .start(g_start), .ready(g_ready), .decrypt(g_decrypt), .ecb(g_ecb),
        .key(g_key), .iv(g_iv)
    );
endmodule
