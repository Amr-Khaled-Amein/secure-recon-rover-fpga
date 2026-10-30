`default_nettype none
// ============================================================================
// trng_health
// ----------------------------------------------------------------------------
// Purpose : online health tests for the RO TRNG (NIST SP 800-90B §4.4) on
//           1-bit raw samples (project brief §5.2):
//             Repetition Count Test : fail if RCT_C identical samples in a row
//             Adaptive Proportion   : in each window of APT_W samples, fail
//                                     if the first sample's value occurs
//                                     APT_C or more times
//           Cutoffs for false-alarm rate alpha = 2^-20 and assumed min-entropy
//           H per raw bit:  RCT_C = 1 + ceil(20/H),
//                           APT_C = 1 + CRITBINOM(APT_W, 2^-H, 1 - alpha).
//           Defaults are for H = 0.5: RCT_C = 41, APT_C = 793 (W = 1024).
//           Replace H with the measured value in Phase 4 (docs/trng.md).
//           Start-up: no output until the first APT window passes.
//           On any failure: output blocked and `fail` latched until reset.
//
// Ports   : clk, rst     system clock; synchronous active-high reset
//           in_valid     raw sample strobe (no back-pressure: free-running)
//           in_bit       raw sample
//           out_valid    sample passed the tests (1 cycle after in_valid)
//           out_bit      the sample
//           startup_done 1 after the first full window without failure
//           fail         sticky error flag (rct_fail | apt_fail)
//           rct_fail, apt_fail  which test tripped
//
// Latency : 1 cycle.
// ============================================================================
module trng_health #(
    parameter RCT_C = 41,
    parameter APT_W = 1024,
    parameter APT_C = 793
) (
    input  wire clk,
    input  wire rst,
    input  wire in_valid,
    input  wire in_bit,
    output reg  out_valid,
    output reg  out_bit,
    output reg  startup_done,
    output wire fail,
    output reg  rct_fail,
    output reg  apt_fail
);

    localparam [10:0] RCT_LIM  = RCT_C;
    localparam [10:0] APT_LIM  = APT_C;
    localparam [10:0] APT_LAST = APT_W - 1;

    reg        rct_a;        // last sample
    reg [10:0] rct_b;        // run length of rct_a
    reg        apt_a;        // first sample of the window
    reg [10:0] apt_b;        // occurrences of apt_a in the window
    reg [10:0] apt_n;        // position in the window

    assign fail = rct_fail || apt_fail;

    // results including the current sample
    wire [10:0] rct_b_next = (in_bit == rct_a) ? (rct_b + 11'd1) : 11'd1;
    wire        apt_first  = (apt_n == 11'd0);
    wire [10:0] apt_b_next = apt_first ? 11'd1 :
                             ((in_bit == apt_a) ? (apt_b + 11'd1) : apt_b);
    wire        rct_trip   = (rct_b_next >= RCT_LIM);
    wire        apt_trip   = (apt_b_next >= APT_LIM);

    always @(posedge clk) begin
        out_valid <= 1'b0;
        if (rst) begin
            rct_a        <= 1'b0;
            rct_b        <= 11'd0;
            apt_a        <= 1'b0;
            apt_b        <= 11'd0;
            apt_n        <= 11'd0;
            rct_fail     <= 1'b0;
            apt_fail     <= 1'b0;
            startup_done <= 1'b0;
            out_bit      <= 1'b0;
        end else if (in_valid) begin
            rct_a <= in_bit;
            rct_b <= rct_b_next;
            if (apt_first) apt_a <= in_bit;
            apt_b <= apt_b_next;
            apt_n <= (apt_n == APT_LAST) ? 11'd0 : (apt_n + 11'd1);

            if (rct_trip) rct_fail <= 1'b1;
            if (apt_trip) apt_fail <= 1'b1;
            if (apt_n == APT_LAST && !rct_trip && !apt_trip && !fail)
                startup_done <= 1'b1;

            out_bit   <= in_bit;
            out_valid <= startup_done && !fail && !rct_trip && !apt_trip;
        end
    end

endmodule
`default_nettype wire
