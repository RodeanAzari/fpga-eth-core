`default_nettype none
// Formal harness for async_fifo: two free-running, independent clocks derived from the
// global formal clock, and a reset that both domains see for at least one edge.
module async_fifo_fv;
    localparam int DATA_W = 4;
    localparam int ADDR_W = 2;

    (* gclk *) logic gclk;
    (* anyseq *) logic step_wr, step_rd;
    (* anyseq *) logic [DATA_W-1:0] s_tdata;
    (* anyseq *) logic s_tvalid, m_tready;

    logic wr_clk = 1'b0, rd_clk = 1'b0;
    logic [2:0] init_cnt = '0;
    logic rst;
    assign rst = (init_cnt != 3'd7);

    // During reset both clocks toggle every global step, so each domain sees reset edges.
    always_ff @(posedge gclk) begin
        if (rst) init_cnt <= init_cnt + 3'd1;
        wr_clk <= rst ? !wr_clk : (wr_clk ^ step_wr);
        rd_clk <= rst ? !rd_clk : (rd_clk ^ step_rd);
    end

    logic s_tready, m_tvalid;
    logic [DATA_W-1:0] m_tdata;
    logic [ADDR_W:0] wr_level, rd_level;

    async_fifo #(.DATA_W(DATA_W), .ADDR_W(ADDR_W), .SYNC_STAGES(2)) dut (
        .wr_clk_i(wr_clk), .wr_rst_i(rst), .s_tdata_i(s_tdata), .s_tvalid_i(s_tvalid),
        .s_tready_o(s_tready), .wr_level_o(wr_level),
        .rd_clk_i(rd_clk), .rd_rst_i(rst), .m_tdata_o(m_tdata), .m_tvalid_o(m_tvalid),
        .m_tready_i(m_tready), .rd_level_o(rd_level)
    );

    // AXI-Stream source rules on the write side: valid/data hold until accepted.
    logic f_past = 1'b0;
    logic wr_clk_q = 1'b0;
    logic s_tvalid_q = 1'b0, s_tready_q = 1'b0;
    logic [DATA_W-1:0] s_tdata_q;
    always_ff @(posedge gclk) begin
        f_past     <= 1'b1;
        wr_clk_q   <= wr_clk;
        s_tvalid_q <= s_tvalid;
        s_tready_q <= s_tready;
        s_tdata_q  <= s_tdata;
    end
    // Inputs only change right after a rising write-clock edge.
    always_comb begin
        if (f_past && !(wr_clk && !wr_clk_q)) begin
            assume (s_tvalid == s_tvalid_q);
            assume (s_tdata == s_tdata_q);
        end
    end

    // Liveness-flavoured cover: the FIFO fills and drains.
    always_comb begin
        if (!rst) begin
            cover (wr_level == 3'd4);
            cover (m_tvalid && m_tready && rd_level == 3'd0 && wr_level == 3'd0);
        end
    end
endmodule
`default_nettype wire
