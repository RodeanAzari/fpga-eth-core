`default_nettype none
// eth_tx: core-domain Ethernet frames -> MII transmit.
//
//   core (clk_i) domain        | tx_clk domain
//   s_* -> async_fifo ---------> mii_tx (preamble, padding, FCS, IFG) -> MII pins
//
// Input: AXI-Stream, one byte per beat, one Ethernet frame per tlast (dst MAC ..
// payload, no FCS, no padding needed). Frames shorter than 60 bytes are zero-padded.
// No length limit is enforced here; the producer (e.g. udp_tx) keeps frames legal.
//
// Contract: the MII cannot stall, so once a frame's first byte is accepted, the rest
// must follow without long gaps (the average must stay above 12.5 MB/s at 100 Mbps; the
// FIFO absorbs short gaps). udp_tx meets this by buffering whole payloads. A producer
// that breaks it gets a frame with a wrong FCS on the wire (every receiver drops it)
// and an underrun_o pulse here, never a silent corrupt frame.
//
// Status (core domain): underrun_o, one-cycle pulse per frame ended by an underrun.
// It crosses from tx_clk through a toggle synchronizer; underruns are at least one
// frame apart, far slower than the 3-cycle crossing, so none merge.
//
// Clocks and resets: mii_clk_i is the PHY's tx_clk (25 MHz at 100 Mbps); clk_i is the
// core clock (must be faster than the 12.5 MB/s byte rate). mii_rst_i and rst_i are
// synchronous, active-high, each from a reset synchronizer in its own domain, fed by
// the same source (async_fifo requirement).
//
// Latency (first byte accepted on s_* -> tx_en high): SYNC_STAGES + 1 tx_clk (FIFO)
// + 2 (mii_tx); the first data nibble is 16 nibbles of preamble/SFD later.
module eth_tx #(
    parameter int FIFO_ADDR_W = 6,   // async FIFO depth 2**N bytes
    parameter int MIN_FRAME   = 64,  // bytes on the wire incl. FCS
    parameter int IFG_NIBBLES = 24   // 96 bit times
) (
    // core domain
    input  wire logic       clk_i,
    input  wire logic       rst_i,
    input  wire logic [7:0] s_tdata_i,
    input  wire logic       s_tvalid_i,
    output logic            s_tready_o,
    input  wire logic       s_tlast_i,
    output logic            underrun_o,
    // MII (tx_clk domain)
    input  wire logic       mii_clk_i,
    input  wire logic       mii_rst_i,
    output logic [3:0]      mii_txd_o,
    output logic            mii_tx_en_o
);
    localparam int SYNC_STAGES = 2;

    // -------------------------------------------------------------- clock crossing
    logic [8:0]           f_word;   // {tlast, tdata}
    logic                 f_tvalid, f_tready;
    logic [FIFO_ADDR_W:0] f_wr_level_unused, f_rd_level_unused;

    async_fifo #(
        .DATA_W      (9),
        .ADDR_W      (FIFO_ADDR_W),
        .SYNC_STAGES (SYNC_STAGES)
    ) u_fifo (
        .wr_clk_i   (clk_i),
        .wr_rst_i   (rst_i),
        .s_tdata_i  ({s_tlast_i, s_tdata_i}),
        .s_tvalid_i (s_tvalid_i),
        .s_tready_o (s_tready_o),
        .wr_level_o (f_wr_level_unused),
        .rd_clk_i   (mii_clk_i),
        .rd_rst_i   (mii_rst_i),
        .m_tdata_o  (f_word),
        .m_tvalid_o (f_tvalid),
        .m_tready_i (f_tready),
        .rd_level_o (f_rd_level_unused)
    );

    // ---------------------------------------------------------------- tx_clk domain
    logic mii_underrun;
    logic underrun_tgl_q;

    mii_tx #(
        .MIN_FRAME   (MIN_FRAME),
        .IFG_NIBBLES (IFG_NIBBLES)
    ) u_mii_tx (
        .clk_i       (mii_clk_i),
        .rst_i       (mii_rst_i),
        .s_tdata_i   (f_word[7:0]),
        .s_tvalid_i  (f_tvalid),
        .s_tready_o  (f_tready),
        .s_tlast_i   (f_word[8]),
        .mii_txd_o   (mii_txd_o),
        .mii_tx_en_o (mii_tx_en_o),
        .underrun_o  (mii_underrun)
    );

    always_ff @(posedge mii_clk_i) begin
        if (mii_rst_i)         underrun_tgl_q <= 1'b0;
        else if (mii_underrun) underrun_tgl_q <= !underrun_tgl_q;
    end

    // ------------------------------------------------------------------ core domain
    // Toggle synchronizer (listed CDC): SYNC_STAGES ASYNC_REG flops, then edge detect.
    (* ASYNC_REG = "TRUE" *) logic [SYNC_STAGES-1:0] underrun_sync_q;
    logic underrun_seen_q;

    always_ff @(posedge clk_i) begin
        // The sync chain and the edge reference track through reset, so a toggle level
        // left over from before reset never shows up as a pulse after it.
        underrun_sync_q <= {underrun_sync_q[SYNC_STAGES-2:0], underrun_tgl_q};
        underrun_seen_q <= underrun_sync_q[SYNC_STAGES-1];
        if (rst_i) underrun_o <= 1'b0;
        else       underrun_o <= underrun_sync_q[SYNC_STAGES-1] != underrun_seen_q;
    end
endmodule
`default_nettype wire
