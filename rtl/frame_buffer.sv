`default_nettype none
// frame_buffer: store-and-forward frame buffer. A frame is released downstream only
// after its last beat has arrived with a good verdict (tuser = 0 on tlast); a bad frame
// is discarded by rewinding the write pointer, so nothing downstream ever sees a byte
// of it.
//
// Input:  AXI-Stream, one byte per beat, tuser on the tlast beat = discard this frame
//         (eth_fcs_check output).
// Output: AXI-Stream, one byte per beat, good frames only, first-word-fall-through.
//
// Oversize: a frame longer than MAX_FRAME bytes is discarded; its remaining bytes are
// consumed without being stored, so a jabbering source cannot deadlock the buffer.
// oversize_o pulses once for it at its tlast, unless the frame was already marked bad
// upstream (then the upstream status has counted it). frame_ok_o pulses for every
// frame released. Together with the upstream status this gives exactly one status
// per frame.
//
// Capacity: 2**ADDR_W bytes, which must be >= MAX_FRAME, so a frame in progress always
// fits once the reader has drained the committed frames. When full, s_tready_o drops
// (backpressure); while discarding an oversize frame it stays high.
//
// Latency: the first byte of a frame is valid on m_* 2 cycles after its tlast beat is
// accepted (commit, then fetch). Throughput: 1 byte/cycle in and out.
// Memory: one (1 + 8)-bit wide array, synchronous read, infers BRAM.
// Reset: synchronous, active-high.
module frame_buffer #(
    parameter int ADDR_W    = 12,
    parameter int MAX_FRAME = 1518   // bytes after FCS strip; 1514 + 4 for a VLAN tag
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
    output logic            frame_ok_o,
    output logic            oversize_o
);
    localparam int PTR_W = ADDR_W + 1;
    localparam int DEPTH = 2 ** ADDR_W;
    localparam int LEN_W = $clog2(MAX_FRAME + 1);

    if (DEPTH < MAX_FRAME) begin : g_bad_depth
        $error("frame_buffer: 2**ADDR_W must be >= MAX_FRAME");
    end

    logic [8:0]       mem [DEPTH];   // {tlast, data}
    logic [PTR_W-1:0] wr_ptr_q, commit_q, rd_ptr_q;
    logic [LEN_W-1:0] len_q;         // bytes of the current frame stored so far
    logic             drop_q;        // discarding the rest of an oversize frame
    logic             full, fire, too_long, store, fetch;

    always_comb begin
        full       = (wr_ptr_q - rd_ptr_q) == PTR_W'(DEPTH);
        s_tready_o = drop_q || !full;
        fire       = s_tvalid_i && s_tready_o;
        too_long   = len_q == LEN_W'(MAX_FRAME);
        store      = fire && !drop_q && !too_long;
        fetch      = (commit_q != rd_ptr_q) && (!m_tvalid_o || m_tready_i);
    end

    always_ff @(posedge clk_i) begin
        if (store) mem[wr_ptr_q[ADDR_W-1:0]] <= {s_tlast_i, s_tdata_i};
        if (fetch) {m_tlast_o, m_tdata_o} <= mem[rd_ptr_q[ADDR_W-1:0]];
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            wr_ptr_q   <= '0;
            commit_q   <= '0;
            rd_ptr_q   <= '0;
            len_q      <= '0;
            drop_q     <= 1'b0;
            m_tvalid_o <= 1'b0;
            frame_ok_o <= 1'b0;
            oversize_o <= 1'b0;
        end else begin
            frame_ok_o <= 1'b0;
            oversize_o <= 1'b0;

            if (fire) begin
                if (drop_q || too_long) begin
                    // Oversize: forget what was stored, swallow the rest.
                    wr_ptr_q <= commit_q;
                    drop_q   <= !s_tlast_i;
                    if (s_tlast_i) begin
                        len_q      <= '0;
                        oversize_o <= !s_tuser_i;
                    end
                end else if (s_tlast_i) begin
                    len_q <= '0;
                    if (s_tuser_i) begin
                        wr_ptr_q <= commit_q;  // bad frame: rewind
                    end else begin
                        wr_ptr_q   <= wr_ptr_q + PTR_W'(1);
                        commit_q   <= wr_ptr_q + PTR_W'(1);
                        frame_ok_o <= 1'b1;
                    end
                end else begin
                    wr_ptr_q <= wr_ptr_q + PTR_W'(1);
                    len_q    <= len_q + LEN_W'(1);
                end
            end

            if (fetch)           m_tvalid_o <= 1'b1;
            else if (m_tready_i) m_tvalid_o <= 1'b0;
            if (fetch)           rd_ptr_q   <= rd_ptr_q + PTR_W'(1);
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (!rst_i) begin
            assert ((wr_ptr_q - rd_ptr_q) <= PTR_W'(DEPTH));
            assert ((commit_q - rd_ptr_q) <= (wr_ptr_q - rd_ptr_q));  // rd <= commit <= wr
            assert (!(frame_ok_o && oversize_o));
        end
    end
`endif
endmodule
`default_nettype wire
