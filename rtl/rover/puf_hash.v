`default_nettype none
// ============================================================================
// puf_hash
// ----------------------------------------------------------------------------
// Purpose : privacy amplification of the corrected PUF response into the
//           128-bit key K (project brief §5.3): Davies-Meyer with AES-128,
//               H_0 = 0,  H_i = AES_{m_i}(H_{i-1}) xor H_{i-1},  K = H_last
//           where m_i are the input bits packed MSB-first into 128-bit
//           blocks; the last block is zero-padded. The input length NBITS is
//           a fixed design parameter, so no length padding is needed.
//           Same function as davies_meyer() in model/gcm_model.py.
//           In rover_top the aes128_core can be shared with GCM, since K is
//           derived once at power-up before any packet is processed.
//
// Ports   : clk, rst   system clock; synchronous active-high reset
//           in_*       input bits (valid/ready), exactly NBITS of them
//           key        K, valid while key_valid = 1
//           key_valid  1 after the last block, until reset
//           done       1-cycle pulse when key becomes valid
//
// Latency : 1 cycle per input bit, + 12 cycles per 128-bit block.
// ============================================================================
module puf_hash #(
    parameter NBITS = 680
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         in_valid,
    output wire         in_ready,
    input  wire         in_bit,
    output reg  [127:0] key,
    output reg          key_valid,
    output reg          done
);

    localparam [15:0] LAST_BIT = NBITS - 1;

    localparam [1:0] S_IN  = 2'd0,
                     S_AES = 2'd1,
                     S_FIN = 2'd2;

    reg [1:0]   state;
    reg [127:0] m;
    reg [127:0] h;
    reg [6:0]   pos;
    reg [15:0]  total;
    reg         last;

    reg          aes_go;
    wire         aes_done;
    wire [127:0] aes_out;
    wire         aes_ready_unused;

    aes128_core u_aes (
        .clk(clk), .rst(rst), .start(aes_go), .key(m), .block_in(h),
        .ready(aes_ready_unused), .done(aes_done), .block_out(aes_out)
    );

    assign in_ready = (state == S_IN);

    always @(posedge clk) begin
        aes_go <= 1'b0;
        done   <= 1'b0;
        if (rst) begin
            state     <= S_IN;
            m         <= 128'd0;
            h         <= 128'd0;
            pos       <= 7'd0;
            total     <= 16'd0;
            last      <= 1'b0;
            key       <= 128'd0;
            key_valid <= 1'b0;
        end else begin
            case (state)
                S_IN: if (in_valid) begin
                    m[7'd127 - pos] <= in_bit;
                    pos   <= pos + 7'd1;
                    total <= total + 16'd1;
                    if (pos == 7'd127 || total == LAST_BIT) begin
                        last   <= (total == LAST_BIT);
                        aes_go <= 1'b1;
                        state  <= S_AES;
                    end
                end

                S_AES: if (aes_done) begin
                    h   <= aes_out ^ h;
                    m   <= 128'd0;
                    pos <= 7'd0;
                    if (last) begin
                        key       <= aes_out ^ h;
                        key_valid <= 1'b1;
                        done      <= 1'b1;
                        state     <= S_FIN;
                    end else begin
                        state     <= S_IN;
                    end
                end

                S_FIN: ;   // key held until reset

                default: state <= S_IN;
            endcase
        end
    end

endmodule
`default_nettype wire
