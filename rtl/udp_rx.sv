`default_nettype none
// udp_rx: Ethernet II / IPv4 / UDP receive filter. Frames in, UDP payloads out.
//
// Input:  AXI-Stream, one byte per beat, one good Ethernet frame per tlast (dst MAC ..
//         end, FCS already stripped; eth_rx output).
// Output: AXI-Stream, one byte per beat, one UDP payload per tlast, Ethernet padding
//         removed (length from the UDP header). m_tuser_o on the tlast beat = the frame
//         ended before the payload did (truncated datagram); discard it.
//
// Accept rules (RFC 894 / RFC 791 / RFC 768):
//   - dst MAC: the multicast MAC for cfg_ip_i (01:00:5E + low 23 bits, RFC 1112 s6.4)
//     if cfg_ip_i is class D, else cfg_mac_i. Broadcast is not accepted.
//   - EtherType 0x0800; no VLAN tag.
//   - IPv4: version 4, IHL >= 5 (options skipped), header checksum valid, protocol 17,
//     not a fragment (MF = 0 and offset = 0), dst IP == cfg_ip_i.
//   - UDP: dst port == cfg_port_i, 8 < length <= IP total length - IHL*4. The UDP
//     checksum is ignored (optional in IPv4).
// Configuration is runtime (registers in the consumer). Change it only between frames;
// a frame in flight may be judged with either value.
//
// Status (one-cycle pulse, exactly one per input frame, at its tlast):
//   ok_o           payload delivered
//   filtered_o     not for us: MAC, EtherType, protocol, fragment, IP, port, or an empty
//                  datagram (UDP length 8: nothing to deliver)
//   ip_csum_err_o  addressed to our MAC, IPv4 header checksum wrong
//   malformed_o    bad version/IHL, inconsistent lengths, or the frame ended inside the
//                  headers or the payload
//
// Metadata (src_mac_o, src_ip_o, src_port_o, dst_port_o): latched when a datagram is
// accepted; stable from its first payload beat until the next accepted datagram's.
//
// Latency: 1 cycle from an input byte to its output beat; the first payload byte is
// input byte 14 + IHL*4 + 8 (42 without options). Throughput 1 byte/cycle.
// Backpressure: s_tready_o = !m_tvalid_o || m_tready_i, also while skipping headers.
// Reset: synchronous, active-high.
module udp_rx (
    input  wire logic        clk_i,
    input  wire logic        rst_i,
    // configuration (runtime)
    input  wire logic [47:0] cfg_mac_i,
    input  wire logic [31:0] cfg_ip_i,
    input  wire logic [15:0] cfg_port_i,
    // frames in
    input  wire logic [7:0]  s_tdata_i,
    input  wire logic        s_tvalid_i,
    output logic             s_tready_o,
    input  wire logic        s_tlast_i,
    // UDP payload out
    output logic [7:0]       m_tdata_o,
    output logic             m_tvalid_o,
    input  wire logic        m_tready_i,
    output logic             m_tlast_o,
    output logic             m_tuser_o,
    output logic [47:0]      src_mac_o,
    output logic [31:0]      src_ip_o,
    output logic [15:0]      src_port_o,
    output logic [15:0]      dst_port_o,
    // status
    output logic             ok_o,
    output logic             filtered_o,
    output logic             ip_csum_err_o,
    output logic             malformed_o
);
    // Header layout
    localparam int          ETH_HDR      = 14;        // RFC 894: dst(6) src(6) type(2)
    localparam int          ETH_SRC_OFF  = 6;
    localparam logic [15:0] ETHERTYPE_IP = 16'h0800;
    localparam int          IP_TOTLEN    = 2;         // RFC 791 s3.1 byte offsets
    localparam int          IP_FRAG      = 6;         // flags(3) + fragment offset(13)
    localparam int          IP_PROTO     = 9;
    localparam int          IP_SRC       = 12;
    localparam int          IP_DST       = 16;
    localparam logic [3:0]  IP_VERSION   = 4'd4;
    localparam logic [3:0]  IHL_MIN      = 4'd5;
    localparam logic [7:0]  PROTO_UDP    = 8'd17;
    localparam int          UDP_HDR      = 8;         // RFC 768: src dst len csum
    localparam int          UDP_DST      = 2;
    localparam int          UDP_LEN      = 4;
    localparam logic [23:0] MCAST_OUI    = 24'h01_00_5E;  // RFC 1112 s6.4
    localparam logic [3:0]  CLASS_D      = 4'hE;

    typedef enum logic [2:0] {S_ETH, S_IP, S_UDP, S_PAY, S_DROP} state_t;
    typedef enum logic [1:0] {V_OK, V_FILT, V_CSUM, V_MAL} verdict_t;

    state_t      state_q;
    verdict_t    verdict_q;   // decided at the end of the UDP header
    logic [5:0]  cnt_q;       // byte index within the current header
    logic [15:0] remain_q;    // payload bytes still to send

    // Captured header fields (datapath, not reset)
    logic [47:0] dst_mac_q, src_mac_q;
    logic [15:0] ethertype_q, ip_totlen_q, udp_src_q, udp_dst_q, udp_len_q;
    logic [13:0] ip_frag_q;   // MF flag + fragment offset (DF and reserved dropped)
    logic [3:0]  ip_ver_q, ihl_q;
    logic [7:0]  ip_proto_q, csum_hi_q;
    logic [31:0] ip_src_q, ip_dst_q;
    logic [20:0] csum_acc_q;  // 16-bit word sum, carries kept (max 30 words)
    logic [15:0] csum_fold_q; // folded at the end of the IP header

    logic        fire, emit, last_pay;
    logic [5:0]  ip_hl;       // header length in bytes, IHL < 5 treated as 5 for indexing
    logic [47:0] want_mac;
    logic [16:0] csum_f1;
    verdict_t    verdict_d;
    logic [15:0] ip_room;

    always_comb begin
        s_tready_o = !m_tvalid_o || m_tready_i;
        fire       = s_tvalid_i && s_tready_o;
        emit       = fire && state_q == S_PAY;
        last_pay   = remain_q == 16'd1;
        ip_hl      = (ihl_q < IHL_MIN) ? 6'd20 : {ihl_q, 2'b00};
        want_mac   = (cfg_ip_i[31:28] == CLASS_D) ? {MCAST_OUI, 1'b0, cfg_ip_i[22:0]}
                                                  : cfg_mac_i;
        csum_f1    = {1'b0, csum_acc_q[15:0]} + {12'd0, csum_acc_q[20:16]};
        ip_room    = ip_totlen_q - {10'd0, ip_hl};

        // Verdict, evaluated on the last UDP header byte (all fields captured but the
        // low byte of the checksum, which is ignored).
        if (dst_mac_q != want_mac || ethertype_q != ETHERTYPE_IP)           verdict_d = V_FILT;
        else if (ip_ver_q != IP_VERSION || ihl_q < IHL_MIN)                 verdict_d = V_MAL;
        else if (csum_fold_q != 16'hFFFF)                                   verdict_d = V_CSUM;
        else if (ip_proto_q != PROTO_UDP || ip_frag_q != '0
                 || ip_dst_q != cfg_ip_i || udp_dst_q != cfg_port_i)        verdict_d = V_FILT;
        else if (ip_totlen_q < {10'd0, ip_hl} + 16'(UDP_HDR)
                 || udp_len_q < 16'(UDP_HDR) || udp_len_q > ip_room)        verdict_d = V_MAL;
        else if (udp_len_q == 16'(UDP_HDR))                                 verdict_d = V_FILT;
        else                                                                verdict_d = V_OK;
    end

    // Field capture and checksum (datapath).
    always_ff @(posedge clk_i) begin
        if (fire) begin
            unique case (state_q)
                S_ETH: begin
                    if (cnt_q < 6'(ETH_SRC_OFF)) dst_mac_q <= {dst_mac_q[39:0], s_tdata_i};
                    else if (cnt_q < 6'(ETH_HDR - 2)) src_mac_q <= {src_mac_q[39:0], s_tdata_i};
                    else ethertype_q <= {ethertype_q[7:0], s_tdata_i};
                    csum_acc_q <= '0;
                end
                S_IP: begin
                    if (cnt_q == 6'd0) {ip_ver_q, ihl_q} <= s_tdata_i;
                    if (cnt_q == 6'(IP_TOTLEN) || cnt_q == 6'(IP_TOTLEN + 1))
                        ip_totlen_q <= {ip_totlen_q[7:0], s_tdata_i};
                    if (cnt_q == 6'(IP_FRAG))     ip_frag_q[13:8] <= s_tdata_i[5:0];
                    if (cnt_q == 6'(IP_FRAG + 1)) ip_frag_q[7:0]  <= s_tdata_i;
                    if (cnt_q == 6'(IP_PROTO)) ip_proto_q <= s_tdata_i;
                    if (cnt_q >= 6'(IP_SRC) && cnt_q < 6'(IP_DST))
                        ip_src_q <= {ip_src_q[23:0], s_tdata_i};
                    if (cnt_q >= 6'(IP_DST) && cnt_q < 6'(IP_DST + 4))
                        ip_dst_q <= {ip_dst_q[23:0], s_tdata_i};
                    if (!cnt_q[0]) csum_hi_q <= s_tdata_i;
                    else csum_acc_q <= csum_acc_q + {5'd0, csum_hi_q, s_tdata_i};
                end
                S_UDP: begin
                    if (cnt_q == 6'd0) csum_fold_q <= csum_f1[15:0] + {15'd0, csum_f1[16]};
                    if (cnt_q < 6'(UDP_DST)) udp_src_q <= {udp_src_q[7:0], s_tdata_i};
                    else if (cnt_q < 6'(UDP_LEN)) udp_dst_q <= {udp_dst_q[7:0], s_tdata_i};
                    else if (cnt_q < 6'(UDP_LEN + 2)) udp_len_q <= {udp_len_q[7:0], s_tdata_i};
                end
                default: ;
            endcase
        end
        if (emit) m_tdata_o <= s_tdata_i;
        if (fire && state_q == S_UDP && cnt_q == 6'(UDP_HDR - 1) && verdict_d == V_OK) begin
            src_mac_o  <= src_mac_q;
            src_ip_o   <= ip_src_q;
            src_port_o <= udp_src_q;
            dst_port_o <= udp_dst_q;
        end
    end

    // Control.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q       <= S_ETH;
            cnt_q         <= '0;
            verdict_q     <= V_MAL;
            m_tvalid_o    <= 1'b0;
            m_tlast_o     <= 1'b0;
            m_tuser_o     <= 1'b0;
            ok_o          <= 1'b0;
            filtered_o    <= 1'b0;
            ip_csum_err_o <= 1'b0;
            malformed_o   <= 1'b0;
        end else begin
            ok_o          <= 1'b0;
            filtered_o    <= 1'b0;
            ip_csum_err_o <= 1'b0;
            malformed_o   <= 1'b0;

            if (emit) begin
                m_tvalid_o <= 1'b1;
                m_tlast_o  <= last_pay || s_tlast_i;
                m_tuser_o  <= s_tlast_i && !last_pay;
            end else if (m_tready_i) begin
                m_tvalid_o <= 1'b0;
            end

            if (fire) begin
                cnt_q <= cnt_q + 6'd1;
                unique case (state_q)
                    S_ETH: if (cnt_q == 6'(ETH_HDR - 1)) begin
                        state_q <= S_IP;
                        cnt_q   <= '0;
                    end
                    S_IP: if (cnt_q != 6'd0 && cnt_q == ip_hl - 6'd1) begin
                        state_q <= S_UDP;
                        cnt_q   <= '0;
                    end
                    S_UDP: if (cnt_q == 6'(UDP_HDR - 1)) begin
                        verdict_q <= verdict_d;
                        state_q   <= (verdict_d == V_OK) ? S_PAY : S_DROP;
                        remain_q  <= udp_len_q - 16'(UDP_HDR);
                    end
                    S_PAY: begin
                        remain_q <= remain_q - 16'd1;
                        if (last_pay) state_q <= S_DROP;  // Ethernet padding follows
                    end
                    default: ;
                endcase

                if (s_tlast_i) begin
                    state_q   <= S_ETH;
                    cnt_q     <= '0;
                    verdict_q <= V_MAL;
                    unique case (state_q)
                        S_PAY:  if (last_pay) ok_o <= 1'b1; else malformed_o <= 1'b1;
                        S_DROP: begin
                            ok_o          <= verdict_q == V_OK;
                            filtered_o    <= verdict_q == V_FILT;
                            ip_csum_err_o <= verdict_q == V_CSUM;
                            malformed_o   <= verdict_q == V_MAL;
                        end
                        S_UDP: begin
                            // Ends on the last header byte: fine only if not accepted.
                            if (cnt_q == 6'(UDP_HDR - 1) && verdict_d != V_OK) begin
                                filtered_o    <= verdict_d == V_FILT;
                                ip_csum_err_o <= verdict_d == V_CSUM;
                                malformed_o   <= verdict_d == V_MAL;
                            end else begin
                                malformed_o <= 1'b1;
                            end
                        end
                        default: malformed_o <= 1'b1;  // ended inside Eth/IP header
                    endcase
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            assert ($countones({ok_o, filtered_o, ip_csum_err_o, malformed_o}) <= 1);
            assert (!(m_tuser_o && !m_tlast_o));
        end
    end
`endif
endmodule
`default_nettype wire
