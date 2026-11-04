`default_nettype none
// mii_rx: MII receive (100BASE-TX, IEEE 802.3 clause 22) -> byte stream.
//
// MII boundary (all in the PHY's rx_clk domain, 25 MHz at 100 Mbps, 2.5 MHz at 10 Mbps):
//   mii_rxd_i[3:0]  data nibble, sampled on the rising edge of rx_clk
//   mii_rx_dv_i     high from the first preamble nibble to the last FCS nibble
//   mii_rx_er_i     symbol error while rx_dv is high (ignored while rx_dv is low)
//   Nibble order:   the LOW nibble of each byte arrives first (clause 22.2.3).
//   Framing:        preamble nibbles 0x5 (the PHY may drop some), then SFD byte 0xD5,
//                   i.e. nibble 0x5 then nibble 0xD.
// Nothing PHY-specific is assumed beyond these signals.
//
// Output: AXI-Stream source, one byte per beat, no tready (the MII cannot be stalled;
// the caller writes it into an async FIFO and counts overflow). The stream carries every
// byte after the SFD, FCS included. tlast marks the last byte; tuser on the tlast beat
// is 1 if rx_er was seen during the frame or the frame ended on an odd nibble
// (alignment error). tuser is 0 on all other beats.
//
// sfd_o pulses for one cycle when the SFD is recognised (the T0 event).
//
// Not reported: a carrier event with no valid SFD (false carrier, bad preamble) emits
// nothing. A frame that ends before its first full byte emits nothing.
//
// Latency (rx_clk cycles, from the nibble at the pins):
//   SFD nibble -> sfd_o:            2 (input register + sfd register)
//   high nibble of byte k -> beat k: 2, when byte k+1 completes; the last byte is
//   emitted 2 cycles after rx_dv falls. Byte k is held back until the next byte (or
//   the end of frame) arrives, because tlast can only be known at that point.
//
// Reset: synchronous, active-high, rx_clk domain.
module mii_rx (
    input  wire logic       clk_i,
    input  wire logic       rst_i,
    // MII
    input  wire logic [3:0] mii_rxd_i,
    input  wire logic       mii_rx_dv_i,
    input  wire logic       mii_rx_er_i,
    // byte stream
    output logic [7:0]      m_tdata_o,
    output logic            m_tvalid_o,
    output logic            m_tlast_o,
    output logic            m_tuser_o,
    // T0 event
    output logic            sfd_o
);
    localparam logic [3:0] PREAMBLE_NIB = 4'h5;  // 802.3 clause 3.2.1: 0x55 bytes
    localparam logic [3:0] SFD_HI_NIB   = 4'hD;  // 802.3 clause 3.2.2: SFD 0xD5, low nibble 5 first

    // Input register (packs into IOB flops).
    logic [3:0] rxd_q;
    logic       dv_q, er_q;
    always_ff @(posedge clk_i) begin
        rxd_q <= mii_rxd_i;
        dv_q  <= mii_rx_dv_i;
        er_q  <= mii_rx_er_i;
    end

    logic       in_frame_q;   // past the SFD
    logic       saw_pre_q;    // previous nibble was a preamble nibble
    logic       odd_q;        // low nibble captured, waiting for the high one
    logic       have_hold_q;  // hold_q contains a byte not yet emitted
    logic       err_q;        // rx_er seen in this frame
    logic [3:0] lo_q;
    logic [7:0] hold_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            in_frame_q  <= 1'b0;
            saw_pre_q   <= 1'b0;
            odd_q       <= 1'b0;
            have_hold_q <= 1'b0;
            err_q       <= 1'b0;
            m_tvalid_o  <= 1'b0;
            m_tlast_o   <= 1'b0;
            m_tuser_o   <= 1'b0;
            sfd_o       <= 1'b0;
        end else begin
            m_tvalid_o <= 1'b0;
            m_tlast_o  <= 1'b0;
            m_tuser_o  <= 1'b0;
            sfd_o      <= 1'b0;

            if (!in_frame_q) begin
                // Hunt for 0x5 followed by 0xD while rx_dv is high.
                saw_pre_q <= dv_q && (rxd_q == PREAMBLE_NIB);
                if (dv_q && saw_pre_q && rxd_q == SFD_HI_NIB) begin
                    in_frame_q  <= 1'b1;
                    sfd_o       <= 1'b1;
                    odd_q       <= 1'b0;
                    have_hold_q <= 1'b0;
                    err_q       <= 1'b0;
                end
            end else if (dv_q) begin
                err_q <= err_q | er_q;
                if (!odd_q) begin
                    lo_q  <= rxd_q;
                    odd_q <= 1'b1;
                end else begin
                    odd_q       <= 1'b0;
                    hold_q      <= {rxd_q, lo_q};
                    have_hold_q <= 1'b1;
                    if (have_hold_q) begin
                        m_tdata_o  <= hold_q;
                        m_tvalid_o <= 1'b1;
                    end
                end
            end else begin
                // rx_dv fell: flush the held byte as the last one.
                in_frame_q <= 1'b0;
                saw_pre_q  <= 1'b0;
                if (have_hold_q) begin
                    m_tdata_o  <= hold_q;
                    m_tvalid_o <= 1'b1;
                    m_tlast_o  <= 1'b1;
                    m_tuser_o  <= err_q | odd_q;
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            assert (!(m_tuser_o && !m_tlast_o));  // tuser only on the last beat
        end
    end
`endif
endmodule
`default_nettype wire
