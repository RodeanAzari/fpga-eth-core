`default_nettype none
// eth_fcs_check: checks and strips the Ethernet FCS on a byte stream.
//
// Input:  one frame per tlast, every byte after the SFD including the 4-byte FCS
//         (mii_rx output, after the async FIFO). s_tuser_i on the tlast beat = the frame
//         already has an error upstream (rx_er, alignment).
// Output: the same frame without its FCS. m_tuser_o on the tlast beat = frame is bad and
//         must be discarded (the store-and-forward buffer drops it). Bytes still flow
//         before the verdict; this block does not buffer frames.
//
// Exactly one status pulse per input frame, on the cycle its tlast beat is accepted,
// with this priority: rx_err_o (upstream error), runt_o (fewer than MIN_FRAME bytes
// including FCS, 802.3 clause 3.4), crc_err_o, else frame_ok_o. A frame of 4 bytes or
// fewer has no payload and produces no output beats at all; it is still counted as a
// runt. Frames are not checked for a maximum length here. emitted_o, valid with every
// status pulse, says the frame put at least one beat on m_* (5 bytes or more in).
//
// Latency: 1 cycle from an accepted input beat to its output beat, but each byte is
// delayed by 4 input beats (the FCS window), so payload byte k leaves when input byte
// k+4 is accepted. Throughput: 1 byte/cycle. Backpressure: s_tready_o is registered
// pipeline style (!m_tvalid_o || m_tready_i).
//
// Reset: synchronous, active-high.
module eth_fcs_check #(
    parameter int MIN_FRAME = 64
) (
    input  wire logic       clk_i,
    input  wire logic       rst_i,
    input  wire logic [7:0] s_tdata_i,
    input  wire logic       s_tvalid_i,
    output logic            s_tready_o,
    input  wire logic       s_tlast_i,
    input  wire logic       s_tuser_i,
    output logic [7:0]      m_tdata_o,
    output logic            m_tvalid_o,
    input  wire logic       m_tready_i,
    output logic            m_tlast_o,
    output logic            m_tuser_o,
    // status pulses, exactly one per input frame
    output logic            frame_ok_o,
    output logic            crc_err_o,
    output logic            rx_err_o,
    output logic            runt_o,
    output logic            emitted_o      // valid with the status pulse
);
    localparam int          FCS_BYTES  = 4;             // 802.3 clause 3.2.9
    localparam logic [31:0] CRC_INIT   = 32'hFFFF_FFFF;
    localparam logic [31:0] CRC_RESIDUE = 32'hDEBB_20E3; // register after data + FCS, reflected
    localparam int          CNT_W      = $clog2(MIN_FRAME + 1);

    logic [31:0]      crc_q, crc_next;
    logic [CNT_W-1:0] cnt_q;        // bytes of this frame accepted so far, saturating
    logic [7:0]       dly_q [FCS_BYTES];  // dly_q[FCS_BYTES-1] is the oldest byte
    logic             fire, emit, too_short, bad_crc;

    crc32_d8 u_crc (
        .crc_i  (crc_q),
        .data_i (s_tdata_i),
        .crc_o  (crc_next)
    );

    always_comb begin
        s_tready_o = !m_tvalid_o || m_tready_i;
        fire       = s_tvalid_i && s_tready_o;
        emit       = cnt_q >= CNT_W'(FCS_BYTES);
        too_short  = (cnt_q + CNT_W'(1)) < CNT_W'(MIN_FRAME);
        bad_crc    = crc_next != CRC_RESIDUE;
    end

    // Datapath: delay line and output data (not reset).
    always_ff @(posedge clk_i) begin
        if (fire) begin
            dly_q[0] <= s_tdata_i;
            for (int i = 1; i < FCS_BYTES; i++) dly_q[i] <= dly_q[i-1];
            if (emit) m_tdata_o <= dly_q[FCS_BYTES-1];
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            crc_q      <= CRC_INIT;
            cnt_q      <= '0;
            m_tvalid_o <= 1'b0;
            m_tlast_o  <= 1'b0;
            m_tuser_o  <= 1'b0;
            frame_ok_o <= 1'b0;
            crc_err_o  <= 1'b0;
            rx_err_o   <= 1'b0;
            runt_o     <= 1'b0;
            emitted_o  <= 1'b0;
        end else begin
            frame_ok_o <= 1'b0;
            crc_err_o  <= 1'b0;
            rx_err_o   <= 1'b0;
            runt_o     <= 1'b0;
            emitted_o  <= 1'b0;

            if (fire && emit) begin
                m_tvalid_o <= 1'b1;
                m_tlast_o  <= s_tlast_i;
                m_tuser_o  <= s_tlast_i && (s_tuser_i || too_short || bad_crc);
            end else if (m_tready_i) begin
                m_tvalid_o <= 1'b0;
            end

            if (fire) begin
                if (s_tlast_i) begin
                    crc_q      <= CRC_INIT;
                    cnt_q      <= '0;
                    rx_err_o   <= s_tuser_i;
                    runt_o     <= !s_tuser_i && too_short;
                    crc_err_o  <= !s_tuser_i && !too_short && bad_crc;
                    frame_ok_o <= !s_tuser_i && !too_short && !bad_crc;
                    emitted_o  <= emit;
                end else begin
                    crc_q <= crc_next;
                    if (cnt_q != CNT_W'(MIN_FRAME)) cnt_q <= cnt_q + CNT_W'(1);
                end
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            // exactly one status per frame
            assert ($countones({frame_ok_o, crc_err_o, rx_err_o, runt_o}) <= 1);
            assert (!(m_tuser_o && !m_tlast_o));
            assert (cnt_q <= CNT_W'(MIN_FRAME));
        end
    end
`endif
endmodule
`default_nettype wire
