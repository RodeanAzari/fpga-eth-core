`default_nettype none
// mii_tx: byte stream -> MII transmit (100BASE-TX, IEEE 802.3 clause 22).
//
// MII boundary (all in the PHY's tx_clk domain, 25 MHz at 100 Mbps, 2.5 MHz at 10 Mbps):
//   mii_txd_o[3:0]  data nibble, driven from a flop on the rising edge of tx_clk; the PHY
//                   samples it on the next rising edge
//   mii_tx_en_o     high from the first preamble nibble to the last FCS nibble
//   Nibble order:   the LOW nibble of each byte goes first (clause 22.2.3).
//   No tx_er: the Arty's DP83848J does not bring it out. A frame that cannot be finished
//   is sent with a deliberately wrong FCS instead, so every receiver discards it.
// Nothing PHY-specific is assumed beyond these signals.
//
// Input: AXI-Stream sink, one byte per beat, one Ethernet frame per tlast (dst MAC ..
// payload, no FCS), first-word-fall-through (an async FIFO's read side). This block
// adds the preamble and SFD (7 x 0x55, 0xD5; clause 3.2.1-2), zero padding up to
// MIN_FRAME - 4 bytes (clause 3.2.8), the FCS (CRC-32, ~crc sent LSB byte first,
// clause 3.2.9), and at least IFG_NIBBLES idle clocks between frames (96 bit times =
// 24 nibbles, clause 4.4.2).
//
// The MII cannot be stalled: once a frame starts, a byte must be valid at the input
// every 2 tx_clk cycles until tlast. If not (underrun), the frame is ended at once with
// a zero byte, padding, and an inverted-bit FCS (always wrong); underrun_o pulses; the
// rest of that frame is consumed and discarded after the IFG. Never silent.
//
// Throughput: line rate; back-to-back frames are separated by exactly IFG_NIBBLES
// idle clocks. Latency: tx_en rises 2 cycles after the first byte is valid (idle check,
// output register); the first data nibble follows the 16-nibble preamble + SFD.
// Reset: synchronous, active-high, tx_clk domain.
module mii_tx #(
    parameter int MIN_FRAME   = 64,  // bytes on the wire incl. FCS (802.3 minimum)
    parameter int IFG_NIBBLES = 24   // idle tx_clk cycles between frames, >= 2
) (
    input  wire logic       clk_i,
    input  wire logic       rst_i,
    // byte stream
    input  wire logic [7:0] s_tdata_i,
    input  wire logic       s_tvalid_i,
    output logic            s_tready_o,
    input  wire logic       s_tlast_i,
    // MII
    output logic [3:0]      mii_txd_o,
    output logic            mii_tx_en_o,
    // status (tx_clk domain)
    output logic            underrun_o
);
    localparam int          PRE_NIBBLES = 16;            // 7 x 0x55 + 0xD5, low nibble first
    localparam logic [3:0]  PRE_NIB     = 4'h5;          // 802.3 clause 3.2.1
    localparam logic [3:0]  SFD_HI_NIB  = 4'hD;          // 802.3 clause 3.2.2: SFD 0xD5
    localparam int          FCS_NIBBLES = 8;
    localparam int          MIN_DATA    = MIN_FRAME - 4; // bytes before the FCS
    localparam logic [31:0] CRC_INIT    = 32'hFFFF_FFFF;
    localparam logic [31:0] FCS_SPOIL   = 32'h0000_0001; // XORed in on underrun
    localparam int          LEN_W       = $clog2(MIN_DATA + 1);
    localparam int          CNT_W       = $clog2(IFG_NIBBLES + PRE_NIBBLES);

    if (IFG_NIBBLES < 2) begin : g_bad_ifg
        $error("mii_tx: IFG_NIBBLES must be >= 2");
    end

    typedef enum logic [2:0] {S_IDLE, S_PRE, S_DATA, S_PAD, S_FCS, S_IFG, S_DRAIN} state_t;

    state_t           state_q;
    logic [CNT_W-1:0] cnt_q;   // nibble index within preamble / FCS / IFG
    logic             hi_q;    // hi_nib_q goes out next
    logic [3:0]       hi_nib_q; // high nibble of the byte in flight
    logic             last_q;  // that byte ends the data (tlast or underrun)
    logic             bad_q;   // underrun in this frame: spoil the FCS, drain after
    logic [LEN_W-1:0] len_q;   // bytes sent, saturating at MIN_DATA
    logic [31:0]      crc_q;

    logic [3:0]  nib_d;
    logic        en_d, take, starve;
    logic [7:0]  crc_byte;
    logic [31:0] crc_next, fcs;
    logic        short;        // the byte just finished leaves the frame below MIN_DATA

    always_comb begin
        nib_d      = '0;
        en_d       = 1'b0;
        s_tready_o = 1'b0;
        fcs        = ~crc_q ^ (bad_q ? FCS_SPOIL : '0);
        take       = state_q == S_DATA && !hi_q && s_tvalid_i;
        starve     = state_q == S_DATA && !hi_q && !s_tvalid_i;
        crc_byte   = take ? s_tdata_i : 8'h00;  // padding and the underrun byte are 0x00
        short      = len_q < LEN_W'(MIN_DATA - 1);

        unique case (state_q)
            S_PRE: begin
                en_d  = 1'b1;
                nib_d = (cnt_q == CNT_W'(PRE_NIBBLES - 1)) ? SFD_HI_NIB : PRE_NIB;
            end
            S_DATA: begin
                en_d       = 1'b1;
                s_tready_o = !hi_q;
                nib_d      = hi_q ? hi_nib_q : (take ? s_tdata_i[3:0] : 4'h0);
            end
            S_PAD: begin
                en_d = 1'b1;
            end
            S_FCS: begin
                en_d  = 1'b1;
                nib_d = fcs[{cnt_q[2:0], 2'b00} +: 4];
            end
            S_DRAIN: s_tready_o = 1'b1;
            default: ;
        endcase
    end

    crc32_d8 u_crc (
        .crc_i  (crc_q),
        .data_i (crc_byte),
        .crc_o  (crc_next)
    );

    // Datapath (not reset).
    always_ff @(posedge clk_i) begin
        if (state_q == S_PRE) crc_q <= CRC_INIT;
        if ((state_q == S_DATA || state_q == S_PAD) && !hi_q) begin
            crc_q    <= crc_next;
            hi_nib_q <= crc_byte[7:4];
            last_q   <= state_q == S_PAD || starve || s_tlast_i;
        end
    end

    // Control and outputs.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q     <= S_IDLE;
            cnt_q       <= '0;
            hi_q        <= 1'b0;
            bad_q       <= 1'b0;
            len_q       <= '0;
            mii_txd_o   <= '0;
            mii_tx_en_o <= 1'b0;
            underrun_o  <= 1'b0;
        end else begin
            mii_txd_o   <= nib_d;
            mii_tx_en_o <= en_d;
            underrun_o  <= starve;
            cnt_q       <= cnt_q + CNT_W'(1);

            unique case (state_q)
                S_IDLE: begin
                    cnt_q <= '0;
                    if (s_tvalid_i) state_q <= S_PRE;
                end
                S_PRE: if (cnt_q == CNT_W'(PRE_NIBBLES - 1)) begin
                    state_q <= S_DATA;
                    hi_q    <= 1'b0;
                    bad_q   <= 1'b0;
                    len_q   <= '0;
                end
                S_DATA, S_PAD: begin
                    hi_q <= !hi_q;
                    if (starve) bad_q <= 1'b1;
                    if (hi_q) begin
                        if (short) len_q <= len_q + LEN_W'(1);
                        if (state_q == S_PAD ? !short : last_q) begin
                            state_q <= short ? S_PAD : S_FCS;
                            cnt_q   <= '0;
                        end
                    end
                end
                S_FCS: if (cnt_q == CNT_W'(FCS_NIBBLES - 1)) begin
                    state_q <= S_IFG;
                    cnt_q   <= '0;
                end
                // IFG_NIBBLES - 1 cycles here plus one in S_IDLE.
                S_IFG: if (cnt_q == CNT_W'(IFG_NIBBLES - 2)) begin
                    state_q <= bad_q ? S_DRAIN : S_IDLE;
                end
                S_DRAIN: if (s_tvalid_i && s_tlast_i) state_q <= S_IDLE;
                default: state_q <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            assert (len_q <= LEN_W'(MIN_DATA));
            assert (!(state_q == S_PAD && len_q >= LEN_W'(MIN_DATA)));
            assert (!(underrun_o && !mii_tx_en_o));
        end
    end
`endif
endmodule
`default_nettype wire
