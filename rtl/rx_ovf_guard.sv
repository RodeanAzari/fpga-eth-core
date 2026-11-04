`default_nettype none
// rx_ovf_guard: sits between mii_rx and the async FIFO's write port, in the rx_clk
// domain. The MII cannot be stalled, so when the FIFO is full a byte is lost. This block
// makes that loss explicit instead of silent:
//   - once any beat of a frame is lost, the rest of that frame is discarded;
//   - as soon as the FIFO has room, an "abort" beat is written: tlast=1, tuser=2'b10,
//     tdata = the number of source frames lost since the last abort (saturating at
//     255). It terminates a partially written frame, or stands alone as a 1-byte frame.
// Downstream, every tlast beat with tuser[1] set reports tdata lost frames, so
//   frames in = frames delivered + sum(abort tdata)   (exact unless a count saturates).
//
// Source: mii_rx output (no tready). tuser[0] = PHY error flag on the last beat.
// Sink:   the FIFO write port, used as a push interface: m_tvalid_o does not depend on
//         fifo_ready_i, and a beat not accepted is gone (counted as above), so data is
//         not held stable across a refusal as AXI-Stream would require.
//
// Latency: 0 cycles (combinational mux in front of the FIFO). Reset: sync, active-high.
module rx_ovf_guard (
    input  wire logic       clk_i,
    input  wire logic       rst_i,
    input  wire logic [7:0] s_tdata_i,
    input  wire logic       s_tvalid_i,
    input  wire logic       s_tlast_i,
    input  wire logic       s_tuser_i,
    output logic [7:0]      m_tdata_o,
    output logic            m_tvalid_o,
    input  wire logic       m_tready_i,
    output logic            m_tlast_o,
    output logic [1:0]      m_tuser_o
);
    localparam logic [1:0] USER_PHY_ERR = 2'b01;
    localparam logic [1:0] USER_OVF     = 2'b10;
    localparam logic [7:0] OWED_MAX     = 8'hFF;

    logic       skip_q;   // discarding the rest of a lost frame, through its tlast
    logic [7:0] owed_q;   // lost frames not yet reported by an abort beat
    logic       src, lost;
    logic [7:0] owed_inc;

    always_comb begin
        src        = s_tvalid_i && !skip_q;
        // A source beat is lost if the FIFO is full, or if the slot goes to the abort.
        lost       = src && (owed_q != '0 || !m_tready_i);
        owed_inc   = (owed_q == OWED_MAX) ? OWED_MAX : owed_q + 8'd1;

        m_tvalid_o = (owed_q != '0) || src;
        if (owed_q != '0) begin
            m_tdata_o = owed_q;
            m_tlast_o = 1'b1;
            m_tuser_o = USER_OVF;
        end else begin
            m_tdata_o = s_tdata_i;
            m_tlast_o = s_tlast_i;
            m_tuser_o = s_tuser_i ? USER_PHY_ERR : 2'b00;
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            skip_q <= 1'b0;
            owed_q <= '0;
        end else begin
            if (s_tvalid_i && skip_q && s_tlast_i) skip_q <= 1'b0;
            if (lost) skip_q <= !s_tlast_i;

            // While owed_q != 0 nothing but the abort beat is written, so a non-skipped
            // source beat is always the first beat of a new frame: one more lost frame.
            if (owed_q != '0 && m_tready_i) owed_q <= lost ? 8'd1 : 8'd0;
            else if (lost)                  owed_q <= owed_inc;
        end
    end
endmodule
`default_nettype wire
