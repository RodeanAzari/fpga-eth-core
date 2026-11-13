# Batch build of an example design for the Arty A7-100T:
#   vivado -mode batch -source syn/build_example.tcl -tclargs <rx_stats|udp_echo> [<part>] [ct]
# "ct" builds rx_stats with eth_rx in cut-through (CUT_THROUGH=1) into build/rx_stats_ct/
# and docs/reports/rx_stats_ct/.
# Non-project flow; nothing but build/ is written, except the reports copied to
# docs/reports/<example>/ for committing. The bitstream is written only if every timing
# path meets and no clock-domain crossing is unconstrained.
# Test builds: EXAMPLE_GENERICS="NAME=VALUE ..." sets top-level parameters (e.g. the
# fpga-coord 0005 reset tests); output goes to build/<example>_test/, reports included,
# and docs/reports/ is not touched.

set expected_vivado 2025.2
if {[version -short] ne $expected_vivado} {
    puts "WARNING: Vivado [version -short], pinned version is $expected_vivado (docs: README)"
}

set example [lindex $argv 0]
set part    [lindex $argv 1]
if {$part eq ""} { set part xc7a100tcsg324-1 }
set ct      [expr {[lindex $argv 2] eq "ct"}]
if {$ct && $example ne "rx_stats"} { error "ct: rx_stats only" }
set repo    [file normalize [file join [file dirname [info script]] ..]]
# Per example: top module, extra source globs (beyond rtl/ and the shared rx_stats
# helpers), and constraint files read before async_fifo.xdc.
set ex [file join $repo examples]
set c  [file join $repo constr]
switch -- $example {
    rx_stats {
        set top   rx_stats_top
        set srcs  {}
        set xdcs  [list [file join $c arty_a7_100_pins.xdc] [file join $c rx_stats_timing.xdc]]
    }
    udp_echo {
        set top   udp_echo_top
        set srcs  [glob [file join $ex udp_echo *.sv]]
        set xdcs  [list [file join $c arty_a7_100_pins.xdc] [file join $c arty_a7_100_pins_tx.xdc] \
                       [file join $c udp_echo_timing.xdc]]
    }
    default { error "unknown example '$example' (rx_stats | udp_echo)" }
}
set tag     [expr {$ct ? "${example}_ct" : $example}]
set generics {}
if {[info exists ::env(EXAMPLE_GENERICS)] && $::env(EXAMPLE_GENERICS) ne ""} {
    foreach g $::env(EXAMPLE_GENERICS) { lappend generics -generic $g }
    append tag _test
}
if {$ct} { lappend generics -generic CUT_THROUGH=1 }
set rundir  [file join $repo build $tag]
set reports [expr {[string match *_test $tag] ? [file join $rundir reports] \
                                              : [file join $repo docs reports $tag]}]
file mkdir $rundir $reports
cd $rundir

set sv [concat \
    [lsort [glob [file join $repo rtl *.sv]]] \
    [lsort [lsearch -all -inline -not [glob [file join $repo examples rx_stats *.sv]] \
        [expr {$example eq "rx_stats" ? "" : "*rx_stats_top.sv"}]]] \
    [lsort [glob [file join $repo examples rx_stats xilinx *.sv]]] \
    [lsort $srcs]]
read_verilog -sv $sv
foreach x $xdcs { read_xdc $x }
read_xdc -ref async_fifo [file join $repo constr async_fifo.xdc]
read_xdc -ref rx_reset_bridge [file join $repo constr rx_reset_bridge.xdc]

synth_design -top $top -part $part {*}$generics
set bb [get_cells -hier -quiet -filter {IS_BLACKBOX == 1}]
if {[llength $bb] > 0} { error "black boxes in the netlist: $bb" }
report_utilization -file [file join $rundir post_synth_util.rpt]

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -max_paths 20 -report_unconstrained -file [file join $reports timing_summary.rpt]
report_utilization                    -file [file join $reports utilization.rpt]
report_utilization -hierarchical      -file [file join $reports utilization_hier.rpt]
report_clock_interaction -delay_type min_max -file [file join $reports clock_interaction.rpt]
report_cdc -details                   -file [file join $reports cdc.rpt]
report_methodology                    -file [file join $reports methodology.rpt]
report_drc                            -file [file join $reports drc.rpt]
report_io                             -file [file join $reports io.rpt]
report_power                          -file [file join $reports power.rpt]

# Gate: timing met (setup and hold), no unsafe/unconstrained crossings.
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1 -nworst 1]]
set core_period [get_property PERIOD [get_clocks -of_objects [get_pins u_clk/u_bufg_core/O]]]
set summary [file join $reports summary.txt]
set fh [open $summary w]
puts $fh "vivado [version -short]  part $part  top $top"
puts $fh "core clock period ${core_period} ns"
puts $fh "WNS ${wns} ns  WHS ${whs} ns"
puts $fh "Fmax core (1/(period - WNS)), only if the core path is the worst: see timing_summary.rpt"
close $fh
puts "RESULT: WNS $wns ns, WHS $whs ns"

set cdc_bad [llength [get_cdc_violations -quiet -filter {SEVERITY == Critical}]]
if {$wns < 0 || $whs < 0} { error "timing not met (WNS $wns, WHS $whs): no bitstream" }
if {$cdc_bad > 0} { error "$cdc_bad critical CDC violation(s), see cdc.rpt: no bitstream" }

write_bitstream -force [file join $rundir $top.bit]
puts "BITSTREAM: [file join $rundir $top.bit]"
