`default_nettype none
// async_fifo: dual-clock FIFO with Gray-coded pointers (Cummings style).
//
// Write side: AXI-Stream sink in wr_clk_i. s_tready_o is low only when full.
// Read side:  AXI-Stream source in rd_clk_i, first-word-fall-through. The memory has a
//             synchronous read (infers BRAM / registered LUTRAM) that feeds m_tdata_o.
//
// Latency: a word written on wr_clk edge N is visible on m_tvalid_o after the write
// pointer crosses SYNC_STAGES rd_clk flops plus one fetch cycle: SYNC_STAGES + 1 rd_clk
// cycles (+ up to one rd_clk of phase uncertainty). Throughput is one word per cycle on
// both sides.
//
// Reset: synchronous, active-high, one per domain. Both resets must be asserted together
// and each must be held for at least one edge of its own clock (drive each from a reset
// synchronizer fed by the same source).
//
// CDC: only the Gray pointers cross domains, each through SYNC_STAGES ASYNC_REG flops.
// Constrain them with set_max_delay -datapath_only (see constr/async_fifo.xdc).
//
// Occupancy: wr_level_o is the write side's (conservative, may over-report) view of the
// fill level, for high-water marks and overflow decisions. rd_level_o is the read side's
// (may under-report) view, excluding the word held in the output register.
module async_fifo #(
    parameter int DATA_W      = 8,
    parameter int ADDR_W      = 4,   // depth = 2**ADDR_W
    parameter int SYNC_STAGES = 2
) (
    // write domain
    input  wire logic              wr_clk_i,
    input  wire logic              wr_rst_i,
    input  wire logic [DATA_W-1:0] s_tdata_i,
    input  wire logic              s_tvalid_i,
    output logic                   s_tready_o,
    output logic [ADDR_W:0]        wr_level_o,
    // read domain
    input  wire logic              rd_clk_i,
    input  wire logic              rd_rst_i,
    output logic [DATA_W-1:0]      m_tdata_o,
    output logic                   m_tvalid_o,
    input  wire logic              m_tready_i,
    output logic [ADDR_W:0]        rd_level_o
);
    localparam int PTR_W = ADDR_W + 1;  // one extra bit tells full from empty
    localparam int DEPTH = 2 ** ADDR_W;

    function automatic logic [PTR_W-1:0] bin2gray(input logic [PTR_W-1:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    function automatic logic [PTR_W-1:0] gray2bin(input logic [PTR_W-1:0] g);
        gray2bin[PTR_W-1] = g[PTR_W-1];
        for (int i = PTR_W - 2; i >= 0; i--) gray2bin[i] = gray2bin[i+1] ^ g[i];
    endfunction

    logic [DATA_W-1:0] mem [DEPTH];

    // ---------------------------------------------------------------- write domain
    logic [PTR_W-1:0] wr_bin_q, wr_gray_q;
    (* ASYNC_REG = "TRUE" *) logic [PTR_W-1:0] rd_gray_sync_q [SYNC_STAGES];
    logic [PTR_W-1:0] rd_bin_in_wr;
    logic             wr_fire;
    logic [PTR_W-1:0] wr_bin_d;

    always_comb begin
        rd_bin_in_wr = gray2bin(rd_gray_sync_q[SYNC_STAGES-1]);
        wr_level_o   = wr_bin_q - rd_bin_in_wr;
        s_tready_o   = (wr_level_o != PTR_W'(DEPTH)) && !wr_rst_i;
        wr_fire      = s_tvalid_i && s_tready_o;
        wr_bin_d     = wr_bin_q + PTR_W'(wr_fire);
    end

    always_ff @(posedge wr_clk_i) begin
        if (wr_fire) mem[wr_bin_q[ADDR_W-1:0]] <= s_tdata_i;
    end

    always_ff @(posedge wr_clk_i) begin
        if (wr_rst_i) begin
            wr_bin_q  <= '0;
            wr_gray_q <= '0;
            for (int i = 0; i < SYNC_STAGES; i++) rd_gray_sync_q[i] <= '0;
        end else begin
            wr_bin_q  <= wr_bin_d;
            wr_gray_q <= bin2gray(wr_bin_d);
            rd_gray_sync_q[0] <= rd_gray_q;
            for (int i = 1; i < SYNC_STAGES; i++) rd_gray_sync_q[i] <= rd_gray_sync_q[i-1];
        end
    end

    // ----------------------------------------------------------------- read domain
    logic [PTR_W-1:0] rd_bin_q, rd_gray_q;
    (* ASYNC_REG = "TRUE" *) logic [PTR_W-1:0] wr_gray_sync_q [SYNC_STAGES];
    logic [PTR_W-1:0] wr_bin_in_rd;
    logic             rd_empty, rd_fetch;
    logic [PTR_W-1:0] rd_bin_d;

    always_comb begin
        wr_bin_in_rd = gray2bin(wr_gray_sync_q[SYNC_STAGES-1]);
        rd_level_o   = wr_bin_in_rd - rd_bin_q;
        rd_empty     = (rd_level_o == '0);
        // Fetch into the output register when it is empty or being drained.
        rd_fetch     = !rd_empty && (!m_tvalid_o || m_tready_i);
        rd_bin_d     = rd_bin_q + PTR_W'(rd_fetch);
    end

    always_ff @(posedge rd_clk_i) begin
        if (rd_fetch) m_tdata_o <= mem[rd_bin_q[ADDR_W-1:0]];
    end

    always_ff @(posedge rd_clk_i) begin
        if (rd_rst_i) begin
            rd_bin_q   <= '0;
            rd_gray_q  <= '0;
            m_tvalid_o <= 1'b0;
            for (int i = 0; i < SYNC_STAGES; i++) wr_gray_sync_q[i] <= '0;
        end else begin
            rd_bin_q  <= rd_bin_d;
            rd_gray_q <= bin2gray(rd_bin_d);
            if (rd_fetch)        m_tvalid_o <= 1'b1;
            else if (m_tready_i) m_tvalid_o <= 1'b0;
            wr_gray_sync_q[0] <= wr_gray_q;
            for (int i = 1; i < SYNC_STAGES; i++) wr_gray_sync_q[i] <= wr_gray_sync_q[i-1];
        end
    end

    // ------------------------------------------------------------------ assertions
`ifndef SYNTHESIS
    // Single-domain checks: visible to Verilator (--assert) and SymbiYosys.
    always_ff @(posedge wr_clk_i) begin
        if (!wr_rst_i) begin
            assert (wr_level_o <= PTR_W'(DEPTH));  // write side never sees > DEPTH
            assert ($countones(wr_gray_q ^ bin2gray(wr_bin_d)) <= 1);  // Gray: 1 bit/step
        end
    end
    always_ff @(posedge rd_clk_i) begin
        if (!rd_rst_i) begin
            assert (rd_level_o <= PTR_W'(DEPTH));
            assert ($countones(rd_gray_q ^ bin2gray(rd_bin_d)) <= 1);
        end
    end
`endif

`ifdef FORMAL
    // Cross-domain properties. Proven with a global clock (formal/async_fifo_fv.sv).
    (* gclk *) logic f_gclk;
    logic f_past_valid = 1'b0;
    always_ff @(posedge f_gclk) f_past_valid <= 1'b1;

    logic [PTR_W-1:0] f_fill;
    assign f_fill = wr_bin_q - rd_bin_q;

    always_comb begin
        if (f_past_valid && !wr_rst_i && !rd_rst_i) begin
            // No overflow, no underflow: the true fill level is always 0..DEPTH.
            assert (f_fill <= PTR_W'(DEPTH));
            // Registered Gray pointers always encode the binary pointers.
            assert (wr_gray_q == bin2gray(wr_bin_q));
            assert (rd_gray_q == bin2gray(rd_bin_q));
            // Each domain's view of the other pointer is never ahead of the truth:
            // the pointer, then sync stage 0, 1, ... form a monotone chain behind it.
            assert ((wr_bin_q - gray2bin(wr_gray_sync_q[0])) <= f_fill);
            assert ((gray2bin(wr_gray_sync_q[0]) - wr_bin_in_rd)
                    <= (wr_bin_q - wr_bin_in_rd));
            assert ((wr_bin_in_rd - rd_bin_q) <= f_fill);
            assert ((rd_bin_q - gray2bin(rd_gray_sync_q[0])) <= PTR_W'(DEPTH) - f_fill);
            assert ((rd_bin_q - rd_bin_in_wr) <= PTR_W'(DEPTH) - f_fill);
            assert ((gray2bin(rd_gray_sync_q[0]) - rd_bin_in_wr) <= (rd_bin_q - rd_bin_in_wr));
        end
    end

    // Data integrity: tag one arbitrary written word; it must come out unchanged and in
    // order (the read pointer reaches its slot exactly once while it is live).
    (* anyseq *) logic f_pick;
    logic              f_armed = 1'b0, f_fetched = 1'b0, f_done = 1'b0;
    logic [PTR_W-1:0]  f_ptr;
    logic [DATA_W-1:0] f_data;

    always_ff @(posedge wr_clk_i) begin
        if (wr_rst_i) begin
            f_armed <= 1'b0;
        end else if (wr_fire && f_pick && !f_armed) begin
            f_armed <= 1'b1;
            f_ptr   <= wr_bin_q;
            f_data  <= s_tdata_i;
        end
    end

    always_ff @(posedge rd_clk_i) begin
        if (rd_rst_i) begin
            f_fetched <= 1'b0;
            f_done    <= 1'b0;
        end else begin
            if (f_armed && !f_fetched && rd_fetch && rd_bin_q == f_ptr) f_fetched <= 1'b1;
            if (f_fetched && m_tvalid_o && m_tready_i) f_done <= 1'b1;
        end
    end

    always_comb begin
        if (f_past_valid && !wr_rst_i && !rd_rst_i) begin
            if (f_fetched && !f_done) assert (m_tvalid_o && m_tdata_o == f_data);
            // While the tagged word is in the FIFO, its slot lies in [rd_bin, wr_bin).
            if (f_armed && !f_fetched) begin
                assert ((f_ptr - rd_bin_q) < f_fill);
                assert (mem[f_ptr[ADDR_W-1:0]] == f_data);
            end
            if (!f_armed) assert (!f_fetched);
            if (!f_fetched) assert (!f_done);
        end
    end
`endif
endmodule
`default_nettype wire
