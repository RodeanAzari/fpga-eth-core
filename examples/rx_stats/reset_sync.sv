`default_nettype none
// reset_sync: brings a reset request into clk_i's domain. Assertion and release both
// pass through STAGES flops (synchronous on both edges), so the output is a clean
// synchronous, active-high reset. The input may come from any domain or a pin; it is a
// listed CDC (level, ASYNC_REG chain, false path to stage 0).
//
// The output only changes while clk_i runs: a domain whose clock is absent (e.g. the
// PHY's rx_clk while the PHY is in reset) leaves reset when its clock starts, after
// STAGES edges. Latency: STAGES cycles each way.
module reset_sync #(
    parameter int STAGES = 3
) (
    input  wire logic clk_i,
    input  wire logic rst_req_i,
    output logic      rst_o
);
    // Power-up value (FPGA configuration init) instead of a reset: this block is what
    // produces the reset, so it has none to use. Starts asserted.
    /* verilator lint_off PROCASSINIT */
    (* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_q = '1;
    /* verilator lint_on PROCASSINIT */

    always_ff @(posedge clk_i) sync_q <= {sync_q[STAGES-2:0], rst_req_i};

    assign rst_o = sync_q[STAGES-1];
endmodule
`default_nettype wire
