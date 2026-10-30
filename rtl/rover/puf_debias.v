`default_nettype none
// ============================================================================
// puf_debias
// ----------------------------------------------------------------------------
// Purpose : index-based Von Neumann debiasing of PUF response bits
//           (Maes et al., CHES 2015), before the code offset (project brief §5.3,
//           "repetition code pitfall").
//           Raw bits are taken in pairs (r0, r1).
//           Enrollment  : keep r0 if r0 != r1. The helper mask bit for the
//                         pair is 1 if the pair is kept. For independent
//                         bits with any bias, kept bits are unbiased and the
//                         mask says nothing about their value.
//           Reconstruct : the stored mask selects the same pairs; output r0
//                         of every pair whose mask bit is 1 (r0 may now be
//                         noisy; the fuzzy extractor corrects it).
//           ENABLE = 0 passes raw bits through unchanged (no mask), for
//           comparison when the measured bias is small (see docs/puf_entropy.md).
//
// Ports   : clk, rst     system clock; synchronous active-high reset
//           raw_*        raw response bits in (valid/ready)
//           mask_in_*    (ENROLL = 0) helper mask bits in, one per pair
//           mask_out_*   (ENROLL = 1) helper mask bits out, one per pair
//           deb_*        debiased bits out (valid/ready)
//
// ENROLL  : 1 only in the separate enrollment bitstream (project brief §5.3).
//           Unused ports of the other mode are tied off inside.
// Latency : a few cycles per pair; never the bottleneck behind ro_puf.
// ============================================================================
module puf_debias #(
    parameter ENROLL = 0,
    parameter ENABLE = 1
) (
    input  wire clk,
    input  wire rst,
    input  wire raw_valid,
    output wire raw_ready,
    input  wire raw_bit,
    input  wire mask_in_valid,
    output wire mask_in_ready,
    input  wire mask_in_bit,
    output reg  mask_out_valid,
    input  wire mask_out_ready,
    output reg  mask_out_bit,
    output reg  deb_valid,
    input  wire deb_ready,
    output reg  deb_bit
);

    localparam [1:0] S_R0   = 2'd0,   // waiting for the first bit of a pair
                     S_R1   = 2'd1,   // waiting for the second bit
                     S_MASK = 2'd2,   // get (reconstruct) or put (enroll) the mask bit
                     S_OUT  = 2'd3;   // output the kept bit

    generate
        if (ENABLE == 0) begin : g_bypass
            assign raw_ready     = deb_ready;
            assign mask_in_ready = 1'b0;
            always @(*) begin
                deb_valid      = raw_valid;
                deb_bit        = raw_bit;
                mask_out_valid = 1'b0;
                mask_out_bit   = 1'b0;
            end
        end else begin : g_vn
            reg [1:0] state;
            reg       r0, r1;

            assign raw_ready     = (state == S_R0) || (state == S_R1);
            assign mask_in_ready = (ENROLL == 0) && (state == S_MASK);

            always @(posedge clk) begin
                if (rst) begin
                    state          <= S_R0;
                    r0             <= 1'b0;
                    r1             <= 1'b0;
                    mask_out_valid <= 1'b0;
                    mask_out_bit   <= 1'b0;
                    deb_valid      <= 1'b0;
                    deb_bit        <= 1'b0;
                end else begin
                    case (state)
                        S_R0: if (raw_valid) begin
                            r0    <= raw_bit;
                            state <= S_R1;
                        end

                        S_R1: if (raw_valid) begin
                            r1    <= raw_bit;
                            state <= S_MASK;
                            if (ENROLL != 0) begin
                                mask_out_valid <= 1'b1;
                                mask_out_bit   <= (r0 != raw_bit);
                            end
                        end

                        S_MASK: begin
                            if (ENROLL != 0) begin
                                if (mask_out_ready) begin
                                    mask_out_valid <= 1'b0;
                                    if (mask_out_bit) begin
                                        deb_valid <= 1'b1;
                                        deb_bit   <= r0;
                                        state     <= S_OUT;
                                    end else begin
                                        state     <= S_R0;
                                    end
                                end
                            end else if (mask_in_valid) begin
                                if (mask_in_bit) begin
                                    deb_valid <= 1'b1;
                                    deb_bit   <= r0;
                                    state     <= S_OUT;
                                end else begin
                                    state     <= S_R0;
                                end
                            end
                        end

                        S_OUT: if (deb_ready) begin
                            deb_valid <= 1'b0;
                            state     <= S_R0;
                        end

                        default: state <= S_R0;
                    endcase
                end
            end
        end
    endgenerate

endmodule
`default_nettype wire
