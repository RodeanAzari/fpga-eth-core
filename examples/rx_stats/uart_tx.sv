`default_nettype none
// uart_tx: 8N1 transmitter, LSB first. AXI-Stream style byte input: a byte is taken
// when s_tvalid_i && s_tready_o. Line idles high. CLKS_PER_BIT = clk / baud.
// Latency: the start bit begins the cycle after the byte is accepted.
module uart_tx #(
    parameter int CLKS_PER_BIT = 1085   // 125 MHz / 115200
) (
    input  wire logic       clk_i,
    input  wire logic       rst_i,
    input  wire logic [7:0] s_tdata_i,
    input  wire logic       s_tvalid_i,
    output logic            s_tready_o,
    output logic            txd_o
);
    localparam int CNT_W = $clog2(CLKS_PER_BIT);
    localparam int FRAME_BITS = 10;  // start + 8 data + stop

    logic [9:0]       shift_q;      // {stop, data, start}, sent LSB first
    logic [3:0]       bits_left_q;
    logic [CNT_W-1:0] baud_q;

    assign s_tready_o = bits_left_q == '0;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            bits_left_q <= '0;
            baud_q      <= '0;
            txd_o       <= 1'b1;
        end else if (s_tready_o) begin
            txd_o <= 1'b1;
            if (s_tvalid_i) begin
                shift_q     <= {1'b1, s_tdata_i, 1'b0};
                bits_left_q <= 4'(FRAME_BITS);
                baud_q      <= '0;
            end
        end else begin
            txd_o <= shift_q[0];
            if (baud_q == CNT_W'(CLKS_PER_BIT - 1)) begin
                baud_q      <= '0;
                shift_q     <= {1'b1, shift_q[9:1]};
                bits_left_q <= bits_left_q - 4'd1;
            end else begin
                baud_q <= baud_q + CNT_W'(1);
            end
        end
    end
endmodule
`default_nettype wire
