`default_nettype none
// mdio_link_mon: polls the PHY's link status over MDIO (IEEE 802.3 clause 22) and
// reports a debounced link_up_o, for holding the MAC in reset while there is no link.
//
// Every POLL_CYCLES it reads BMSR (register 1) of PHY address PHY_ADDR:
//   32 x '1' preamble, ST=01, OP=10 (read), PHYAD, REGAD, TA (PHY drives the 2nd bit 0),
//   16 data bits, MSB first. 64 MDC periods per read.
// BMSR bit 2 (link status) is latched-low in the PHY, so the first read after any link
// loss returns 0, even if the link has already come back.
//
// Outputs (core domain, registered):
//   link_up_o  1 after LINK_UP_READS consecutive reads with link status 1 and a PHY that
//              answered; 0 at once on any read with link 0 or no answer, and in reset.
//              With the default 10 ms poll, link_up_o rises 10-20 ms after the PHY sets
//              its link bit, which gives RX_CLK time to settle on the recovered clock.
//   phy_ok_o   the last read was answered: TA's second bit was 0. With no PHY at
//              PHY_ADDR the pulled-up line reads all ones, which would otherwise look like
//              link up; a wrong address therefore shows as phy_ok_o = 0, link_up_o = 0.
//
// MDIO timing: mdc_o has period 2*HALF_CYCLES. This block changes mdio_o at the start of
// MDC low (HALF_CYCLES of setup before the PHY samples on the rising edge) and samples
// mdio_i at the end of MDC low, through a 2-flop synchronizer, i.e. (2*HALF_CYCLES - 2)
// clk_i cycles after the previous rising edge. That must exceed the PHY's output delay
// (DP83848: 300 ns max), so with clk 100 MHz and MDC 2.5 MHz it is 380 ns.
// The pad is a tristate in the top level: eth_mdio = mdio_oe_o ? mdio_o : 'z.
//
// CDC: mdio_i is asynchronous; it crosses through the two ASYNC_REG flops below. It is a
// slow serial line sampled hundreds of ns after it changes, so a single-bit synchronizer
// is sufficient.
//
// Latency: link_up_o follows the PHY's link bit within LINK_UP_READS * POLL_CYCLES +
// 64 * 2 * HALF_CYCLES clk_i cycles (rising), POLL_CYCLES + 64 * 2 * HALF_CYCLES (falling).
// Reset: synchronous, active-high. The first read starts right after reset.
module mdio_link_mon #(
    parameter int         CLK_HZ        = 100_000_000,
    parameter int         MDC_HZ        = 2_500_000,      // 802.3 clause 22 max 2.5 MHz
    parameter int         POLL_CYCLES   = CLK_HZ / 100,   // 10 ms between read starts
    parameter int         LINK_UP_READS = 2,
    parameter logic [4:0] PHY_ADDR      = 5'd1            // Arty A7: DP83848J strapped to 1
) (
    input  wire logic clk_i,
    input  wire logic rst_i,
    output logic      mdc_o,
    output logic      mdio_o,
    output logic      mdio_oe_o,
    input  wire logic mdio_i,
    output logic      link_up_o,
    output logic      phy_ok_o
);
    localparam int         HALF_CYCLES = CLK_HZ / (2 * MDC_HZ);
    localparam int         FRAME_BITS  = 64;
    localparam int         DRIVE_BITS  = 46;           // preamble .. REGAD; then TA
    localparam int         TA2_BIT     = 47;           // PHY drives 0 here
    localparam int         DATA_BIT0   = 48;           // first (MSB) data bit
    localparam logic [4:0] REG_BMSR    = 5'd1;         // 802.3 22.2.4.2
    localparam int         BMSR_LINK   = 2;            // 802.3 22.2.4.2.13, latched low
    // ST=01, OP=10 (read), PHYAD, REGAD: the 14 driven bits after the preamble.
    localparam logic [13:0] HEADER     = {2'b01, 2'b10, PHY_ADDR, REG_BMSR};
    localparam int         HALF_W      = $clog2(HALF_CYCLES + 1);
    localparam int         POLL_W      = $clog2(POLL_CYCLES + 1);
    localparam int         UP_W        = $clog2(LINK_UP_READS + 1);

    if (HALF_CYCLES < 2) begin : g_bad_mdc
        $error("mdio_link_mon: CLK_HZ must be >= 4 * MDC_HZ");
    end
    if (POLL_CYCLES < FRAME_BITS * 2 * HALF_CYCLES) begin : g_bad_poll
        $error("mdio_link_mon: POLL_CYCLES shorter than one MDIO read");
    end

    (* ASYNC_REG = "TRUE" *) logic [1:0] mdio_sync_q;
    logic [POLL_W-1:0] poll_q;       // cycles since this read started
    logic [5:0]        bit_q;        // 0..63 during a read
    logic              busy_q, high_q;
    logic [HALF_W-1:0] half_q;
    logic [15:0]       data_q;
    logic              ta_ok_q;
    logic [UP_W-1:0]   up_cnt_q;
    logic              half_end, bit_end;

    // Value this block drives in MDIO bit b (b < DRIVE_BITS): preamble ones, then HEADER.
    function automatic logic drive_val(input int b);
        drive_val = (b < 32) ? 1'b1 : HEADER[13 - (b - 32)];
    endfunction

    always_comb begin
        half_end = half_q == HALF_W'(HALF_CYCLES - 1);
        bit_end  = half_end && high_q;
    end

    always_ff @(posedge clk_i) begin
        mdio_sync_q <= {mdio_sync_q[0], mdio_i};
        if (busy_q && !high_q && half_end) begin                      // end of MDC low
            if (int'(bit_q) == TA2_BIT)  ta_ok_q <= !mdio_sync_q[1];
            if (int'(bit_q) >= DATA_BIT0) data_q <= {data_q[14:0], mdio_sync_q[1]};
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            poll_q    <= '0;
            busy_q    <= 1'b1;
            bit_q     <= '0;
            high_q    <= 1'b0;
            half_q    <= '0;
            mdc_o     <= 1'b0;
            mdio_o    <= 1'b1;
            mdio_oe_o <= 1'b1;
            up_cnt_q  <= '0;
            link_up_o <= 1'b0;
            phy_ok_o  <= 1'b0;
        end else begin
            poll_q <= (poll_q == POLL_W'(POLL_CYCLES - 1)) ? '0 : poll_q + POLL_W'(1);
            if (busy_q) begin
                half_q <= half_end ? '0 : half_q + HALF_W'(1);
                if (half_end) begin
                    high_q <= !high_q;
                    mdc_o  <= !high_q;                                // rise after low
                end
                if (bit_end) begin
                    if (bit_q == 6'(FRAME_BITS - 1)) begin
                        busy_q <= 1'b0;
                    end else begin
                        bit_q     <= bit_q + 6'd1;
                        mdio_oe_o <= int'(bit_q) + 1 < DRIVE_BITS;
                        mdio_o    <= drive_val(int'(bit_q) + 1);
                    end
                end
            end else begin
                if (poll_q == '0) begin                               // start the next read
                    busy_q    <= 1'b1;
                    bit_q     <= '0;
                    high_q    <= 1'b0;
                    half_q    <= '0;
                    mdio_o    <= 1'b1;
                    mdio_oe_o <= 1'b1;
                end
            end
            // Verdict one cycle after the last bit (data_q holds all 16 bits by then).
            if (busy_q && bit_end && bit_q == 6'(FRAME_BITS - 1)) begin
                phy_ok_o <= ta_ok_q;
                if (ta_ok_q && data_q[BMSR_LINK]) begin
                    if (up_cnt_q != UP_W'(LINK_UP_READS)) up_cnt_q <= up_cnt_q + UP_W'(1);
                    link_up_o <= up_cnt_q + UP_W'(1) >= UP_W'(LINK_UP_READS);
                end else begin
                    up_cnt_q  <= '0;
                    link_up_o <= 1'b0;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            assert (!(mdio_oe_o && int'(bit_q) >= DRIVE_BITS));  // never fight the PHY
            assert (!link_up_o || phy_ok_o);
        end
    end
`endif
endmodule
`default_nettype wire
