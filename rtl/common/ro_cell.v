`default_nettype none
// ============================================================================
// ro_cell
// ----------------------------------------------------------------------------
// Purpose : one ring oscillator for the RO-PUF / RO-TRNG: a NAND (enable)
//           plus two inverters in a loop (3 stages, ~3 LUTs).
//           This is the ONLY place in the design where a combinational loop
//           is allowed (ALLOW_COMBINATORIAL_LOOPS). Every instance must be an
//           identical macro with fixed placement and routing (LOC/BEL,
//           RLOC, Pblock, DONT_TOUCH, locked routes; project brief §5.3), applied
//           in the board XDC in Phase 4.
//
// Ports   : en      1 = oscillate, 0 = stop (output settles to 1)
//           ro_out  oscillator output (asynchronous; only for counter clocks)
//
// Simulation: an event simulator cannot run this zero-delay loop. The
//           testbenches use the behavioral model tb/common/ro_cell_sim.sv
//           instead (ro_puf / ro_trng parameter SIM_RO = 1).
// ============================================================================
module ro_cell (
    input  wire en,
    output wire ro_out
);

    (* DONT_TOUCH = "yes", ALLOW_COMBINATORIAL_LOOPS = "true" *) wire s0;
    (* DONT_TOUCH = "yes", ALLOW_COMBINATORIAL_LOOPS = "true" *) wire s1;
    (* DONT_TOUCH = "yes", ALLOW_COMBINATORIAL_LOOPS = "true" *) wire s2;

    assign s0     = ~(en & s2);
    assign s1     = ~s0;
    assign s2     = ~s1;
    assign ro_out = s2;

endmodule
`default_nettype wire
