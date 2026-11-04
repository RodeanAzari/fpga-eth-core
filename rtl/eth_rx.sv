`default_nettype none
// eth_rx: MII receive path to good, FCS-stripped Ethernet frames in the core domain.
//
//   rx_clk domain                      | core (clk_i) domain
//   mii_rx -> rx_ovf_guard -> async_fifo -> eth_fcs_check -> frame_buffer -> m_*
//
// Output: AXI-Stream, one byte per beat, one Ethernet frame (dst MAC .. payload, no
// FCS) per tlast. Only frames with a good FCS, no PHY error, 64..MAX_FRAME+4 bytes on
// the wire, and no FIFO overflow are delivered (store-and-forward).
//
// Status (core domain, one-cycle pulses). Every frame that had an SFD gets exactly one:
//   frame_ok_o   delivered on m_*
//   crc_err_o    bad FCS
//   rx_err_o     rx_er during the frame, or it ended on an odd nibble
//   runt_o       fewer than 64 bytes on the wire (802.3 minimum)
//   oversize_o   more than MAX_FRAME bytes after the FCS
//   ovf_o        the async FIFO overflowed; ovf_frames_o (valid with ovf_o) is how many
//                frames were lost, saturating at 255. One pulse may cover several frames.
// So: frames with SFD = frame_ok + crc_err + rx_err + runt + oversize + sum(ovf_frames).
//
// fifo_level_o: async FIFO occupancy seen from the core side (under-reports the true
// level by up to the pointer-synchronizer delay, ~2-3 bytes at 25 MHz / 125 MHz).
// sfd_o: T0 event, a one-cycle pulse in the rx_clk domain; the consumer synchronizes it.
//
// Clocks and resets: mii_clk_i is the PHY's rx_clk; clk_i is the core clock (must be
// faster than 12.5 MHz byte rate, typically 100-125 MHz). mii_rst_i and rst_i are
// synchronous, active-high, each from a reset synchronizer in its own domain, fed by the
// same source (async_fifo requirement).
//
// Latency (last FCS nibble at the pins -> first frame byte valid on m_*):
//   2 rx_clk (mii_rx flush) + SYNC_STAGES+1 core (FIFO) + 1 (fcs check) + 2 (buffer)
//   + the 4-byte FCS window; see each sub-block's header.
module eth_rx #(
    parameter int FIFO_ADDR_W = 11,    // async FIFO depth 2**N bytes
    parameter int BUF_ADDR_W  = 12,    // frame buffer depth 2**N bytes
    parameter int MAX_FRAME   = 1518,  // max bytes after FCS strip
    parameter int MIN_FRAME   = 64     // min bytes on the wire, FCS included
) (
    // MII (rx_clk domain)
    input  wire logic       mii_clk_i,
    input  wire logic       mii_rst_i,
    input  wire logic [3:0] mii_rxd_i,
    input  wire logic       mii_rx_dv_i,
    input  wire logic       mii_rx_er_i,
    output logic            sfd_o,
    // core domain
    input  wire logic       clk_i,
    input  wire logic       rst_i,
    output logic [7:0]      m_tdata_o,
    output logic            m_tvalid_o,
    input  wire logic       m_tready_i,
    output logic            m_tlast_o,
    output logic            frame_ok_o,
    output logic            crc_err_o,
    output logic            rx_err_o,
    output logic            runt_o,
    output logic            oversize_o,
    output logic            ovf_o,
    output logic [7:0]      ovf_frames_o,
    output logic [FIFO_ADDR_W:0] fifo_level_o
);
    localparam int USER_OVF_BIT = 1;  // rx_ovf_guard: tuser[1] marks an abort beat

    // ---------------------------------------------------------------- rx_clk domain
    logic [7:0] mii_tdata;
    logic       mii_tvalid, mii_tlast, mii_tuser;

    mii_rx u_mii_rx (
        .clk_i       (mii_clk_i),
        .rst_i       (mii_rst_i),
        .mii_rxd_i   (mii_rxd_i),
        .mii_rx_dv_i (mii_rx_dv_i),
        .mii_rx_er_i (mii_rx_er_i),
        .m_tdata_o   (mii_tdata),
        .m_tvalid_o  (mii_tvalid),
        .m_tlast_o   (mii_tlast),
        .m_tuser_o   (mii_tuser),
        .sfd_o       (sfd_o)
    );

    logic [7:0] g_tdata;
    logic       g_tvalid, g_tready, g_tlast;
    logic [1:0] g_tuser;

    rx_ovf_guard u_guard (
        .clk_i      (mii_clk_i),
        .rst_i      (mii_rst_i),
        .s_tdata_i  (mii_tdata),
        .s_tvalid_i (mii_tvalid),
        .s_tlast_i  (mii_tlast),
        .s_tuser_i  (mii_tuser),
        .m_tdata_o  (g_tdata),
        .m_tvalid_o (g_tvalid),
        .m_tready_i (g_tready),
        .m_tlast_o  (g_tlast),
        .m_tuser_o  (g_tuser)
    );

    // -------------------------------------------------------------- clock crossing
    logic [10:0]          f_word;   // {tuser[1:0], tlast, tdata}
    logic                 f_tvalid, f_tready;
    logic [FIFO_ADDR_W:0] f_wr_level_unused;

    async_fifo #(
        .DATA_W (11),
        .ADDR_W (FIFO_ADDR_W)
    ) u_fifo (
        .wr_clk_i   (mii_clk_i),
        .wr_rst_i   (mii_rst_i),
        .s_tdata_i  ({g_tuser, g_tlast, g_tdata}),
        .s_tvalid_i (g_tvalid),
        .s_tready_o (g_tready),
        .wr_level_o (f_wr_level_unused),
        .rd_clk_i   (clk_i),
        .rd_rst_i   (rst_i),
        .m_tdata_o  (f_word),
        .m_tvalid_o (f_tvalid),
        .m_tready_i (f_tready),
        .rd_level_o (fifo_level_o)
    );

    // ------------------------------------------------------------------ core domain
    logic [7:0] c_tdata;
    logic       c_tvalid, c_tready, c_tlast, c_tuser;
    logic       fcs_ok_unused, fcs_rx_err;
    logic       ovf_q;
    logic [7:0] ovf_frames_q;

    eth_fcs_check #(
        .MIN_FRAME (MIN_FRAME)
    ) u_fcs (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .s_tdata_i  (f_word[7:0]),
        .s_tvalid_i (f_tvalid),
        .s_tready_o (f_tready),
        .s_tlast_i  (f_word[8]),
        .s_tuser_i  (|f_word[10:9]),
        .m_tdata_o  (c_tdata),
        .m_tvalid_o (c_tvalid),
        .m_tready_i (c_tready),
        .m_tlast_o  (c_tlast),
        .m_tuser_o  (c_tuser),
        .frame_ok_o (fcs_ok_unused),
        .crc_err_o  (crc_err_o),
        .rx_err_o   (fcs_rx_err),
        .runt_o     (runt_o)
    );

    // An overflow-terminated frame reaches the FCS check with tuser set, so it reports
    // rx_err one cycle after its tlast is accepted. Re-label that pulse as ovf.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ovf_q <= 1'b0;
        end else begin
            ovf_q <= f_tvalid && f_tready && f_word[8] && f_word[9 + USER_OVF_BIT];
        end
        ovf_frames_q <= f_word[7:0];
    end

    always_comb begin
        ovf_o        = ovf_q;
        ovf_frames_o = ovf_frames_q;
        rx_err_o     = fcs_rx_err && !ovf_q;
    end

    frame_buffer #(
        .ADDR_W    (BUF_ADDR_W),
        .MAX_FRAME (MAX_FRAME)
    ) u_buf (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .s_tdata_i  (c_tdata),
        .s_tvalid_i (c_tvalid),
        .s_tready_o (c_tready),
        .s_tlast_i  (c_tlast),
        .s_tuser_i  (c_tuser),
        .m_tdata_o  (m_tdata_o),
        .m_tvalid_o (m_tvalid_o),
        .m_tready_i (m_tready_i),
        .m_tlast_o  (m_tlast_o),
        .frame_ok_o (frame_ok_o),
        .oversize_o (oversize_o)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i) assert (!(ovf_q && !fcs_rx_err));  // the re-label lines up
    end
`endif
endmodule
`default_nettype wire
