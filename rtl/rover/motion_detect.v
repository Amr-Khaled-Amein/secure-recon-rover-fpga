`default_nettype none
// ============================================================================
// motion_detect
// ----------------------------------------------------------------------------
// Purpose : frame-difference motion detector (project brief §5.4).
//           A frame buffer (inferred simple-dual-port BRAM) holds the previous
//           frame. For each incoming pixel: read previous, count it if
//           |cur - prev| > PIX_THRESH, write current over previous.
//           At frame end: motion = (count > AREA_THRESH).
//           The first frame after reset only fills the buffer (motion = 0).
//           A frame is also ignored (motion = 0) if `suppress` (motors
//           running) was high during it or during the frame before it, since
//           the reference frame was then taken while moving.
//
// Ports   : clk, rst     system clock; synchronous active-high reset
//           sof          start of frame pulse (before or with the first pixel)
//           pix_valid    1 = pix is a pixel (raster order)
//           pix          8-bit grayscale pixel
//           eof          end of frame pulse (with or after the last pixel)
//           suppress     1 = motors running, ignore this frame
//           result_valid 1-cycle pulse, one per frame, 4 cycles after eof
//           motion       1 = motion in the last frame (held)
//           motion_count number of changed pixels in the last frame (held)
//
// Pixels beyond WIDTH*HEIGHT in one frame are ignored.
// Latency : result_valid 4 cycles after eof. Accepts one pixel per clock.
// Memory  : ceil(WIDTH*HEIGHT/4096) BRAM36 (19 at 320x240).
// ============================================================================
module motion_detect #(
    parameter WIDTH       = 320,
    parameter HEIGHT      = 240,
    parameter PIX_THRESH  = 20,       // per-pixel difference threshold
    parameter AREA_THRESH = 400       // changed-pixel count threshold
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          sof,
    input  wire          pix_valid,
    input  wire [7:0]    pix,
    input  wire          eof,
    input  wire          suppress,
    output reg           result_valid,
    output reg           motion,
    output reg  [16:0]   motion_count
);

    localparam integer NPIX  = WIDTH * HEIGHT;
    localparam integer AW    = (NPIX > 65536) ? 17 : 16;
    localparam integer BW    = 12;                       // 4096 bytes per bank
    localparam integer NBANK = (NPIX + 4095) / 4096;     // 19 at 320x240
    localparam [AW-1:0] LAST_ADDR = NPIX - 1;
    localparam [7:0]    PTH = PIX_THRESH;
    localparam [16:0]   ATH = AREA_THRESH;

    // ------------------------------------------------------------------------
    // Frame buffer: NBANK banks of 4096 x 8, each one BRAM36 (4K x 9 mode).
    // One write port, one read port, read latency 1 + 1 output mux register.
    // (A single 76,800-deep array makes Vivado cascade 32K x 1 blocks and use
    //  24 BRAM36 instead of 19.)
    // ------------------------------------------------------------------------
    wire [AW-1:0]  raddr;
    reg            we;
    reg  [AW-1:0]  waddr;
    reg  [7:0]     wdata;
    wire [8*NBANK-1:0] bank_q;

    genvar b;
    generate
        for (b = 0; b < NBANK; b = b + 1) begin : g_bank
            (* ram_style = "block" *) reg [7:0] mem [0:4095];
            reg [7:0] q;
            always @(posedge clk) begin
                if (we && (waddr[AW-1:BW] == b)) mem[waddr[BW-1:0]] <= wdata;
                if (raddr[AW-1:BW] == b)         q <= mem[raddr[BW-1:0]];
            end
            assign bank_q[8*b +: 8] = q;
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Stage 0: address counter, read issued
    // ------------------------------------------------------------------------
    reg  [AW-1:0] addr;
    reg           full;                         // all NPIX pixels received
    wire [AW-1:0] cur_addr = sof ? {AW{1'b0}} : addr;
    wire          cur_full = sof ? 1'b0 : full;
    wire          take     = pix_valid && !cur_full;

    assign raddr = cur_addr;

    always @(posedge clk) begin
        if (rst) begin
            addr <= {AW{1'b0}};
            full <= 1'b0;
        end else if (take) begin
            if (cur_addr == LAST_ADDR) begin
                addr <= {AW{1'b0}};
                full <= 1'b1;
            end else begin
                addr <= cur_addr + {{(AW-1){1'b0}}, 1'b1};
                full <= 1'b0;
            end
        end else if (sof) begin
            addr <= {AW{1'b0}};
            full <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // Stage 1: bank output ready; write back the current pixel
    // Stage 2: bank mux registered
    // Stage 3: |cur - prev| > PIX_THRESH registered
    // Stage 4: count and frame result
    // ------------------------------------------------------------------------
    reg           v1, v2, eof1, eof2, eof3, sof1, sof2, sof3;
    reg  [7:0]    pix1, pix2, prev2;
    reg  [AW-1:0] addr1;
    reg  [AW-BW-1:0] bank1;
    reg           hit3;

    wire [7:0]  diff2 = (pix2 > prev2) ? (pix2 - prev2) : (prev2 - pix2);

    reg  [16:0] count;
    wire [16:0] count_base = sof3 ? 17'd0 : count;
    wire [16:0] count_now  = count_base + {16'd0, hit3};

    reg         primed;          // previous frame exists
    reg         supp_cur;        // suppress seen in this frame
    reg         supp_prev;       // suppress seen in the previous frame

    always @(posedge clk) begin
        we           <= 1'b0;
        result_valid <= 1'b0;
        if (rst) begin
            v1 <= 1'b0; v2 <= 1'b0;
            eof1 <= 1'b0; eof2 <= 1'b0; eof3 <= 1'b0;
            sof1 <= 1'b0; sof2 <= 1'b0; sof3 <= 1'b0;
            pix1 <= 8'd0; pix2 <= 8'd0; prev2 <= 8'd0;
            addr1        <= {AW{1'b0}};
            bank1        <= {(AW-BW){1'b0}};
            hit3         <= 1'b0;
            waddr        <= {AW{1'b0}};
            wdata        <= 8'd0;
            count        <= 17'd0;
            primed       <= 1'b0;
            supp_cur     <= 1'b0;
            supp_prev    <= 1'b0;
            motion       <= 1'b0;
            motion_count <= 17'd0;
        end else begin
            // stage 0 -> 1
            v1    <= take;
            pix1  <= pix;
            addr1 <= cur_addr;
            bank1 <= cur_addr[AW-1:BW];
            eof1  <= eof;
            sof1  <= sof;

            // stage 1: write back the current pixel, select the bank output
            if (v1) begin
                we    <= 1'b1;
                waddr <= addr1;
                wdata <= pix1;
            end
            v2    <= v1;
            pix2  <= pix1;
            prev2 <= bank_q[8*bank1 +: 8];
            eof2  <= eof1;
            sof2  <= sof1;

            // stage 2 -> 3
            hit3 <= v2 && (diff2 > PTH);
            eof3 <= eof2;
            sof3 <= sof2;

            // stage 4: frame result
            if (eof3) begin
                motion_count <= count_now;
                motion       <= primed && !supp_cur && !supp_prev && !suppress
                                && (count_now > ATH);
                result_valid <= 1'b1;
                primed       <= 1'b1;
                supp_prev    <= supp_cur || suppress;
                supp_cur     <= 1'b0;
                count        <= 17'd0;
            end else begin
                count        <= count_now;
                if (suppress) supp_cur <= 1'b1;
            end
        end
    end

endmodule
`default_nettype wire
