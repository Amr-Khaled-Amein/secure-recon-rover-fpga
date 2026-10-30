`default_nettype none
// ============================================================================
// ro_trng
// ----------------------------------------------------------------------------
// Purpose : ring-oscillator jitter TRNG, raw source (project brief §5.2), on both
//           boards. N_RO free-running ring oscillators are XORed and sampled
//           by the system clock; one raw bit every DECIM cycles, so the
//           jitter accumulates between samples.
//           Raw bits must go through trng_health and then be conditioned
//           (AES CBC-MAC in session_kdf) before use as nonces.
//
// CDC     : the XOR of the ROs is asynchronous; it is sampled by a 2-flop
//           synchronizer (metastability of the first flop is part of the
//           noise, the second flop resolves it).
//
// Ports   : clk, rst   system clock; synchronous active-high reset
//           enable     1 = ROs running and producing bits
//           raw_valid  1-cycle strobe every DECIM cycles
//           raw_bit    raw sample
//
// Latency : first bit DECIM + 2 cycles after enable.
// SIM_RO  : 1 = behavioral RO model tb/common/ro_cell_sim.sv (sim only)
// ============================================================================
module ro_trng #(
    parameter N_RO   = 4,
    parameter DECIM  = 64,
    parameter SIM_RO = 0
) (
    input  wire clk,
    input  wire rst,
    input  wire enable,
    output reg  raw_valid,
    output reg  raw_bit
);

    localparam [15:0] LAST = DECIM - 1;

    wire [N_RO-1:0] ro_out;
    genvar i;
    generate
        for (i = 0; i < N_RO; i = i + 1) begin : g_ro
            if (SIM_RO != 0) begin : g_sim
                // IDX offset keeps these model instances apart from the PUF ROs
                ro_cell_sim #(.IDX(100000 + i), .NOM_PS(4000.0 + 173.0 * i)) u_ro (
                    .en(enable), .ro_out(ro_out[i]));
            end else begin : g_hw
                (* DONT_TOUCH = "yes" *) ro_cell u_ro (.en(enable), .ro_out(ro_out[i]));
            end
        end
    endgenerate

    wire mixed = ^ro_out;

    (* ASYNC_REG = "TRUE" *) reg s1;
    (* ASYNC_REG = "TRUE" *) reg s2;
    reg [15:0] cnt;

    always @(posedge clk) begin
        raw_valid <= 1'b0;
        if (rst) begin
            s1      <= 1'b0;
            s2      <= 1'b0;
            cnt     <= 16'd0;
            raw_bit <= 1'b0;
        end else begin
            s1 <= mixed;
            s2 <= s1;
            if (!enable) begin
                cnt <= 16'd0;
            end else if (cnt == LAST) begin
                cnt       <= 16'd0;
                raw_valid <= 1'b1;
                raw_bit   <= s2;
            end else begin
                cnt <= cnt + 16'd1;
            end
        end
    end

endmodule
`default_nettype wire
