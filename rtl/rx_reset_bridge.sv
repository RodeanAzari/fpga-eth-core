`default_nettype none
// rx_reset_bridge: eth_rx's resets, safe whatever the PHY's rx_clk does (fpga-coord 0005).
//
// async_fifo needs its write side (rx_clk) in reset whenever its read side (core) is
// reset. A reset synchronizer on rx_clk only moves while rx_clk runs, so a core reset
// during a stopped rx_clk used to reset the read pointer alone: the FIFO then showed
// words that were never written (old frames again, levels above the depth).
// Here the core side asks and the rx side acknowledges:
//   req_q (core)    set by rst_i; held until rst_i is low and the ack is seen, so a
//                   request made while rx_clk is stopped completes when it returns.
//   mii_rst_o (rx)  req_q through SYNC_STAGES rx_clk flops, OR mii_rst_i (optional
//                   external rx reset, tie 0 if unused); power-up asserted.
//   ack (core)      mii_rst_o through SYNC_STAGES core flops: the rx side is in reset.
//   fifo_rd_rst_o   = ack: the FIFO read side resets only inside the write side's reset.
//   core_rst_o      = rst_i | req_q | ack: the rest of eth_rx's core side.
// Release: rst_i low and ack seen -> req_q falls -> mii_rst_o falls SYNC_STAGES rx_clk
// later -> ack falls SYNC_STAGES core cycles after that: the read side leaves reset last.
// While rx_clk is stopped, core_rst_o stays high after a reset request (in_reset).
// Latency: rst_i -> core_rst_o 0 cycles; rst_i -> fifo_rd_rst_o SYNC_STAGES rx_clk +
// SYNC_STAGES core; release SYNC_STAGES (core) + SYNC_STAGES (rx) + SYNC_STAGES (core).
// CDC: req_q and mii_rst_o are levels into ASYNC_REG chains (listed in constr/).
module rx_reset_bridge #(
    parameter int SYNC_STAGES = 3
) (
    input  wire logic clk_i,
    input  wire logic rst_i,
    input  wire logic mii_clk_i,
    input  wire logic mii_rst_i,
    output logic      mii_rst_o,
    output logic      fifo_rd_rst_o,
    output logic      core_rst_o
);
    logic req_q, ack;

    // rx side: no reset of its own (it makes the rx reset); power-up asserted, as
    // examples/rx_stats/reset_sync.sv.
    /* verilator lint_off PROCASSINIT */
    (* ASYNC_REG = "TRUE" *) logic [SYNC_STAGES-1:0] rx_sync_q = '1;
    /* verilator lint_on PROCASSINIT */
    always_ff @(posedge mii_clk_i) rx_sync_q <= {rx_sync_q[SYNC_STAGES-2:0], req_q};
    assign mii_rst_o = rx_sync_q[SYNC_STAGES-1] || mii_rst_i;

    // core side: the ack synchronizer is not reset (a reset would hide the ack while
    // rst_i is high); power-up 0, so a power-up rst_i must see the rx side first.
    /* verilator lint_off PROCASSINIT */
    (* ASYNC_REG = "TRUE" *) logic [SYNC_STAGES-1:0] ack_sync_q = '0;
    /* verilator lint_on PROCASSINIT */
    always_ff @(posedge clk_i) ack_sync_q <= {ack_sync_q[SYNC_STAGES-2:0], mii_rst_o};
    assign ack = ack_sync_q[SYNC_STAGES-1];

    always_ff @(posedge clk_i) begin
        if (rst_i)    req_q <= 1'b1;
        else if (ack) req_q <= 1'b0;
    end

    assign fifo_rd_rst_o = ack;
    assign core_rst_o    = rst_i || req_q || ack;

`ifndef SYNTHESIS
    // the FIFO read side never resets outside a request or an rx reset
    always_ff @(posedge clk_i) begin
        if (fifo_rd_rst_o) assert (core_rst_o);
    end
`endif
endmodule
`default_nettype wire
