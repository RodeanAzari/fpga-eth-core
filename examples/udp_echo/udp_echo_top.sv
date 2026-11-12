`default_nettype none
// udp_echo_top: fpga-eth-core transmit example for the Digilent Arty A7-100T, and the
// hardware harness for the eth-core-v0.2 gate. It is not the order book: every UDP
// datagram received for one group/port is sent straight back, payload unchanged, to
// the sender's MAC/IP/port as learned by udp_rx (no ARP). The host checks each echo.
//
//   MII RX -> eth_rx -> udp_rx -> udp_tx -> eth_tx -> MII TX
//                          `-- src_mac/src_ip/src_port --'  (reply address)
//
// Reply: source MAC/IP = OWN_MAC/OWN_IP, source port = UDP_PORT, destination = the
// datagram's sender. Truncated datagrams (udp_rx m_tuser) are discarded by udp_tx.
//
// UART line, once per REPORT_CYCLES, 115200 8N1 (see stats_report):
//   RX <f0> <f1> ... <f14>     each field 8 hex digits, cumulative since reset:
//    0 uptime_s       1 eth_ok        2 crc_err      3 rx_err      4 runt
//    5 oversize       6 ovf_lost      7 udp_ok       8 udp_filtered
//    9 ip_csum_err   10 udp_malformed
//   11 tx_sent        echo frames handed to the MAC (udp_tx sent_o)
//   12 tx_oversize   13 tx_underrun   (both must stay 0)
//   14 fifo_hwm       RX async FIFO high-water mark, bytes (core-side view)
//
// LEDs: led[0] 1 Hz heartbeat; led[1] echo activity (stretched); led[2] sticky: any of
// 2,3,6,9,10,12,13 non-zero; led[3] MAC out of reset.
//
// Start-up and reset as rx_stats (PHY reset, then the MAC in all three domains).
// MDIO: mdio_link_mon polls the PHY's link status; the MAC is held in reset while
// the link is down and re-enters reset on link loss (fpga-coord request 0005).
// Top-level ports use the Digilent master-XDC names. Shared helpers (clk_gen,
// reset_sync, stats_report, uart_tx) come from examples/rx_stats.
module udp_echo_top #(
    parameter int          CLK_HZ           = 125_000_000,
    parameter int          BAUD             = 115_200,
    parameter int          REPORT_CYCLES    = CLK_HZ,             // 1 s
    parameter int          PHY_RST_CYCLES   = CLK_HZ / 100,       // 10 ms
    parameter int          MAC_START_CYCLES = CLK_HZ / 5,         // 200 ms
    parameter int          MDC_HZ           = 2_500_000,          // MDIO clock
    parameter int          LINK_POLL_CYCLES = CLK_HZ / 100,       // 10 ms
    parameter logic [47:0] OWN_MAC          = 48'h02_00_0A_0B_0C_0D,
    parameter logic [31:0] OWN_IP           = 32'hC0_A8_0A_02,    // 192.168.10.2
    parameter logic [31:0] GROUP_IP         = 32'hEF_01_01_01,    // 239.1.1.1
    parameter logic [15:0] UDP_PORT         = 16'd26400
) (
    input  wire logic       CLK100MHZ,
    input  wire logic       ck_rst,        // active low
    output logic [3:0]      led,
    output logic            uart_rxd_out,  // FPGA -> host
    // Ethernet PHY (TI DP83848J, MII)
    output logic            eth_ref_clk,
    output logic            eth_rstn,
    input  wire logic       eth_rx_clk,
    input  wire logic       eth_rx_dv,
    input  wire logic [3:0] eth_rxd,
    input  wire logic       eth_rxerr,
    input  wire logic       eth_tx_clk,
    output logic            eth_tx_en,
    output logic [3:0]      eth_txd,
    output logic            eth_mdc,
    inout  wire logic       eth_mdio
);
    localparam int N_FIELDS = 15;
    localparam int FIFO_AW  = 11;
    localparam int START_W  = $clog2(MAC_START_CYCLES + 1);
    localparam int REPORT_W = $clog2(REPORT_CYCLES);
    localparam int LED_HOLD = CLK_HZ / 30;  // ~33 ms activity flash
    localparam int LED_W    = $clog2(LED_HOLD + 1);

    // --------------------------------------------------------- clocks and resets
    logic clk, clk_ref_unused, locked, rst;

    clk_gen u_clk (
        .clk100_i      (CLK100MHZ),
        .clk_core_o    (clk),
        .clk_ref_o     (clk_ref_unused),
        .eth_ref_clk_o (eth_ref_clk),
        .locked_o      (locked)
    );

    reset_sync u_rst_core (
        .clk_i     (clk),
        .rst_req_i (!ck_rst || !locked),
        .rst_o     (rst)
    );

    logic [START_W-1:0] start_q;
    logic               link_up, phy_ok_unused, mdio_o, mdio_oe;
    logic               mac_rst_q, mii_tx_rst;

    always_ff @(posedge clk) begin
        if (rst) begin
            start_q   <= '0;
            eth_rstn  <= 1'b0;
            mac_rst_q <= 1'b1;
        end else begin
            if (start_q != START_W'(MAC_START_CYCLES)) start_q <= start_q + START_W'(1);
            eth_rstn  <= start_q >= START_W'(PHY_RST_CYCLES);
            mac_rst_q <= start_q != START_W'(MAC_START_CYCLES) || !link_up;
        end
    end

    reset_sync u_rst_mii_tx (
        .clk_i     (eth_tx_clk),
        .rst_req_i (mac_rst_q),
        .rst_o     (mii_tx_rst)
    );

    mdio_link_mon #(
        .CLK_HZ      (CLK_HZ),
        .MDC_HZ      (MDC_HZ),
        .POLL_CYCLES (LINK_POLL_CYCLES)
    ) u_link (
        .clk_i     (clk),
        .rst_i     (rst),
        .mdc_o     (eth_mdc),
        .mdio_o    (mdio_o),
        .mdio_oe_o (mdio_oe),
        .mdio_i    (eth_mdio),
        .link_up_o (link_up),
        .phy_ok_o  (phy_ok_unused)
    );
    assign eth_mdio = mdio_oe ? mdio_o : 1'bz;

    // ------------------------------------------------------------ receive path
    logic [7:0]       f_tdata;
    logic             f_tvalid, f_tready, f_tlast;
    logic             e_ok, e_crc, e_rxerr, e_runt, e_over, e_ovf;
    logic [7:0]       e_ovf_frames;
    logic [FIFO_AW:0] fifo_level;
    logic             sfd_unused, tuser_unused, emitted_unused, eth_in_reset_unused;  // store-and-forward

    eth_rx #(
        .FIFO_ADDR_W (FIFO_AW)
    ) u_eth_rx (
        .mii_clk_i    (eth_rx_clk),
        .mii_rst_i    (1'b0),  // eth_rx makes its rx reset from rst_i (0005)
        .mii_rxd_i    (eth_rxd),
        .mii_rx_dv_i  (eth_rx_dv),
        .mii_rx_er_i  (eth_rxerr),
        .sfd_o        (sfd_unused),
        .clk_i        (clk),
        .rst_i        (mac_rst_q),
        .in_reset_o   (eth_in_reset_unused),
        .m_tdata_o    (f_tdata),
        .m_tvalid_o   (f_tvalid),
        .m_tready_i   (f_tready),
        .m_tlast_o    (f_tlast),
        .m_tuser_o    (tuser_unused),
        .frame_ok_o   (e_ok),
        .crc_err_o    (e_crc),
        .rx_err_o     (e_rxerr),
        .runt_o       (e_runt),
        .oversize_o   (e_over),
        .ovf_o        (e_ovf),
        .ovf_frames_o (e_ovf_frames),
        .emitted_o    (emitted_unused),
        .fifo_level_o (fifo_level)
    );

    logic [7:0]  u_tdata;
    logic        u_tvalid, u_tready, u_tlast, u_tuser;
    logic        u_ok, u_filt, u_csum, u_mal;
    logic [47:0] peer_mac;
    logic [31:0] peer_ip;
    logic [15:0] peer_port, dst_port_unused;

    udp_rx u_udp_rx (
        .clk_i         (clk),
        .rst_i         (mac_rst_q),
        .cfg_mac_i     (OWN_MAC),
        .cfg_ip_i      (GROUP_IP),
        .cfg_port_i    (UDP_PORT),
        .s_tdata_i     (f_tdata),
        .s_tvalid_i    (f_tvalid),
        .s_tready_o    (f_tready),
        .s_tlast_i     (f_tlast),
        .m_tdata_o     (u_tdata),
        .m_tvalid_o    (u_tvalid),
        .m_tready_i    (u_tready),
        .m_tlast_o     (u_tlast),
        .m_tuser_o     (u_tuser),
        .src_mac_o     (peer_mac),
        .src_ip_o      (peer_ip),
        .src_port_o    (peer_port),
        .dst_port_o    (dst_port_unused),
        .ok_o          (u_ok),
        .filtered_o    (u_filt),
        .ip_csum_err_o (u_csum),
        .malformed_o   (u_mal)
    );

    // ----------------------------------------------------------- transmit path
    logic [7:0] t_tdata;
    logic       t_tvalid, t_tready, t_tlast;
    logic       t_sent, t_over, t_underrun;

    udp_tx u_udp_tx (
        .clk_i      (clk),
        .rst_i      (mac_rst_q),
        .cfg_mac_i  (OWN_MAC),
        .cfg_ip_i   (OWN_IP),
        .s_tdata_i  (u_tdata),
        .s_tvalid_i (u_tvalid),
        .s_tready_o (u_tready),
        .s_tlast_i  (u_tlast),
        .s_tuser_i  (u_tuser),
        .dst_mac_i  (peer_mac),
        .dst_ip_i   (peer_ip),
        .dst_port_i (peer_port),
        .src_port_i (UDP_PORT),
        .m_tdata_o  (t_tdata),
        .m_tvalid_o (t_tvalid),
        .m_tready_i (t_tready),
        .m_tlast_o  (t_tlast),
        .sent_o     (t_sent),
        .oversize_o (t_over)
    );

    eth_tx u_eth_tx (
        .clk_i       (clk),
        .rst_i       (mac_rst_q),
        .s_tdata_i   (t_tdata),
        .s_tvalid_i  (t_tvalid),
        .s_tready_o  (t_tready),
        .s_tlast_i   (t_tlast),
        .underrun_o  (t_underrun),
        .mii_clk_i   (eth_tx_clk),
        .mii_rst_i   (mii_tx_rst),
        .mii_txd_o   (eth_txd),
        .mii_tx_en_o (eth_tx_en)
    );

    // --------------------------------------------------------------- counters
    logic [31:0]         cnt_q [N_FIELDS];
    logic [REPORT_W-1:0] tick_cnt_q;
    logic                tick;
    logic [LED_W-1:0]    led_hold_q;

    always_ff @(posedge clk) begin
        if (mac_rst_q) begin
            for (int i = 0; i < N_FIELDS; i++) cnt_q[i] <= '0;
            tick_cnt_q <= '0;
            led_hold_q <= '0;
        end else begin
            tick_cnt_q <= tick ? '0 : tick_cnt_q + REPORT_W'(1);
            if (tick) cnt_q[0] <= cnt_q[0] + 32'd1;
            cnt_q[1]  <= cnt_q[1]  + 32'(e_ok);
            cnt_q[2]  <= cnt_q[2]  + 32'(e_crc);
            cnt_q[3]  <= cnt_q[3]  + 32'(e_rxerr);
            cnt_q[4]  <= cnt_q[4]  + 32'(e_runt);
            cnt_q[5]  <= cnt_q[5]  + 32'(e_over);
            if (e_ovf) cnt_q[6] <= cnt_q[6] + 32'(e_ovf_frames);
            cnt_q[7]  <= cnt_q[7]  + 32'(u_ok);
            cnt_q[8]  <= cnt_q[8]  + 32'(u_filt);
            cnt_q[9]  <= cnt_q[9]  + 32'(u_csum);
            cnt_q[10] <= cnt_q[10] + 32'(u_mal);
            cnt_q[11] <= cnt_q[11] + 32'(t_sent);
            cnt_q[12] <= cnt_q[12] + 32'(t_over);
            cnt_q[13] <= cnt_q[13] + 32'(t_underrun);
            if (32'(fifo_level) > cnt_q[14]) cnt_q[14] <= 32'(fifo_level);

            if (t_sent) led_hold_q <= LED_W'(LED_HOLD);
            else if (led_hold_q != '0) led_hold_q <= led_hold_q - LED_W'(1);
        end
    end

    assign tick = tick_cnt_q == REPORT_W'(REPORT_CYCLES - 1);

    // ------------------------------------------------------------ UART report
    logic [N_FIELDS*32-1:0] fields;
    logic [7:0]             r_tdata;
    logic                   r_tvalid, r_tready;

    always_comb begin
        for (int i = 0; i < N_FIELDS; i++) fields[i*32 +: 32] = cnt_q[i];
    end

    stats_report #(
        .N_FIELDS (N_FIELDS)
    ) u_report (
        .clk_i      (clk),
        .rst_i      (mac_rst_q),
        .tick_i     (tick),
        .fields_i   (fields),
        .m_tdata_o  (r_tdata),
        .m_tvalid_o (r_tvalid),
        .m_tready_i (r_tready)
    );

    uart_tx #(
        .CLKS_PER_BIT (CLK_HZ / BAUD)
    ) u_uart (
        .clk_i      (clk),
        .rst_i      (rst),
        .s_tdata_i  (r_tdata),
        .s_tvalid_i (r_tvalid),
        .s_tready_o (r_tready),
        .txd_o      (uart_rxd_out)
    );

    always_comb begin
        led[0] = !mac_rst_q && cnt_q[0][0];
        led[1] = led_hold_q != '0;
        led[2] = (cnt_q[2] | cnt_q[3] | cnt_q[6] | cnt_q[9] | cnt_q[10] | cnt_q[12]
                  | cnt_q[13]) != '0;
        led[3] = !mac_rst_q;
    end
endmodule
`default_nettype wire
