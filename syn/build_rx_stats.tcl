# Batch build of examples/rx_stats for the Arty A7-100T:
#   vivado -mode batch -source syn/build_rx_stats.tcl [-tclargs <part>]
# Non-project flow; nothing but build/ is written, except the reports copied to
# docs/reports/rx_stats/ for committing. The bitstream is written only if every timing
# path meets and no clock-domain crossing is unconstrained.

set expected_vivado 2025.2
if {[version -short] ne $expected_vivado} {
    puts "WARNING: Vivado [version -short], pinned version is $expected_vivado (docs: README)"
}

set part [lindex $argv 0]
if {$part eq ""} { set part xc7a100tcsg324-1 }
set top     rx_stats_top
set repo    [file normalize [file join [file dirname [info script]] ..]]
set rundir  [file join $repo build rx_stats]
set reports [file join $repo docs reports rx_stats]
file mkdir $rundir $reports
cd $rundir

set sv [concat \
    [lsort [glob [file join $repo rtl *.sv]]] \
    [lsort [glob [file join $repo examples rx_stats *.sv]]] \
    [lsort [glob [file join $repo examples rx_stats xilinx *.sv]]]]
read_verilog -sv $sv
read_xdc [file join $repo constr arty_a7_100_pins.xdc]
read_xdc [file join $repo constr rx_stats_timing.xdc]
read_xdc -ref async_fifo [file join $repo constr async_fifo.xdc]

synth_design -top $top -part $part
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
