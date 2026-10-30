`default_nettype none
// ============================================================================
// fuzzy_extractor
// ----------------------------------------------------------------------------
// Purpose : code-offset secure sketch with a repetition code of length R
//           (project brief §5.3, Phase 0 code; the final design adds BCH).
//           Debiased bits are taken in blocks x = (x0 .. x(R-1)).
//           Enrollment  : helper w_i = x_i xor x_0 for i = 1..R-1 (this is
//                         x xor C(x0), the syndrome form of the code offset;
//                         w_0 = 0 is not stored). Output x.
//           Reconstruct : with noisy x': y_i = x'_i xor w_i, s = majority(y),
//                         corrected x_i = s xor w_i. Up to (R-1)/2 errors per
//                         block are corrected.
//           Output: NB*R corrected bits, then done. Further input is refused
//           until reset.
//
// Ports   : clk, rst      system clock; synchronous active-high reset
//           in_*          debiased bits in (valid/ready)
//           off_in_*      (ENROLL = 0) helper offset bits in, R-1 per block
//           off_out_*     (ENROLL = 1) helper offset bits out, R-1 per block
//           out_*         corrected bits out (valid/ready), R per block
//           done          1-cycle pulse after the last output bit
//           finished      1 after done, until reset
//           nerr          number of bits corrected so far (statistics)
//
// ENROLL  : 1 only in the separate enrollment bitstream.
// Latency : ~2R+3 cycles per block when inputs are ready.
// ============================================================================
module fuzzy_extractor #(
    parameter R      = 5,        // repetition length, odd, 3..15
    parameter NB     = 136,      // number of blocks
    parameter ENROLL = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire        in_bit,
    input  wire        off_in_valid,
    output wire        off_in_ready,
    input  wire        off_in_bit,
    output reg         off_out_valid,
    input  wire        off_out_ready,
    output reg         off_out_bit,
    output reg         out_valid,
    input  wire        out_ready,
    output reg         out_bit,
    output reg         done,
    output reg         finished,
    output reg  [15:0] nerr
);

    localparam [2:0] S_IN   = 3'd0,   // collect R input bits
                     S_OFF  = 3'd1,   // R-1 helper bits in or out
                     S_DEC  = 3'd2,   // majority decode (reconstruct)
                     S_EMIT = 3'd3,   // R corrected bits out
                     S_FIN  = 3'd4;

    localparam [3:0]  LAST_BIT  = R - 1;
    localparam [3:0]  HALF      = R / 2;
    localparam [15:0] LAST_BLK  = NB - 1;

    reg [2:0]   state;
    reg [3:0]   idx;
    reg [15:0]  blk;
    reg [R-1:0] x;        // bit i = x_i
    reg [R-1:0] w;        // bit 0 always 0
    reg [R-1:0] corr;

    assign in_ready     = (state == S_IN);
    assign off_in_ready = (ENROLL == 0) && (state == S_OFF);

    // majority decode
    reg [R-1:0] y;
    reg [3:0]   ones;
    reg         s;
    reg [R-1:0] dec;
    reg [3:0]   flips;
    integer     k;
    always @(*) begin
        y     = x ^ w;
        ones  = 4'd0;
        for (k = 0; k < R; k = k + 1) ones = ones + {3'd0, y[k]};
        s     = (ones > HALF);
        dec   = w ^ {R{s}};
        flips = 4'd0;
        for (k = 0; k < R; k = k + 1) flips = flips + {3'd0, dec[k] ^ x[k]};
    end

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state         <= S_IN;
            idx           <= 4'd0;
            blk           <= 16'd0;
            x             <= {R{1'b0}};
            w             <= {R{1'b0}};
            corr          <= {R{1'b0}};
            off_out_valid <= 1'b0;
            off_out_bit   <= 1'b0;
            out_valid     <= 1'b0;
            out_bit       <= 1'b0;
            finished      <= 1'b0;
            nerr          <= 16'd0;
        end else begin
            case (state)
                S_IN: if (in_valid) begin
                    x[idx] <= in_bit;
                    if (idx == LAST_BIT) begin
                        idx   <= 4'd1;
                        w     <= {R{1'b0}};
                        state <= S_OFF;
                        if (ENROLL != 0) begin
                            off_out_valid <= 1'b1;
                            off_out_bit   <= x[1] ^ x[0];          // w_1
                        end
                    end else begin
                        idx <= idx + 4'd1;
                    end
                end

                S_OFF: begin
                    if (ENROLL != 0) begin
                        if (off_out_ready) begin
                            if (idx == LAST_BIT) begin
                                off_out_valid <= 1'b0;
                                corr          <= x;
                                idx           <= 4'd0;
                                out_valid     <= 1'b1;
                                out_bit       <= x[0];
                                state         <= S_EMIT;
                            end else begin
                                off_out_bit <= x[idx + 4'd1] ^ x[0];
                                idx         <= idx + 4'd1;
                            end
                        end
                    end else if (off_in_valid) begin
                        w[idx] <= off_in_bit;
                        if (idx == LAST_BIT) state <= S_DEC;
                        else                 idx   <= idx + 4'd1;
                    end
                end

                S_DEC: begin
                    corr      <= dec;
                    nerr      <= nerr + {12'd0, flips};
                    idx       <= 4'd0;
                    out_valid <= 1'b1;
                    out_bit   <= dec[0];
                    state     <= S_EMIT;
                end

                S_EMIT: if (out_ready) begin
                    if (idx == LAST_BIT) begin
                        out_valid <= 1'b0;
                        idx       <= 4'd0;
                        if (blk == LAST_BLK) begin
                            done     <= 1'b1;
                            finished <= 1'b1;
                            state    <= S_FIN;
                        end else begin
                            blk   <= blk + 16'd1;
                            state <= S_IN;
                        end
                    end else begin
                        out_bit <= corr[idx + 4'd1];
                        idx     <= idx + 4'd1;
                    end
                end

                S_FIN: ;   // stay until reset

                default: state <= S_IN;
            endcase
        end
    end

endmodule
`default_nettype wire
