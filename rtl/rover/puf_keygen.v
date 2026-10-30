`default_nettype none
// ============================================================================
// puf_keygen
// ----------------------------------------------------------------------------
// Purpose : the rover's long-term key K from the RO-PUF (project brief §5.3):
//             ro_puf (TMV) -> puf_debias -> fuzzy_extractor -> puf_hash -> K
//           K is regenerated at every power-up and never stored.
//
//           Helper data (public, stored in rover flash):
//             mask   : one bit per raw pair consumed by puf_debias
//             offset : R-1 bits per repetition block (fuzzy_extractor)
//           ENROLL = 1 (enrollment bitstream only) PRODUCES the helper data
//           on mask_out_* / off_out_*; ENROLL = 0 (deployed bitstream)
//           CONSUMES it on mask_in_* / off_in_*.
//
// Ports   : clk, rst     system clock; synchronous active-high reset
//           start        1-cycle pulse after reset: generate K
//           mask_in_*, off_in_*    helper data in  (valid/ready, ENROLL = 0)
//           mask_out_*, off_out_*  helper data out (valid/ready, ENROLL = 1)
//           key          K, valid while key_valid = 1. In the deployed design
//                        this port may only feed the session KDF / HELLO
//                        logic, never a pin, ILA or UART (project brief §5.3).
//           key_valid    1 once K is ready, until reset
//           err          1 = the PUF ran out of bits before NB*R debiased
//                        bits were collected (enrollment: choose a larger
//                        N_RO or smaller NB)
//           nerr         number of bits the fuzzy extractor corrected
//
// Sizing  : with the Phase 0 repetition code alone, no RO count that fits
//           this FPGA gives a 128-bit key (docs/puf_entropy.md). The default
//           parameters only demonstrate the pipeline on hardware.
// Latency : dominated by ro_puf: ~VOTES*(WINDOW+2*SETTLE+2) cycles per raw bit.
// ============================================================================
module puf_keygen #(
    parameter ENROLL = 0,
    parameter DEBIAS = 1,
    parameter N_RO   = 1280,
    parameter WINDOW = 4096,
    parameter VOTES  = 5,
    parameter SETTLE = 8,
    parameter R      = 5,
    parameter NB     = 24,      // Phase 0 demo sizing: 24-bit entropy, NOT a
                                // 128-bit key. Final sizing needs the BCH outer
                                // code: see docs/puf_entropy.md
    parameter SIM_RO = 0
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire         mask_in_valid,
    output wire         mask_in_ready,
    input  wire         mask_in_bit,
    output wire         mask_out_valid,
    input  wire         mask_out_ready,
    output wire         mask_out_bit,
    input  wire         off_in_valid,
    output wire         off_in_ready,
    input  wire         off_in_bit,
    output wire         off_out_valid,
    input  wire         off_out_ready,
    output wire         off_out_bit,
    output wire [127:0] key,
    output wire         key_valid,
    output reg          err,
    output wire [15:0]  nerr
);

    // ro_puf -> puf_debias
    wire        raw_valid, raw_ready, raw_bit, puf_done, puf_busy;
    wire [15:0] raw_idx_unused;
    // puf_debias -> fuzzy_extractor
    wire        deb_valid, deb_ready, deb_bit;
    // fuzzy_extractor -> puf_hash
    wire        fe_valid, fe_ready, fe_bit, fe_done_unused, fe_finished;
    wire        hash_done_unused;

    ro_puf #(
        .N_RO(N_RO), .WINDOW(WINDOW), .VOTES(VOTES), .SETTLE(SETTLE), .SIM_RO(SIM_RO)
    ) u_puf (
        .clk(clk), .rst(rst), .start(start), .busy(puf_busy),
        .bit_valid(raw_valid), .bit_ready(raw_ready), .bit_out(raw_bit),
        .bit_idx(raw_idx_unused), .done(puf_done)
    );

    puf_debias #(.ENROLL(ENROLL), .ENABLE(DEBIAS)) u_debias (
        .clk(clk), .rst(rst),
        .raw_valid(raw_valid), .raw_ready(raw_ready), .raw_bit(raw_bit),
        .mask_in_valid(mask_in_valid), .mask_in_ready(mask_in_ready), .mask_in_bit(mask_in_bit),
        .mask_out_valid(mask_out_valid), .mask_out_ready(mask_out_ready), .mask_out_bit(mask_out_bit),
        .deb_valid(deb_valid), .deb_ready(deb_ready), .deb_bit(deb_bit)
    );

    fuzzy_extractor #(.R(R), .NB(NB), .ENROLL(ENROLL)) u_fe (
        .clk(clk), .rst(rst),
        .in_valid(deb_valid), .in_ready(deb_ready), .in_bit(deb_bit),
        .off_in_valid(off_in_valid), .off_in_ready(off_in_ready), .off_in_bit(off_in_bit),
        .off_out_valid(off_out_valid), .off_out_ready(off_out_ready), .off_out_bit(off_out_bit),
        .out_valid(fe_valid), .out_ready(fe_ready), .out_bit(fe_bit),
        .done(fe_done_unused), .finished(fe_finished), .nerr(nerr)
    );

    puf_hash #(.NBITS(NB * R)) u_hash (
        .clk(clk), .rst(rst),
        .in_valid(fe_valid), .in_ready(fe_ready), .in_bit(fe_bit),
        .key(key), .key_valid(key_valid), .done(hash_done_unused)
    );

    // out of PUF bits: ro_puf finished, debias waits for more raw bits,
    // and the fuzzy extractor still needs bits
    reg puf_finished;
    always @(posedge clk) begin
        if (rst) begin
            puf_finished <= 1'b0;
            err          <= 1'b0;
        end else begin
            if (puf_done) puf_finished <= 1'b1;
            if (puf_finished && !puf_busy && raw_ready && deb_ready && !fe_finished)
                err <= 1'b1;
        end
    end

endmodule
`default_nettype wire
