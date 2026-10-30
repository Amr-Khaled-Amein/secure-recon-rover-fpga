`default_nettype none
// ============================================================================
// ro_puf
// ----------------------------------------------------------------------------
// Purpose : ring-oscillator PUF (project brief §5.3). N_RO identical ring
//           oscillators in disjoint pairs (2p, 2p+1): N_RO/2 response bits.
//           Bit p = 1 when RO 2p counts more edges than RO 2p+1 in the same
//           window. Each bit is the majority of VOTES measurements (temporal
//           majority voting).
//           Only the two ROs of the pair being measured run at any time
//           (measurement in batches: limits self-heating and supply noise).
//
// Counting: the selected pair's outputs clock two free-running CW-bit
//           counters. The system clock reads them only while both ROs are
//           stopped and the counters have been static for SETTLE cycles, so
//           the read is of static data (no synchronizer needed); the
//           edge count of a window is the difference of two reads (mod 2^CW).
//           CW must satisfy f_RO * WINDOW / f_clk < 2^CW.
//           These counters are the only flops not on the system clock and
//           have no reset (power-up value 0; only differences are used).
//
// Ports   : clk, rst   system clock; synchronous active-high reset
//           start      1-cycle pulse: measure all pairs once, in order
//           busy       1 while measuring
//           bit_valid  response bit available (held until bit_ready)
//           bit_ready  consumer accepts the bit
//           bit_out    response bit
//           bit_idx    pair index of bit_out
//           done       1-cycle pulse after the last pair
//
// Latency : per bit ~VOTES * (WINDOW + 2*SETTLE + 2) cycles. With the
//           defaults: 5 * 4114 cycles = ~206 us per bit, ~132 ms for 640 bits.
//
// SIM_RO  : 1 = use the behavioral model tb/common/ro_cell_sim.sv (sim only)
// ============================================================================
module ro_puf #(
    parameter N_RO   = 1280,     // even
    parameter WINDOW = 4096,     // measurement window, system clock cycles
    parameter VOTES  = 5,        // odd, measurements per bit
    parameter SETTLE = 8,        // cycles to let the ROs/mux/counters settle
    parameter CW     = 16,       // edge counter width
    parameter SIM_RO = 0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output wire        busy,
    output reg         bit_valid,
    input  wire        bit_ready,
    output reg         bit_out,
    output reg  [15:0] bit_idx,
    output reg         done
);

    localparam integer NPAIR = N_RO / 2;
    localparam [15:0]  LAST_PAIR = NPAIR - 1;
    localparam [7:0]   LAST_VOTE = VOTES - 1;
    localparam [7:0]   HALF_VOTES = VOTES / 2;
    localparam [23:0]  LAST_WIN  = WINDOW - 1;
    localparam [7:0]   LAST_SET  = SETTLE - 1;

    localparam [2:0] S_IDLE = 3'd0,
                     S_SEL  = 3'd1,    // pair selected, waiting to settle
                     S_RUN  = 3'd2,    // both ROs running
                     S_STOP = 3'd3,    // stopped, waiting to settle
                     S_OUT  = 3'd4;    // bit waiting for bit_ready

    reg  [2:0]  state;
    reg  [15:0] pair;
    reg  [7:0]  vote;
    reg  [7:0]  ones;
    reg  [23:0] wcnt;
    reg         run;

    assign busy = (state != S_IDLE);

    // ------------------------------------------------------------------------
    // Ring oscillators: only the selected pair is enabled
    // ------------------------------------------------------------------------
    wire [N_RO-1:0] ro_out;
    genvar i;
    generate
        for (i = 0; i < N_RO; i = i + 1) begin : g_ro
            wire en = run && (pair == (i / 2));
            if (SIM_RO != 0) begin : g_sim
                ro_cell_sim #(.IDX(i)) u_ro (.en(en), .ro_out(ro_out[i]));
            end else begin : g_hw
                (* DONT_TOUCH = "yes" *) ro_cell u_ro (.en(en), .ro_out(ro_out[i]));
            end
        end
    endgenerate

    wire ro_a = ro_out[{pair, 1'b0}];
    wire ro_b = ro_out[{pair, 1'b1}];

    // free-running edge counters in the RO domains (see header)
    reg [CW-1:0] cnt_a = {CW{1'b0}};
    reg [CW-1:0] cnt_b = {CW{1'b0}};
    always @(posedge ro_a) cnt_a <= cnt_a + {{(CW-1){1'b0}}, 1'b1};
    always @(posedge ro_b) cnt_b <= cnt_b + {{(CW-1){1'b0}}, 1'b1};

    reg  [CW-1:0] a0, b0;
    wire [CW-1:0] da = cnt_a - a0;
    wire [CW-1:0] db = cnt_b - b0;

    // ------------------------------------------------------------------------
    // Control
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state     <= S_IDLE;
            pair      <= 16'd0;
            vote      <= 8'd0;
            ones      <= 8'd0;
            wcnt      <= 24'd0;
            run       <= 1'b0;
            a0        <= {CW{1'b0}};
            b0        <= {CW{1'b0}};
            bit_valid <= 1'b0;
            bit_out   <= 1'b0;
            bit_idx   <= 16'd0;
        end else begin
            case (state)
                S_IDLE: if (start) begin
                    pair  <= 16'd0;
                    vote  <= 8'd0;
                    ones  <= 8'd0;
                    wcnt  <= 24'd0;
                    state <= S_SEL;
                end

                S_SEL: begin
                    if (wcnt[7:0] == LAST_SET) begin
                        a0    <= cnt_a;            // static: ROs stopped
                        b0    <= cnt_b;
                        wcnt  <= 24'd0;
                        run   <= 1'b1;
                        state <= S_RUN;
                    end else begin
                        wcnt  <= wcnt + 24'd1;
                    end
                end

                S_RUN: begin
                    if (wcnt == LAST_WIN) begin
                        run   <= 1'b0;
                        wcnt  <= 24'd0;
                        state <= S_STOP;
                    end else begin
                        wcnt  <= wcnt + 24'd1;
                    end
                end

                S_STOP: begin
                    if (wcnt[7:0] == LAST_SET) begin
                        wcnt <= 24'd0;
                        if (vote == LAST_VOTE) begin
                            bit_out   <= ((ones + {7'd0, (da > db)}) > HALF_VOTES);
                            bit_idx   <= pair;
                            bit_valid <= 1'b1;
                            state     <= S_OUT;
                        end else begin
                            ones  <= ones + {7'd0, (da > db)};
                            vote  <= vote + 8'd1;
                            state <= S_SEL;
                        end
                    end else begin
                        wcnt <= wcnt + 24'd1;
                    end
                end

                S_OUT: if (bit_ready) begin
                    bit_valid <= 1'b0;
                    vote      <= 8'd0;
                    ones      <= 8'd0;
                    if (pair == LAST_PAIR) begin
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        pair  <= pair + 16'd1;
                        state <= S_SEL;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
`default_nettype wire
