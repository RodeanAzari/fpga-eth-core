`default_nettype none
// udp_tx: UDP payloads in, Ethernet II / IPv4 / UDP frames out (no FCS; eth_tx adds it).
//
// Input: AXI-Stream, one byte per beat, one UDP payload per tlast, 1..MAX_PAYLOAD
//   bytes. The length is counted here from tlast, so the producer never supplies it.
//   s_tuser_i on the tlast beat = discard this payload (e.g. a truncated datagram from
//   udp_rx); nothing is sent and no status pulses.
//   Destination (dst_mac_i, dst_ip_i, dst_port_i) and src_port_i are sampled with the
//   FIRST payload beat. For replies, wire them to udp_rx's src_mac_o / src_ip_o /
//   src_port_o: those are stable from udp_rx's first payload beat, so the host's
//   MAC/IP are learned from received traffic and no ARP is needed.
// Configuration (runtime): cfg_mac_i, cfg_ip_i are this node's source MAC and IP,
//   sampled when the header is built (after tlast). Change them only between payloads.
// Output: AXI-Stream, one byte per beat, one frame per tlast: dst MAC .. payload,
//   42 + length bytes, unpadded (eth_tx pads to the 802.3 minimum).
//
// Header (RFC 894 / RFC 791 / RFC 768): EtherType 0x0800; IPv4 version 4, IHL 5,
//   DSCP/ECN 0, identification 0 with DF set (RFC 6864 s4.1: atomic datagrams), TTL,
//   protocol 17, header checksum computed here; UDP checksum 0 (optional in IPv4).
//
// Store-and-forward: the payload is written to a buffer and the frame is emitted only
//   after tlast, at one byte per cycle with no gaps of its own, which is what eth_tx's
//   no-underrun contract needs. One payload is buffered at a time: s_tready_o is low
//   from tlast until the frame's last byte has left on m_*.
//
// Status (one-cycle pulses):
//   sent_o      the frame's last byte was accepted on m_*
//   oversize_o  payload longer than MAX_PAYLOAD: discarded, rest consumed (never stalls)
//
// Latency: tlast accepted -> first header byte valid on m_*: 3 cycles (checksum sum,
//   fold + header load, output register). Throughput: 1 byte/cycle out.
// Memory: 2**clog2(MAX_PAYLOAD) x 8 bits, synchronous read, infers one BRAM18 at 1472.
// Reset: synchronous, active-high.
module udp_tx #(
    parameter int         MAX_PAYLOAD = 1472,   // 1500 MTU - 20 IPv4 - 8 UDP
    parameter logic [7:0] TTL         = 8'd64
) (
    input  wire logic        clk_i,
    input  wire logic        rst_i,
    // configuration (runtime)
    input  wire logic [47:0] cfg_mac_i,
    input  wire logic [31:0] cfg_ip_i,
    // payload in
    input  wire logic [7:0]  s_tdata_i,
    input  wire logic        s_tvalid_i,
    output logic             s_tready_o,
    input  wire logic        s_tlast_i,
    input  wire logic        s_tuser_i,
    input  wire logic [47:0] dst_mac_i,
    input  wire logic [31:0] dst_ip_i,
    input  wire logic [15:0] dst_port_i,
    input  wire logic [15:0] src_port_i,
    // frame out
    output logic [7:0]       m_tdata_o,
    output logic             m_tvalid_o,
    input  wire logic        m_tready_i,
    output logic             m_tlast_o,
    // status
    output logic             sent_o,
    output logic             oversize_o
);
    localparam int          HDR_BYTES    = 14 + 20 + 8;  // Ethernet + IPv4 (IHL 5) + UDP
    localparam int          IP_HDR       = 20;
    localparam int          UDP_HDR      = 8;
    localparam logic [15:0] ETHERTYPE_IP = 16'h0800;      // RFC 894
    localparam logic [15:0] IP_VER_IHL   = 16'h4500;      // version 4, IHL 5, TOS 0
    localparam logic [15:0] IP_ID        = 16'h0000;      // RFC 6864 s4.1
    localparam logic [15:0] IP_FLAGS_DF  = 16'h4000;      // DF, offset 0
    localparam logic [7:0]  PROTO_UDP    = 8'd17;
    localparam logic [15:0] UDP_CSUM     = 16'h0000;      // RFC 768: 0 = not computed
    localparam int          LEN_W        = $clog2(MAX_PAYLOAD + 1);
    localparam int          ADDR_W       = $clog2(MAX_PAYLOAD);
    localparam int          HCNT_W       = $clog2(HDR_BYTES);

    typedef enum logic [2:0] {S_FILL, S_DROP, S_SUM, S_LOAD, S_HDR, S_PAY} state_t;

    state_t            state_q;
    logic              first_q;    // the next accepted beat starts a payload
    logic [LEN_W-1:0]  wr_cnt_q;   // payload bytes stored so far
    logic [LEN_W-1:0]  len_q;      // payload length, valid from S_SUM
    logic [ADDR_W-1:0] rd_ptr_q;
    logic [HCNT_W-1:0] hcnt_q;

    // Datapath (not reset)
    logic [7:0]          mem [2**ADDR_W];
    logic [7:0]          rd_data_q;
    logic [47:0]         dst_mac_q;
    logic [31:0]         dst_ip_q;
    logic [15:0]         dst_port_q, src_port_q;
    logic [19:0]         sum_q;    // ones'-complement sum of 10 16-bit words, unfolded
    logic [HDR_BYTES*8-1:0] hdr_q;    // shifted out MSB first

    logic              fire, adv, full, last_pay;
    logic [ADDR_W-1:0] rd_addr;
    logic [15:0]       ip_totlen, udp_len, csum;
    logic [16:0]       fold1;

    always_comb begin
        s_tready_o = state_q == S_FILL || state_q == S_DROP;
        fire       = s_tvalid_i && s_tready_o;
        full       = wr_cnt_q == LEN_W'(MAX_PAYLOAD);
        adv        = !m_tvalid_o || m_tready_i;
        last_pay   = LEN_W'(rd_ptr_q) == len_q - LEN_W'(1);
        rd_addr    = (state_q == S_PAY && adv) ? rd_ptr_q + ADDR_W'(1) : rd_ptr_q;
        ip_totlen  = 16'(len_q) + 16'(IP_HDR + UDP_HDR);
        udp_len    = 16'(len_q) + 16'(UDP_HDR);
        fold1      = {1'b0, sum_q[15:0]} + {13'd0, sum_q[19:16]};
        csum       = ~(fold1[15:0] + {15'd0, fold1[16]});
    end

    always_ff @(posedge clk_i) begin
        if (fire && state_q == S_FILL && !full) mem[wr_cnt_q[ADDR_W-1:0]] <= s_tdata_i;
        rd_data_q <= mem[rd_addr];  // always mem[rd_ptr_q] one cycle after rd_ptr_q moves

        if (fire && first_q) begin
            dst_mac_q  <= dst_mac_i;
            dst_ip_q   <= dst_ip_i;
            dst_port_q <= dst_port_i;
            src_port_q <= src_port_i;
        end

        // RFC 791 header checksum: ones'-complement sum of the header words with the
        // checksum field taken as 0, folded twice, complemented.
        if (state_q == S_SUM) begin
            sum_q <= 20'(IP_VER_IHL) + 20'(ip_totlen) + 20'(IP_ID) + 20'(IP_FLAGS_DF)
                   + 20'({TTL, PROTO_UDP})
                   + 20'(cfg_ip_i[31:16]) + 20'(cfg_ip_i[15:0])
                   + 20'(dst_ip_q[31:16]) + 20'(dst_ip_q[15:0]);
        end

        if (state_q == S_LOAD) begin
            hdr_q <= {dst_mac_q, cfg_mac_i, ETHERTYPE_IP,
                      IP_VER_IHL, ip_totlen, IP_ID, IP_FLAGS_DF, TTL, PROTO_UDP, csum,
                      cfg_ip_i, dst_ip_q,
                      src_port_q, dst_port_q, udp_len, UDP_CSUM};
        end else if (state_q == S_HDR && adv) begin
            hdr_q <= hdr_q << 8;
        end

        if (adv && state_q == S_HDR) m_tdata_o <= hdr_q[HDR_BYTES*8-1 -: 8];
        if (adv && state_q == S_PAY) m_tdata_o <= rd_data_q;
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q    <= S_FILL;
            first_q    <= 1'b1;
            wr_cnt_q   <= '0;
            rd_ptr_q   <= '0;
            hcnt_q     <= '0;
            m_tvalid_o <= 1'b0;
            m_tlast_o  <= 1'b0;
            sent_o     <= 1'b0;
            oversize_o <= 1'b0;
        end else begin
            sent_o     <= m_tvalid_o && m_tready_i && m_tlast_o;
            oversize_o <= 1'b0;
            if (fire) first_q <= s_tlast_i;

            if (m_tready_i) m_tvalid_o <= 1'b0;

            unique case (state_q)
                S_FILL: if (fire) begin
                    if (full) begin
                        // Byte MAX_PAYLOAD + 1: too long. Swallow the rest.
                        wr_cnt_q <= '0;
                        if (s_tlast_i) oversize_o <= !s_tuser_i;
                        else           state_q    <= S_DROP;
                    end else if (s_tlast_i) begin
                        wr_cnt_q <= '0;
                        len_q    <= wr_cnt_q + LEN_W'(1);
                        if (!s_tuser_i) state_q <= S_SUM;
                    end else begin
                        wr_cnt_q <= wr_cnt_q + LEN_W'(1);
                    end
                end
                S_DROP: if (fire && s_tlast_i) begin
                    oversize_o <= !s_tuser_i;
                    state_q    <= S_FILL;
                end
                S_SUM:  state_q <= S_LOAD;
                S_LOAD: begin
                    state_q  <= S_HDR;
                    hcnt_q   <= '0;
                    rd_ptr_q <= '0;
                end
                S_HDR: if (adv) begin
                    m_tvalid_o <= 1'b1;
                    m_tlast_o  <= 1'b0;
                    hcnt_q     <= hcnt_q + HCNT_W'(1);
                    if (hcnt_q == HCNT_W'(HDR_BYTES - 1)) state_q <= S_PAY;
                end
                S_PAY: if (adv) begin
                    m_tvalid_o <= 1'b1;
                    m_tlast_o  <= last_pay;
                    rd_ptr_q   <= rd_ptr_q + ADDR_W'(1);
                    if (last_pay) state_q <= S_FILL;
                end
                default: state_q <= S_FILL;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            assert (wr_cnt_q <= LEN_W'(MAX_PAYLOAD));
            assert (!(state_q == S_PAY && len_q == '0));
            assert (!(sent_o && oversize_o));
        end
    end
`endif
endmodule
`default_nettype wire
