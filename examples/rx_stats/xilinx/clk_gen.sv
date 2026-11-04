`default_nettype none
// clk_gen: Xilinx 7-series clocking for the Arty A7 example. The only file in this
// example that instantiates vendor primitives.
//   100 MHz in -> MMCM (VCO 1000 MHz) -> core 125 MHz, PHY reference 25 MHz.
//   The 25 MHz reference leaves the FPGA through an ODDR (clock forwarding), so the pin
//   is driven from an IOB flop, not from a clock net routed to fabric.
// locked_o is asynchronous to every output clock; it feeds reset_sync only.
module clk_gen (
    input  wire logic clk100_i,
    output logic      clk_core_o,     // 125 MHz
    output logic      clk_ref_o,      // 25 MHz, internal
    output logic      eth_ref_clk_o,  // 25 MHz, to the PHY pin
    output logic      locked_o
);
    localparam real CLKIN_PERIOD_NS = 10.0;
    localparam real VCO_MULT        = 10.0;  // 1000 MHz VCO (600-1200 MHz for -1)
    localparam real CORE_DIV        = 8.0;   // 125 MHz
    localparam int  REF_DIV         = 40;    // 25 MHz (802.3 clause 22 MII reference)

    logic clkfb, core_unbuf, ref_unbuf;

    // Unused MMCM outputs are left open on purpose.
    /* verilator lint_off PINCONNECTEMPTY */
    MMCME2_BASE #(
        .CLKIN1_PERIOD    (CLKIN_PERIOD_NS),
        .CLKFBOUT_MULT_F  (VCO_MULT),
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (CORE_DIV),
        .CLKOUT1_DIVIDE   (REF_DIV)
    ) u_mmcm (
        .CLKIN1    (clk100_i),
        .CLKFBIN   (clkfb),
        .CLKFBOUT  (clkfb),
        .CLKFBOUTB (),
        .CLKOUT0   (core_unbuf),
        .CLKOUT0B  (),
        .CLKOUT1   (ref_unbuf),
        .CLKOUT1B  (),
        .CLKOUT2   (),
        .CLKOUT2B  (),
        .CLKOUT3   (),
        .CLKOUT3B  (),
        .CLKOUT4   (),
        .CLKOUT5   (),
        .CLKOUT6   (),
        .LOCKED    (locked_o),
        .PWRDWN    (1'b0),
        .RST       (1'b0)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    BUFG u_bufg_core (.I(core_unbuf), .O(clk_core_o));
    BUFG u_bufg_ref  (.I(ref_unbuf),  .O(clk_ref_o));

    ODDR #(
        .DDR_CLK_EDGE ("OPPOSITE_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_oddr_ref (
        .Q  (eth_ref_clk_o),
        .C  (clk_ref_o),
        .CE (1'b1),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (1'b0),
        .S  (1'b0)
    );
endmodule
`default_nettype wire
