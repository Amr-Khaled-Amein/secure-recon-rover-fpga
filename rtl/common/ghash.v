`default_nettype none
// ============================================================================
// ghash
// ----------------------------------------------------------------------------
// Purpose : GHASH accumulator for AES-GCM (NIST SP 800-38D, Algorithm 1/2).
//           One step computes  Y <= (Y xor X) * H  in GF(2^128), bit-serial:
//           one bit of (Y xor X) per clock, 128 clocks per block.
//
// Ports   : clk    system clock
//           rst    synchronous, active-high reset (also clears Y)
//           clear  1-cycle pulse: Y <= 0 (start of a new message).
//                  Ignored while busy; do not assert together with start.
//           start  1-cycle request; accepted only while ready = 1
//           x      128-bit input block      (sampled when start is accepted)
//           h      128-bit hash subkey H    (sampled when start is accepted)
//           ready  1 = idle
//           done   1-cycle pulse: y holds the new value
//           y      128-bit accumulator Y, held between steps
//
// Bit order: bit 127 = bit 0 of the GCM bit string (MSB of the first byte),
//            so byte strings from the standard can be used as written.
//
// Latency : start accepted at edge N -> done and the new y after edge N+128.
//           A new start can be accepted in the cycle where done = 1.
// ============================================================================
module ghash (
    input  wire         clk,
    input  wire         rst,
    input  wire         clear,
    input  wire         start,
    input  wire [127:0] x,
    input  wire [127:0] h,
    output wire         ready,
    output reg          done,
    output reg  [127:0] y
);

    // reduction constant R = 11100001 || 0^120
    localparam [127:0] R = {8'he1, 120'd0};

    reg [127:0] a;      // remaining bits of (Y xor X), MSB first
    reg [127:0] v;      // H * x^i
    reg [127:0] z;      // partial product
    reg [6:0]   cnt;
    reg         busy;

    assign ready = ~busy;

    wire [127:0] z_next = a[127] ? (z ^ v) : z;
    wire [127:0] v_next = v[0] ? ((v >> 1) ^ R) : (v >> 1);

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            cnt  <= 7'd0;
            a    <= 128'd0;
            v    <= 128'd0;
            z    <= 128'd0;
            y    <= 128'd0;
        end else if (busy) begin
            a   <= {a[126:0], 1'b0};
            v   <= v_next;
            z   <= z_next;
            cnt <= cnt + 7'd1;
            if (cnt == 7'd127) begin
                busy <= 1'b0;
                done <= 1'b1;
                y    <= z_next;
            end
        end else if (start) begin
            busy <= 1'b1;
            cnt  <= 7'd0;
            a    <= y ^ x;
            v    <= h;
            z    <= 128'd0;
        end else if (clear) begin
            y    <= 128'd0;
        end
    end

endmodule
`default_nettype wire
