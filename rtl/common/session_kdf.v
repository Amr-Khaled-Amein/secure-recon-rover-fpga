`default_nettype none
// ============================================================================
// session_kdf
// ----------------------------------------------------------------------------
// Purpose : crypto services for the session setup (project brief §5.2), all on
//           the shared aes_gcm engine (one AES core per board):
//             OP_NONCE : conditioned random nonce. Takes COND_BLOCKS x 128
//                        health-tested TRNG bits R_i and computes the AES
//                        CBC-MAC X_i = AES_CK(X_{i-1} xor R_i), X_0 = 0, with
//                        the fixed public key COND_KEY (an SP 800-90B vetted
//                        conditioning function). Result X; the nonce is the
//                        upper 64 bits.
//             OP_KDF   : K_s = AES_K(N_rover || N_base)
//             OP_GMAC  : GMAC tag under key/iv over up to 48 bytes of AAD
//                        (empty plaintext). verify = 1 also compares with
//                        cmd_tag (res_match) and runs the engine in decrypt
//                        mode, so the simulation IV-reuse monitor only counts
//                        tags we generate.
//
// Ports   : clk, rst   system clock; synchronous active-high reset
//           cmd_*      request (valid/ready); arguments sampled on accept
//             cmd_op      0 = NONCE, 1 = KDF, 2 = GMAC
//             cmd_verify  GMAC: 1 = check cmd_tag
//             cmd_key     K (KDF, GMAC)
//             cmd_iv      GMAC IV
//             cmd_aad     GMAC AAD, byte 0 in [383:376]; cmd_aad_len bytes
//             cmd_tag     GMAC expected tag (verify)
//             cmd_nr, cmd_nb  KDF nonces
//           res_valid  1-cycle pulse: res_data (and res_match) valid
//           rnd_*      health-tested random bits (valid/ready), only drawn
//                      during OP_NONCE
//           g_*        master port to aes_gcm (connect 1:1)
//
// Latency : NONCE 128*COND_BLOCKS bits + ~14 cycles per block;
//           KDF ~15 cycles; GMAC ~24 + 129 per AAD block + 129 cycles.
// ============================================================================
module session_kdf #(
    parameter [127:0] COND_KEY    = 128'h726f7665722d74726e672d636f6e6430, // "rover-trng-cond0"
    parameter         COND_BLOCKS = 4
) (
    input  wire         clk,
    input  wire         rst,
    // command
    input  wire         cmd_valid,
    output wire         cmd_ready,
    input  wire [1:0]   cmd_op,
    input  wire         cmd_verify,
    input  wire [127:0] cmd_key,
    input  wire [95:0]  cmd_iv,
    input  wire [383:0] cmd_aad,
    input  wire [5:0]   cmd_aad_len,
    input  wire [127:0] cmd_tag,
    input  wire [63:0]  cmd_nr,
    input  wire [63:0]  cmd_nb,
    // result
    output reg          res_valid,
    output reg  [127:0] res_data,
    output reg          res_match,
    // TRNG
    input  wire         rnd_valid,
    output wire         rnd_ready,
    input  wire         rnd_bit,
    // aes_gcm master port
    output wire         g_start,
    output wire         g_decrypt,
    output wire         g_ecb,
    output wire [127:0] g_key,
    output wire [95:0]  g_iv,
    output wire [15:0]  g_aad_len,
    output wire [15:0]  g_txt_len,
    input  wire         g_ready,
    output wire         g_in_valid,
    input  wire         g_in_ready,
    output wire [127:0] g_in_data,
    input  wire         g_out_valid,
    output wire         g_out_ready,
    input  wire         g_done,
    input  wire [127:0] g_tag,
    output wire [127:0] g_tag_in,
    input  wire         g_tag_match
);

    localparam [1:0] OP_NONCE = 2'd0,
                     OP_KDF   = 2'd1,
                     OP_GMAC  = 2'd2;

    localparam [2:0] S_IDLE = 3'd0,
                     S_RND  = 3'd1,    // collecting 128 random bits
                     S_GS   = 3'd2,    // starting the engine
                     S_GF   = 3'd3,    // feeding blocks
                     S_GW   = 3'd4;    // waiting for done

    localparam [7:0] LAST_BLK = COND_BLOCKS - 1;

    reg [2:0]   state;
    reg [1:0]   op;
    reg         verify;
    reg [127:0] key_r;
    reg [95:0]  iv_r;
    reg [5:0]   aad_len_r;
    reg [127:0] tag_r;
    reg [383:0] feed;          // blocks to feed, first block in [383:256]
    reg [1:0]   nfeed;         // blocks left to feed
    reg [127:0] rnd;           // random bits being collected
    reg [6:0]   rpos;
    reg [127:0] x;             // CBC-MAC chaining value
    reg [7:0]   blk;

    assign cmd_ready   = (state == S_IDLE);
    assign rnd_ready   = (state == S_RND);

    assign g_start     = (state == S_GS);
    assign g_ecb       = (op != OP_GMAC);
    assign g_decrypt   = verify;
    assign g_key       = (op == OP_NONCE) ? COND_KEY : key_r;
    assign g_iv        = iv_r;
    assign g_aad_len   = {10'd0, aad_len_r};
    assign g_txt_len   = 16'd0;
    assign g_in_valid  = (state == S_GF);
    assign g_in_data   = feed[383:256];
    assign g_out_ready = 1'b1;
    assign g_tag_in    = tag_r;

    // number of 16-byte AAD blocks (1..3)
    wire [1:0] aad_blocks = (cmd_aad_len > 6'd32) ? 2'd3 :
                            (cmd_aad_len > 6'd16) ? 2'd2 : 2'd1;

    always @(posedge clk) begin
        res_valid <= 1'b0;
        if (rst) begin
            state     <= S_IDLE;
            op        <= OP_NONCE;
            verify    <= 1'b0;
            key_r     <= 128'd0;
            iv_r      <= 96'd0;
            aad_len_r <= 6'd0;
            tag_r     <= 128'd0;
            feed      <= 384'd0;
            nfeed     <= 2'd0;
            rnd       <= 128'd0;
            rpos      <= 7'd0;
            x         <= 128'd0;
            blk       <= 8'd0;
            res_data  <= 128'd0;
            res_match <= 1'b0;
        end else begin
            case (state)
                S_IDLE: if (cmd_valid) begin
                    op        <= cmd_op;
                    verify    <= (cmd_op == OP_GMAC) && cmd_verify;
                    key_r     <= cmd_key;
                    iv_r      <= cmd_iv;
                    aad_len_r <= cmd_aad_len;
                    tag_r     <= cmd_tag;
                    case (cmd_op)
                        OP_KDF: begin
                            feed  <= {cmd_nr, cmd_nb, 256'd0};
                            nfeed <= 2'd1;
                            state <= S_GS;
                        end
                        OP_GMAC: begin
                            feed  <= cmd_aad;
                            nfeed <= aad_blocks;
                            state <= S_GS;
                        end
                        default: begin                   // OP_NONCE
                            x     <= 128'd0;
                            blk   <= 8'd0;
                            rpos  <= 7'd0;
                            state <= S_RND;
                        end
                    endcase
                end

                S_RND: if (rnd_valid) begin
                    rnd[7'd127 - rpos] <= rnd_bit;
                    rpos <= rpos + 7'd1;
                    if (rpos == 7'd127) begin
                        feed  <= {x ^ {rnd[127:1], rnd_bit}, 256'd0};
                        nfeed <= 2'd1;
                        state <= S_GS;
                    end
                end

                S_GS: if (g_ready) state <= S_GF;

                S_GF: if (g_in_ready) begin
                    feed  <= {feed[255:0], 128'd0};
                    nfeed <= nfeed - 2'd1;
                    if (nfeed == 2'd1) state <= S_GW;
                end

                S_GW: if (g_done) begin
                    if (op == OP_NONCE && blk != LAST_BLK) begin
                        x     <= g_tag;
                        blk   <= blk + 8'd1;
                        rpos  <= 7'd0;
                        state <= S_RND;
                    end else begin
                        res_data  <= g_tag;
                        res_match <= g_tag_match;
                        res_valid <= 1'b1;
                        rnd       <= 128'd0;       // don't keep random bits around
                        x         <= 128'd0;
                        state     <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
