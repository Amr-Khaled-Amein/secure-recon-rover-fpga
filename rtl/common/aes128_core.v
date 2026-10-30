`default_nettype none
// ============================================================================
// aes128_core
// ----------------------------------------------------------------------------
// Purpose : AES-128 block encryption (FIPS-197), encrypt only.
//           Iterative: one full round per clock. Round keys are expanded on
//           the fly (no key RAM), so every block starts from the cipher key.
//           Encrypt-only is enough for GCM (decrypt also uses the forward
//           cipher), for the session KDF and for the Davies-Meyer PUF hash.
//           Uses 20 aes_sbox instances (16 for SubBytes, 4 for the key step).
//
// Ports   : clk       system clock (100 MHz target)
//           rst       synchronous, active-high reset
//           start     1-cycle request; accepted only while ready = 1
//           key       128-bit cipher key   (sampled when start is accepted)
//           block_in  128-bit plaintext    (sampled when start is accepted)
//           ready     1 = idle, a start will be accepted
//           done      1-cycle pulse: block_out is valid
//           block_out 128-bit ciphertext, held from done until the next
//                     accepted start
//
// Byte order: bits [127:120] are byte 0 (the first byte of the FIPS-197
//             hex strings), so test vectors can be used as written.
//
// Latency : start accepted at clock edge N -> done is high after edge N+10.
//           A new start can be accepted at edge N+11, so one block every
//           11 cycles (~1.16 Gbit/s at 100 MHz).
//           key and block_in may change freely after start is accepted.
// ============================================================================
module aes128_core (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [127:0] key,
    input  wire [127:0] block_in,
    output wire         ready,
    output reg          done,
    output wire [127:0] block_out
);

    localparam [3:0] LAST_ROUND = 4'd10;

    // multiply by 2 in GF(2^8), modulo x^8 + x^4 + x^3 + x + 1
    function [7:0] xtime;
        input [7:0] a;
        begin
            xtime = {a[6:0], 1'b0} ^ (a[7] ? 8'h1b : 8'h00);
        end
    endfunction

    // ------------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------------
    reg [127:0] state;      // cipher state
    reg [127:0] rk;         // round key of the previous round
    reg [7:0]   rcon;       // round constant for the next key step
    reg [3:0]   round;      // round being computed (1..10)
    reg         busy;

    assign ready     = ~busy;
    assign block_out = state;

    // ------------------------------------------------------------------------
    // Key expansion (one step per round)
    // ------------------------------------------------------------------------
    wire [31:0] w0 = rk[127:96];
    wire [31:0] w1 = rk[95:64];
    wire [31:0] w2 = rk[63:32];
    wire [31:0] w3 = rk[31:0];

    // SubWord(RotWord(w3)): RotWord turns bytes [a0 a1 a2 a3] into [a1 a2 a3 a0]
    wire [31:0] rot_w3 = {w3[23:0], w3[31:24]};
    wire [31:0] sub_w3;

    genvar i, c, r;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_key_sbox
            aes_sbox u_sbox (.x(rot_w3[31-8*i -: 8]), .y(sub_w3[31-8*i -: 8]));
        end
    endgenerate

    wire [31:0]  key_t   = sub_w3 ^ {rcon, 24'd0};
    wire [31:0]  n0      = w0 ^ key_t;
    wire [31:0]  n1      = w1 ^ n0;
    wire [31:0]  n2      = w2 ^ n1;
    wire [31:0]  n3      = w3 ^ n2;
    wire [127:0] rk_next = {n0, n1, n2, n3};

    // ------------------------------------------------------------------------
    // Round function: SubBytes -> ShiftRows -> MixColumns (skipped in round 10)
    // Byte i of the state = row (i % 4), column (i / 4).
    // ------------------------------------------------------------------------
    wire [127:0] sb;        // after SubBytes
    wire [127:0] sr;        // after ShiftRows
    wire [127:0] mc;        // after MixColumns

    generate
        for (i = 0; i < 16; i = i + 1) begin : g_sub
            aes_sbox u_sbox (.x(state[127-8*i -: 8]), .y(sb[127-8*i -: 8]));
        end

        // row r of column c comes from column (c + r) % 4
        for (c = 0; c < 4; c = c + 1) begin : g_shift_col
            for (r = 0; r < 4; r = r + 1) begin : g_shift_row
                assign sr[127-8*(4*c+r) -: 8] = sb[127-8*(4*((c+r)%4)+r) -: 8];
            end
        end

        for (c = 0; c < 4; c = c + 1) begin : g_mix
            wire [7:0] a0 = sr[127-32*c    -: 8];
            wire [7:0] a1 = sr[127-32*c-8  -: 8];
            wire [7:0] a2 = sr[127-32*c-16 -: 8];
            wire [7:0] a3 = sr[127-32*c-24 -: 8];
            assign mc[127-32*c    -: 8] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3;
            assign mc[127-32*c-8  -: 8] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3;
            assign mc[127-32*c-16 -: 8] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3);
            assign mc[127-32*c-24 -: 8] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);
        end
    endgenerate

    wire [127:0] round_out = ((round == LAST_ROUND) ? sr : mc) ^ rk_next;

    // ------------------------------------------------------------------------
    // Control
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state <= 128'd0;
            rk    <= 128'd0;
            rcon  <= 8'h00;
            round <= 4'd0;
            busy  <= 1'b0;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                state <= block_in ^ key;    // round 0: AddRoundKey
                rk    <= key;
                rcon  <= 8'h01;
                round <= 4'd1;
                busy  <= 1'b1;
            end else if (busy) begin
                state <= round_out;
                rk    <= rk_next;
                rcon  <= xtime(rcon);
                if (round == LAST_ROUND) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    round <= round + 4'd1;
                end
            end
        end
    end

endmodule
`default_nettype wire
