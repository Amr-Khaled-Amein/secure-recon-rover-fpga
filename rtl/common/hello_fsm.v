`default_nettype none
// ============================================================================
// hello_fsm
// ----------------------------------------------------------------------------
// Purpose : authenticated session setup (project brief §5.2), rover or base.
//
//   Rover (ROLE = 0)
//     1. wait for K (PUF); draw N_rover; send HELLO = hdr || N_rover with a
//        GMAC tag under K, IV = 03 || N_rover || 000000
//     2. accept only a base reply that echoes the current N_rover and whose
//        GMAC (IV = 04 || N_base || 000000) verifies under K; anything else
//        is dropped. No valid reply within T_REPLY -> new HELLO (new N_rover)
//     3. K_s = AES_K(N_rover || N_base), session_id = N_rover[63:40]
//        -> pending session (the rover already sends with it)
//     4. established when the packet layer reports a valid packet under the
//        pending key (confirm_pend); not within T_CONFIRM -> restart
//     5. established and no valid packet (confirm_cur) for T_LINK -> restart;
//        HELLO_REQ received (rate-limited by T_REQ_HOLD) -> restart
//   Base (ROLE = 1)
//     1. on a rover HELLO whose GMAC verifies under K: draw N_base, reply
//        hdr || N_rover || N_base with its GMAC, derive K_s -> pending session
//     2. the current session stays in use until a packet verifies under the
//        pending key (confirm_pend); then pending replaces current. An
//        unconfirmed pending session expires after T_CONFIRM. (A replayed
//        old rover HELLO therefore cannot disturb the running session.)
//     3. while it has no session at all, send HELLO_REQ every T_REQ_PERIOD
//        (base reboot recovery; HELLO_REQ is unauthenticated and can only
//        trigger a new handshake)
//   Counters restart at 0 for every new session (packet layer).
//
// Header (18 B, AAD): magic(16) type(8) session_id(24) frame(16) chunk(16)
//   counter(64) in hdr[143:0], magic in [143:128]. HELLO: frame = chunk =
//   counter = 0, session_id = N_rover[63:40].
//
// Ports   : clk, rst        system clock; synchronous active-high reset
//           k, k_valid      long-term key K (rover: from puf_keygen; base:
//                           enrolled key). Never leaves this core except
//                           towards session_kdf.
//           c_*, r_*        master port to session_kdf (connect 1:1)
//           tx_*            HELLO / HELLO_REQ message to the packetizer
//                           (valid/ready). tx_plen = payload bytes (8 rover
//                           HELLO, 16 base reply, 0 HELLO_REQ: no tag)
//           rx_*            received HELLO / HELLO_REQ (from depacketizer);
//                           sampled when rx_valid = 1, ignored if unexpected
//           confirm_pend    pulse: a packet verified under the pending key
//           confirm_cur     pulse: a packet verified under the current key
//           cur_*           established session (valid, K_s, session_id)
//           pend_*          pending session
//           restarts        number of handshakes started (statistics)
//
// Timers  : in clock cycles (defaults for 100 MHz in comments).
// ============================================================================
module hello_fsm #(
    parameter        ROLE         = 0,             // 0 = rover, 1 = base
    parameter [15:0] MAGIC        = 16'h5256,      // "RV"
    parameter [31:0] T_REPLY      = 32'd50000000,  // 0.5 s
    parameter [31:0] T_CONFIRM    = 32'd50000000,  // 0.5 s
    parameter [31:0] T_LINK       = 32'd200000000, // 2 s
    parameter [31:0] T_REQ_HOLD   = 32'd100000000, // 1 s
    parameter [31:0] T_REQ_PERIOD = 32'd50000000   // 0.5 s
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [127:0] k,
    input  wire         k_valid,
    // session_kdf master port
    output reg          c_valid,
    input  wire         c_ready,
    output reg  [1:0]   c_op,
    output reg          c_verify,
    output reg  [127:0] c_key,
    output reg  [95:0]  c_iv,
    output reg  [383:0] c_aad,
    output reg  [5:0]   c_aad_len,
    output reg  [127:0] c_tag,
    output reg  [63:0]  c_nr,
    output reg  [63:0]  c_nb,
    input  wire         r_valid,
    input  wire [127:0] r_data,
    input  wire         r_match,
    // transmit
    output reg          tx_valid,
    input  wire         tx_ready,
    output reg  [143:0] tx_hdr,
    output reg  [4:0]   tx_plen,
    output reg  [63:0]  tx_nr,
    output reg  [63:0]  tx_nb,
    output reg  [127:0] tx_tag,
    // receive
    input  wire         rx_valid,
    input  wire [143:0] rx_hdr,
    input  wire [4:0]   rx_plen,
    input  wire [63:0]  rx_nr,
    input  wire [63:0]  rx_nb,
    input  wire [127:0] rx_tag,
    // confirmation from the packet layer
    input  wire         confirm_pend,
    input  wire         confirm_cur,
    // sessions
    output reg          cur_valid,
    output reg  [127:0] cur_ks,
    output reg  [23:0]  cur_sid,
    output reg          pend_valid,
    output reg  [127:0] pend_ks,
    output reg  [23:0]  pend_sid,
    output reg  [15:0]  restarts
);

    localparam [1:0] OP_NONCE = 2'd0, OP_KDF = 2'd1, OP_GMAC = 2'd2;
    localparam [7:0] T_HELLO = 8'h05, T_HELLO_REQ = 8'h06;
    localparam [7:0] IV_ROVER = 8'h03, IV_BASE = 8'h04;

    localparam [4:0] S_WAITK       = 5'd0,
                     S_CALL        = 5'd1,   // session_kdf request
                     S_WAIT        = 5'd2,   // session_kdf result
                     R_START       = 5'd3,
                     R_GOT_NONCE   = 5'd4,
                     R_GOT_TAG     = 5'd5,
                     R_TX          = 5'd6,
                     R_WAIT_REPLY  = 5'd7,
                     R_GOT_VERIFY  = 5'd8,
                     R_GOT_KDF     = 5'd9,
                     R_PEND        = 5'd10,
                     R_EST         = 5'd11,
                     B_IDLE        = 5'd12,
                     B_GOT_VERIFY  = 5'd13,
                     B_GOT_NONCE   = 5'd14,
                     B_GOT_TAG     = 5'd15,
                     B_GOT_KDF     = 5'd16,
                     B_TX          = 5'd17,
                     B_REQ_TX      = 5'd18;

    localparam [31:0] TMAX = 32'hffffffff;

    reg [4:0]   state, ret;
    reg [127:0] res_q;
    reg         match_q;
    reg [63:0]  nr, nb;
    reg [127:0] tag_q;
    reg [143:0] hdr_q;
    reg [31:0]  tmr, req_tmr, pend_tmr;

    function [143:0] hello_hdr;
        input [7:0]  ptype;
        input [23:0] sid;
        begin
            hello_hdr = {MAGIC, ptype, sid, 16'd0, 16'd0, 64'd0};
        end
    endfunction

    wire        rx_magic_ok = (rx_hdr[143:128] == MAGIC);
    wire [7:0]  rx_type     = rx_hdr[127:120];
    wire [23:0] rx_sid      = rx_hdr[119:96];
    wire        rx_zero     = (rx_hdr[95:0] == 96'd0);       // frame, chunk, counter
    wire        rx_hello    = rx_valid && rx_magic_ok && (rx_type == T_HELLO) && rx_zero;
    wire        rx_req      = rx_valid && rx_magic_ok && (rx_type == T_HELLO_REQ);

    wire [31:0] tmr_inc      = (tmr      == TMAX) ? TMAX : tmr + 32'd1;
    wire [31:0] req_tmr_inc  = (req_tmr  == TMAX) ? TMAX : req_tmr + 32'd1;
    wire [31:0] pend_tmr_inc = (pend_tmr == TMAX) ? TMAX : pend_tmr + 32'd1;

    // start a session_kdf call; the result arrives in state `after`
    task call;
        input [1:0]   op;
        input         verify;
        input [95:0]  iv;
        input [383:0] aad;
        input [5:0]   aad_len;
        input [127:0] tag;
        input [4:0]   after;
        begin
            c_op      <= op;
            c_verify  <= verify;
            c_key     <= k;
            c_iv      <= iv;
            c_aad     <= aad;
            c_aad_len <= aad_len;
            c_tag     <= tag;
            c_nr      <= nr;
            c_nb      <= nb;
            ret       <= after;
            state     <= S_CALL;
        end
    endtask

    task restart_rover;
        begin
            cur_valid  <= 1'b0;
            pend_valid <= 1'b0;
            cur_ks     <= 128'd0;
            pend_ks    <= 128'd0;
            req_tmr    <= 32'd0;
            state      <= R_START;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_WAITK;
            ret        <= S_WAITK;
            res_q      <= 128'd0;
            match_q    <= 1'b0;
            nr         <= 64'd0;
            nb         <= 64'd0;
            tag_q      <= 128'd0;
            hdr_q      <= 144'd0;
            tmr        <= 32'd0;
            req_tmr    <= 32'd0;
            pend_tmr   <= 32'd0;
            c_valid    <= 1'b0;
            c_op       <= OP_NONCE;
            c_verify   <= 1'b0;
            c_key      <= 128'd0;
            c_iv       <= 96'd0;
            c_aad      <= 384'd0;
            c_aad_len  <= 6'd0;
            c_tag      <= 128'd0;
            c_nr       <= 64'd0;
            c_nb       <= 64'd0;
            tx_valid   <= 1'b0;
            tx_hdr     <= 144'd0;
            tx_plen    <= 5'd0;
            tx_nr      <= 64'd0;
            tx_nb      <= 64'd0;
            tx_tag     <= 128'd0;
            cur_valid  <= 1'b0;
            cur_ks     <= 128'd0;
            cur_sid    <= 24'd0;
            pend_valid <= 1'b0;
            pend_ks    <= 128'd0;
            pend_sid   <= 24'd0;
            restarts   <= 16'd0;
        end else begin
            tmr     <= tmr_inc;
            req_tmr <= req_tmr_inc;

            // ---------------- base: background session bookkeeping ----------
            if (ROLE != 0) begin
                pend_tmr <= pend_tmr_inc;
                if (pend_valid && confirm_pend) begin
                    cur_valid  <= 1'b1;
                    cur_ks     <= pend_ks;
                    cur_sid    <= pend_sid;
                    pend_valid <= 1'b0;
                    pend_ks    <= 128'd0;
                end else if (pend_valid && pend_tmr >= T_CONFIRM) begin
                    pend_valid <= 1'b0;
                    pend_ks    <= 128'd0;
                end
            end

            case (state)
                S_WAITK: if (k_valid) begin
                    state <= (ROLE == 0) ? R_START : B_IDLE;
                end

                // ---------------- session_kdf call ----------------
                S_CALL: begin
                    c_valid <= 1'b1;
                    if (c_valid && c_ready) begin
                        c_valid <= 1'b0;
                        state   <= S_WAIT;
                    end
                end

                S_WAIT: if (r_valid) begin
                    res_q   <= r_data;
                    match_q <= r_match;
                    state   <= ret;
                end

                // ======================== ROVER ========================
                R_START: begin
                    restarts <= restarts + 16'd1;
                    call(OP_NONCE, 1'b0, 96'd0, 384'd0, 6'd0, 128'd0, R_GOT_NONCE);
                end

                R_GOT_NONCE: begin
                    nr    <= res_q[127:64];
                    hdr_q <= hello_hdr(T_HELLO, res_q[127:104]);
                    c_op      <= OP_GMAC;
                    c_verify  <= 1'b0;
                    c_key     <= k;
                    c_iv      <= {IV_ROVER, res_q[127:64], 24'd0};
                    c_aad     <= {hello_hdr(T_HELLO, res_q[127:104]), res_q[127:64], 176'd0};
                    c_aad_len <= 6'd26;
                    ret       <= R_GOT_TAG;
                    state     <= S_CALL;
                end

                R_GOT_TAG: begin
                    tx_hdr   <= hdr_q;
                    tx_plen  <= 5'd8;
                    tx_nr    <= nr;
                    tx_nb    <= 64'd0;
                    tx_tag   <= res_q;
                    tx_valid <= 1'b1;
                    state    <= R_TX;
                end

                R_TX: if (tx_ready) begin
                    tx_valid <= 1'b0;
                    tmr      <= 32'd0;
                    state    <= R_WAIT_REPLY;
                end

                R_WAIT_REPLY: begin
                    if (tmr >= T_REPLY) begin
                        state <= R_START;                       // new HELLO, new N_rover
                    end else if (rx_hello && rx_plen == 5'd16 && rx_nr == nr && rx_sid == nr[63:40]) begin
                        nb    <= rx_nb;
                        c_op      <= OP_GMAC;
                        c_verify  <= 1'b1;
                        c_key     <= k;
                        c_iv      <= {IV_BASE, rx_nb, 24'd0};
                        c_aad     <= {rx_hdr, rx_nr, rx_nb, 112'd0};
                        c_aad_len <= 6'd34;
                        c_tag     <= rx_tag;
                        ret       <= R_GOT_VERIFY;
                        state     <= S_CALL;
                    end
                end

                R_GOT_VERIFY: begin
                    if (match_q) begin
                        call(OP_KDF, 1'b0, 96'd0, 384'd0, 6'd0, 128'd0, R_GOT_KDF);
                    end else begin
                        state <= R_WAIT_REPLY;                  // forged: drop, keep waiting
                    end
                end

                R_GOT_KDF: begin
                    pend_ks    <= res_q;
                    pend_sid   <= nr[63:40];
                    pend_valid <= 1'b1;
                    tmr        <= 32'd0;
                    state      <= R_PEND;
                end

                R_PEND: begin
                    if (confirm_pend) begin
                        cur_valid  <= 1'b1;
                        cur_ks     <= pend_ks;
                        cur_sid    <= pend_sid;
                        pend_valid <= 1'b0;
                        pend_ks    <= 128'd0;
                        tmr        <= 32'd0;
                        state      <= R_EST;
                    end else if (tmr >= T_CONFIRM) begin
                        restart_rover;
                    end else if (rx_req && req_tmr >= T_REQ_HOLD) begin
                        restart_rover;
                    end
                end

                R_EST: begin
                    if (confirm_cur) begin
                        tmr <= 32'd0;
                    end else if (tmr >= T_LINK) begin
                        restart_rover;
                    end else if (rx_req && req_tmr >= T_REQ_HOLD) begin
                        restart_rover;
                    end
                end

                // ======================== BASE ========================
                B_IDLE: begin
                    if (rx_hello && rx_plen == 5'd8 && rx_sid == rx_nr[63:40]) begin
                        nr    <= rx_nr;
                        c_op      <= OP_GMAC;
                        c_verify  <= 1'b1;
                        c_key     <= k;
                        c_iv      <= {IV_ROVER, rx_nr, 24'd0};
                        c_aad     <= {rx_hdr, rx_nr, 176'd0};
                        c_aad_len <= 6'd26;
                        c_tag     <= rx_tag;
                        ret       <= B_GOT_VERIFY;
                        state     <= S_CALL;
                    end else if (!cur_valid && !pend_valid && req_tmr >= T_REQ_PERIOD) begin
                        tx_hdr   <= hello_hdr(T_HELLO_REQ, 24'd0);
                        tx_plen  <= 5'd0;
                        tx_nr    <= 64'd0;
                        tx_nb    <= 64'd0;
                        tx_tag   <= 128'd0;
                        tx_valid <= 1'b1;
                        state    <= B_REQ_TX;
                    end
                end

                B_GOT_VERIFY: begin
                    if (match_q) begin
                        restarts <= restarts + 16'd1;
                        call(OP_NONCE, 1'b0, 96'd0, 384'd0, 6'd0, 128'd0, B_GOT_NONCE);
                    end else begin
                        state <= B_IDLE;                        // forged: drop
                    end
                end

                B_GOT_NONCE: begin
                    nb    <= res_q[127:64];
                    hdr_q <= hello_hdr(T_HELLO, nr[63:40]);
                    c_op      <= OP_GMAC;
                    c_verify  <= 1'b0;
                    c_key     <= k;
                    c_iv      <= {IV_BASE, res_q[127:64], 24'd0};
                    c_aad     <= {hello_hdr(T_HELLO, nr[63:40]), nr, res_q[127:64], 112'd0};
                    c_aad_len <= 6'd34;
                    ret       <= B_GOT_TAG;
                    state     <= S_CALL;
                end

                B_GOT_TAG: begin
                    tag_q <= res_q;
                    call(OP_KDF, 1'b0, 96'd0, 384'd0, 6'd0, 128'd0, B_GOT_KDF);
                end

                B_GOT_KDF: begin
                    pend_ks    <= res_q;
                    pend_sid   <= nr[63:40];
                    pend_valid <= 1'b1;
                    pend_tmr   <= 32'd0;
                    tx_hdr     <= hdr_q;
                    tx_plen    <= 5'd16;
                    tx_nr      <= nr;
                    tx_nb      <= nb;
                    tx_tag     <= tag_q;
                    tx_valid   <= 1'b1;
                    state      <= B_TX;
                end

                B_TX, B_REQ_TX: if (tx_ready) begin
                    tx_valid <= 1'b0;
                    if (state == B_REQ_TX) req_tmr <= 32'd0;
                    state    <= B_IDLE;
                end

                default: state <= S_WAITK;
            endcase
        end
    end

endmodule
`default_nettype wire
