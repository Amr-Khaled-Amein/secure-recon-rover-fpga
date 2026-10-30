// ============================================================================
// demo_aes128 : interactive demo harness for aes128_core (not a testbench)
// ----------------------------------------------------------------------------
// Driven from the XSim Tcl console by scripts/aes_demo.tcl:
//   Tcl writes key and block_in, then sets go = 1. A rising edge on go makes
//   one start pulse. The ciphertext appears on block_out.
// The self-checking test is tb_aes128_core.sv.
// ============================================================================
`timescale 1ns/1ps

module demo_aes128;

    logic         clk      = 1'b0;
    logic         rst      = 1'b1;
    logic         go       = 1'b0;      // set by Tcl
    logic         go_d     = 1'b0;
    logic [127:0] key      = '0;        // set by Tcl
    logic [127:0] block_in = '0;        // set by Tcl
    wire          ready;
    wire          done;
    wire  [127:0] block_out;

    always #5 clk = ~clk;               // 100 MHz

    initial #20 rst = 1'b0;

    // one start pulse per rising edge of go
    always @(posedge clk) go_d <= go;
    wire start = go & ~go_d;

    aes128_core dut (
        .clk(clk), .rst(rst), .start(start), .key(key), .block_in(block_in),
        .ready(ready), .done(done), .block_out(block_out)
    );

endmodule
