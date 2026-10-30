`default_nettype none
// ============================================================================
// aes_gcm
// ----------------------------------------------------------------------------
// Purpose : AES-128-GCM authenticated encryption / decryption (SP 800-38D)
//           with a 96-bit IV and a 128-bit tag. One aes128_core (CTR
//           keystream, H and E_K(J0)) and one bit-serial ghash.
//           Empty plaintext gives GMAC (used for the HELLO messages).
//           ecb = 1 computes one plain AES block E_key(in_data) instead and
//           returns it on `tag` (session KDF and TRNG conditioning share
//           this AES core; see session_kdf).
//
// Ports   : clk, rst   system clock; synchronous active-high reset
//           start      1-cycle request; accepted only while ready = 1.
//                      decrypt, key, iv, aad_len, txt_len are sampled then.
//           decrypt    0 = encrypt (in = plaintext,  out = ciphertext)
//                      1 = decrypt (in = ciphertext, out = plaintext)
//           ecb        1 = single AES block: one in_* block, result on tag
//                      (iv, aad_len, txt_len, decrypt ignored; no out_*)
//           key        128-bit key
//           iv         96-bit IV
//           aad_len    AAD length in bytes
//           txt_len    plaintext / ciphertext length in bytes
//           ready      1 = idle
//           in_*       input blocks, valid/ready handshake: first
//                      ceil(aad_len/16) AAD blocks, then ceil(txt_len/16)
//                      text blocks. Byte 0 of a block is in_data[127:120].
//                      Bytes past the end of the last block are ignored.
//           out_*      output text blocks, valid/ready handshake, one per
//                      input text block; bytes past the end are zero.
//           done       1-cycle pulse: tag is valid
//           tag        computed 128-bit tag, held until the next start
//           tag_in     expected tag (receiver); compared with tag
//           tag_match  1 when tag == tag_in. Only meaningful after done.
//
// NOTE    : in decrypt mode out_data is UNVERIFIED plaintext. The caller
//           must hold it in a buffer and release it only if tag_match = 1
//           after done (project brief §5.1).
//
// Latency : ~24 cycles setup (H and E_K(J0)), then 129 cycles per AAD block
//           and ~143 cycles per text block, 129 cycles for the length block.
//           A 674-byte packet (18 B AAD + 640 B text) takes ~6.1k cycles,
//           ~61 us at 100 MHz (~88 Mbit/s). ECB: 12 cycles after in_data.
// ============================================================================
module aes_gcm #(
    parameter LEN_W = 16                  // width of the byte-length fields
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             start,
    input  wire             decrypt,
    input  wire             ecb,
    input  wire [127:0]     key,
    input  wire [95:0]      iv,
    input  wire [LEN_W-1:0] aad_len,
    input  wire [LEN_W-1:0] txt_len,
    output wire             ready,
    input  wire             in_valid,
    output wire             in_ready,
    input  wire [127:0]     in_data,
    output reg              out_valid,
    input  wire             out_ready,
    output reg  [127:0]     out_data,
    output reg              done,
    output reg  [127:0]     tag,
    input  wire [127:0]     tag_in,
    output wire             tag_match
);

    localparam [3:0] S_IDLE    = 4'd0,
                     S_H       = 4'd1,   // E_K(0^128) running
                     S_J0      = 4'd2,   // E_K(J0) running
                     S_AAD     = 4'd3,   // waiting for an AAD block
                     S_AAD_GH  = 4'd4,   // GHASH of an AAD block
                     S_TXT     = 4'd5,   // waiting for a text block
                     S_TXT_AES = 4'd6,   // keystream block running
                     S_TXT_GH  = 4'd7,   // GHASH of a ciphertext block
                     S_TXT_OUT = 4'd8,   // waiting for out_ready
                     S_LEN     = 4'd9,   // start GHASH of the length block
                     S_LEN_GH  = 4'd10,  // GHASH of the length block
                     S_ECB_IN  = 4'd11,  // ECB: waiting for the block
                     S_ECB     = 4'd12;  // ECB: AES running

    localparam [LEN_W-1:0] SIXTEEN = 16;

    // bytes 0..nb-1 of a block kept, the rest zero (nb = min(rem, 16))
    function [127:0] byte_mask;
        input [LEN_W-1:0] rem;
        reg   [4:0]       nb;
        begin
            nb        = (rem >= SIXTEEN) ? 5'd16 : rem[4:0];
            byte_mask = ~({128{1'b1}} >> {nb, 3'b000});
        end
    endfunction

    function [LEN_W-1:0] sub16;
        input [LEN_W-1:0] rem;
        begin
            sub16 = (rem > SIXTEEN) ? (rem - SIXTEEN) : {LEN_W{1'b0}};
        end
    endfunction

    reg [3:0]       state;
    reg             dec_r;
    reg [127:0]     key_r;
    reg [95:0]      iv_r;
    reg [LEN_W-1:0] aad_len_r, txt_len_r;
    reg [LEN_W-1:0] rem_aad, rem_txt;
    reg [31:0]      ctr;
    reg [127:0]     h_r;
    reg [127:0]     ej0_r;
    reg [127:0]     din_r;      // masked input text block
    reg [127:0]     mask_r;     // byte mask of that block

    // AES core
    reg          aes_go;
    reg  [127:0] aes_in;
    wire         aes_done;
    wire [127:0] aes_out;
    wire         aes_ready_unused;

    aes128_core u_aes (
        .clk(clk), .rst(rst), .start(aes_go), .key(key_r), .block_in(aes_in),
        .ready(aes_ready_unused), .done(aes_done), .block_out(aes_out)
    );

    // GHASH
    reg          gh_go, gh_clr;
    reg  [127:0] gh_x;
    wire         gh_done;
    wire [127:0] gh_y;
    wire         gh_ready_unused;

    ghash u_ghash (
        .clk(clk), .rst(rst), .clear(gh_clr), .start(gh_go), .x(gh_x), .h(h_r),
        .ready(gh_ready_unused), .done(gh_done), .y(gh_y)
    );

    assign ready     = (state == S_IDLE);
    assign in_ready  = (state == S_AAD) || (state == S_TXT) || (state == S_ECB_IN);
    assign tag_match = (tag == tag_in);

    wire [127:0] txt_xor = (din_r ^ aes_out) & mask_r;

    // length block: len(A) || len(C) in bits, 64 bits each
    wire [127:0] len_block = {{(61-LEN_W){1'b0}}, aad_len_r, 3'b000,
                              {(61-LEN_W){1'b0}}, txt_len_r, 3'b000};

    always @(posedge clk) begin
        aes_go <= 1'b0;
        gh_go  <= 1'b0;
        gh_clr <= 1'b0;
        done   <= 1'b0;
        if (rst) begin
            state     <= S_IDLE;
            out_valid <= 1'b0;
            out_data  <= 128'd0;
            tag       <= 128'd0;
            dec_r     <= 1'b0;
            key_r     <= 128'd0;
            iv_r      <= 96'd0;
            aad_len_r <= {LEN_W{1'b0}};
            txt_len_r <= {LEN_W{1'b0}};
            rem_aad   <= {LEN_W{1'b0}};
            rem_txt   <= {LEN_W{1'b0}};
            ctr       <= 32'd0;
            h_r       <= 128'd0;
            ej0_r     <= 128'd0;
            din_r     <= 128'd0;
            mask_r    <= 128'd0;
            aes_in    <= 128'd0;
            gh_x      <= 128'd0;
        end else begin
            if (out_valid && out_ready)
                out_valid <= 1'b0;

            case (state)
                S_IDLE: if (start) begin
                    dec_r     <= decrypt;
                    key_r     <= key;
                    iv_r      <= iv;
                    aad_len_r <= aad_len;
                    txt_len_r <= txt_len;
                    rem_aad   <= aad_len;
                    rem_txt   <= txt_len;
                    aes_in    <= 128'd0;             // H = E_K(0)
                    if (ecb) begin
                        state  <= S_ECB_IN;
                    end else begin
                        aes_go <= 1'b1;
                        state  <= S_H;
                    end
                end

                S_ECB_IN: if (in_valid) begin
                    aes_in <= in_data;
                    aes_go <= 1'b1;
                    state  <= S_ECB;
                end

                S_ECB: if (aes_done) begin
                    tag   <= aes_out;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                S_H: if (aes_done) begin
                    h_r    <= aes_out;
                    aes_in <= {iv_r, 32'd1};         // J0
                    aes_go <= 1'b1;
                    state  <= S_J0;
                end

                S_J0: if (aes_done) begin
                    ej0_r  <= aes_out;
                    gh_clr <= 1'b1;
                    ctr    <= 32'd2;                 // inc32(J0)
                    if (rem_aad != {LEN_W{1'b0}})      state <= S_AAD;
                    else if (rem_txt != {LEN_W{1'b0}}) state <= S_TXT;
                    else                               state <= S_LEN;
                end

                S_AAD: if (in_valid) begin
                    gh_x    <= in_data & byte_mask(rem_aad);
                    gh_go   <= 1'b1;
                    rem_aad <= sub16(rem_aad);
                    state   <= S_AAD_GH;
                end

                S_AAD_GH: if (gh_done) begin
                    if (rem_aad != {LEN_W{1'b0}})      state <= S_AAD;
                    else if (rem_txt != {LEN_W{1'b0}}) state <= S_TXT;
                    else                               state <= S_LEN;
                end

                S_TXT: if (in_valid) begin
                    din_r   <= in_data & byte_mask(rem_txt);
                    mask_r  <= byte_mask(rem_txt);
                    aes_in  <= {iv_r, ctr};
                    aes_go  <= 1'b1;
                    ctr     <= ctr + 32'd1;
                    rem_txt <= sub16(rem_txt);
                    state   <= S_TXT_AES;
                end

                S_TXT_AES: if (aes_done) begin
                    out_data  <= txt_xor;
                    out_valid <= 1'b1;
                    gh_x      <= dec_r ? din_r : txt_xor;   // GHASH the ciphertext
                    gh_go     <= 1'b1;
                    state     <= S_TXT_GH;
                end

                S_TXT_GH: if (gh_done) begin
                    state <= S_TXT_OUT;
                end

                S_TXT_OUT: if (!out_valid || out_ready) begin
                    if (rem_txt != {LEN_W{1'b0}}) state <= S_TXT;
                    else                          state <= S_LEN;
                end

                S_LEN: begin
                    gh_x  <= len_block;
                    gh_go <= 1'b1;
                    state <= S_LEN_GH;
                end

                S_LEN_GH: if (gh_done) begin
                    tag   <= gh_y ^ ej0_r;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
