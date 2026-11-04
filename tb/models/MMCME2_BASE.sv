// Lint/sim stand-in for the Xilinx MMCME2_BASE primitive (never synthesized: Vivado
// uses its own). Outputs are NOT frequency-accurate: CLKOUT* follow CLKIN1. Only the
// ports used by examples/ are modelled.
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
module MMCME2_BASE #(
    parameter real CLKIN1_PERIOD    = 10.0,
    parameter real CLKFBOUT_MULT_F  = 5.0,
    parameter int  DIVCLK_DIVIDE    = 1,
    parameter real CLKOUT0_DIVIDE_F = 1.0,
    parameter int  CLKOUT1_DIVIDE   = 1
) (
    input  wire CLKIN1, CLKFBIN, PWRDWN, RST,
    output wire CLKFBOUT, CLKFBOUTB, CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B,
    output wire CLKOUT2, CLKOUT2B, CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6, LOCKED
);
    assign {CLKFBOUT, CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6}
        = {8{CLKIN1}};
    assign {CLKFBOUTB, CLKOUT0B, CLKOUT1B, CLKOUT2B, CLKOUT3B} = {5{~CLKIN1}};
    assign LOCKED = ~RST;
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
