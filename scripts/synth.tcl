# ============================================================================
# synth.tcl : synthesize, place and route one module for the target FPGA
#             (out-of-context, so wide cores need no pins) and report
#             LUT / FF / BRAM / DSP usage and timing at 100 MHz.
#
# Usage (from the project root):
#   vivado -mode batch -nojournal -source scripts/synth.tcl -tclargs <module>
#
# Fails (exit code 1) if:
#   - the target part is not installed in this Vivado,
#   - synthesis infers a latch,
#   - timing at 100 MHz is not met (WNS < 0).
# Reports are copied to build/synth/<module>/ in the project.
#
# Vivado works in a local folder outside OneDrive (opt_design fails with an
# empty "Synth 20-411" error when its work folder is synced by OneDrive):
#   %ROVER_BUILD%  if set, else  %LOCALAPPDATA%\rover_fpga_build
# ============================================================================
set part   xc7a35tcpg236-1
if {[llength $argv] != 1} {
    error "usage: -tclargs <module>"
}
set top    [lindex $argv 0]
set root   [file normalize [file join [file dirname [info script]] ..]]
if {[info exists ::env(ROVER_BUILD)]} {
    set work [file normalize $::env(ROVER_BUILD)]
} else {
    set work [file normalize [file join $::env(LOCALAPPDATA) rover_fpga_build]]
}
set outdir [file join $work synth $top]
set repdir [file join $root build synth $top]
foreach d [list $outdir $repdir] {
    file delete -force $d
    file mkdir $d
}
cd $outdir

if {[llength [get_parts -quiet $part]] == 0} {
    error "SYNTH: part $part is not installed. Re-run the Vivado installer and add Artix-7 device support."
}

read_verilog [lsort [glob [file join $root rtl * *.v]]]
read_xdc -mode out_of_context [file join $root constraints ooc_100mhz.xdc]

synth_design -top $top -part $part -mode out_of_context
set latches [get_cells -quiet -hierarchical -filter {REF_NAME =~ LD*}]
if {[llength $latches] > 0} {
    error "SYNTH: [llength $latches] latch(es) inferred: $latches"
}
report_utilization -file utilization_synth.rpt

opt_design
place_design
route_design

report_utilization        -file utilization_routed.rpt
report_timing_summary     -file timing_routed.rpt
write_checkpoint -force   ${top}_routed.dcp

# --- one-line summary -------------------------------------------------------
proc util_row {rpt name label} {
    if {[regexp "\\|\\s*${name}\\s*\\|\\s*(\[0-9.\]+)\\s*\\|\[^\\n\]*?\\|\\s*(\[0-9.\]+)\\s*\\|\\s*(\[0-9.<\]+)\\s*\\|\\s*\\n" $rpt -> used avail pct]} {
        return [format "%-16s %8s / %-7s (%s%%)" $label $used $avail $pct]
    }
    return [format "%-16s (not found)" $label]
}
set rpt [report_utilization -return_string]
set wns [get_property SLACK [lindex [get_timing_paths -max_paths 1 -setup] 0]]
set fmax [expr {1000.0 / (10.0 - $wns)}]

set summary [list \
    "==================== $top on $part ====================" \
    [util_row $rpt {Slice LUTs\*?} LUTs] \
    [util_row $rpt {Slice Registers} FFs] \
    [util_row $rpt {Block RAM Tile} BRAM36] \
    [util_row $rpt {DSPs} DSPs] \
    [format "Timing @100 MHz  WNS = %.3f ns   (est. Fmax %.0f MHz)" $wns $fmax] \
    "=======================================================" ]
set fh [open summary.txt w]
foreach line $summary { puts $line; puts $fh $line }
close $fh

foreach f {summary.txt utilization_synth.rpt utilization_routed.rpt timing_routed.rpt} {
    file copy -force $f [file join $repdir $f]
}
puts "SYNTH: reports in $repdir (work files in $outdir)"

if {$wns < 0} {
    error "SYNTH: timing FAILED at 100 MHz (WNS = $wns ns)"
}
puts "SYNTH: $top PASSED"
