# Out-of-context constraint for synthesizing a single core: 100 MHz system clock.
# Used by scripts/synth.tcl. Board pin constraints live in cmod_a7.xdc / basys3.xdc.
create_clock -period 10.000 -name clk [get_ports clk]
