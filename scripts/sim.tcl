# ============================================================================
# sim.tcl : compile and run one self-checking testbench with XSim
#
# Usage (from the project root):
#   vivado -mode batch -nojournal -source scripts/sim.tcl -tclargs <module>
# Example:
#   vivado -mode batch -nojournal -source scripts/sim.tcl -tclargs aes128_core
#
# Compiles every rtl/*/*.v file, the shared testbench helpers tb/common/*.sv
# and tb/tb_<module>.sv, runs the simulation (+VEC_DIR = model/vectors)
# and fails (exit code 1) unless the log contains "TEST PASSED" and no
# $fatal / error. The log is copied to build/sim/<module>/xsim.log.
#
# Work files go to a local folder outside OneDrive (see synth.tcl):
#   %ROVER_BUILD%  if set, else  %LOCALAPPDATA%\rover_fpga_build
# ============================================================================
if {[llength $argv] != 1} {
    error "usage: -tclargs <module>"
}
set top    [lindex $argv 0]
set tbtop  "tb_${top}"
set root   [file normalize [file join [file dirname [info script]] ..]]
if {[info exists ::env(ROVER_BUILD)]} {
    set work [file normalize $::env(ROVER_BUILD)]
} else {
    set work [file normalize [file join $::env(LOCALAPPDATA) rover_fpga_build]]
}
set outdir [file join $work sim $top]
set repdir [file join $root build sim $top]
set tbfile [file join $root tb ${tbtop}.sv]

if {![file exists $tbfile]} { error "testbench not found: $tbfile" }
foreach d [list $outdir $repdir] {
    file delete -force $d
    file mkdir $d
}
cd $outdir

set rtl [lsort [glob -nocomplain [file join $root rtl * *.v]]]
puts "SIM: [llength $rtl] RTL files, testbench $tbtop"

# Run a Vivado command-line tool; stop on a non-zero exit code.
proc run_tool {args} {
    puts "SIM: $args"
    if {[catch {exec -ignorestderr {*}$args 2>@1} out opts]} {
        puts $out
        error "SIM: [lindex $args 0] failed"
    }
    puts $out
    return $out
}

run_tool xvlog --nolog --incr {*}$rtl
set tblib [lsort [glob -nocomplain [file join $root tb common *.sv]]]
run_tool xvlog --nolog --incr -sv {*}$tblib $tbfile
run_tool xelab --nolog -debug typical -timescale 1ns/1ps $tbtop -s snap_$tbtop
set vecdir [file join $root model vectors]
set log [run_tool xsim snap_$tbtop -R -log xsim.log -testplusarg VEC_DIR=$vecdir]
file copy -force xsim.log [file join $repdir xsim.log]

if {[regexp {Fatal|FATAL|ERROR:} $log] || ![regexp {TEST PASSED} $log]} {
    error "SIM: $tbtop FAILED (see $outdir/xsim.log)"
}
puts "SIM: $tbtop PASSED"
