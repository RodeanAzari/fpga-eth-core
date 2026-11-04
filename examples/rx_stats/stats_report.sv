`default_nettype none
// stats_report: on every tick_i, snapshots N_FIELDS 32-bit counters and prints them as
// one ASCII line over the UART byte stream:
//   "RX" + N_FIELDS x (" " + 8 upper-case hex digits) + "\r\n"
// Field order is the caller's (documented in the top level). If a tick arrives while
// a line is still being sent, that tick is skipped (the next line still carries the
// cumulative counts, so nothing is lost but a sample).
module stats_report #(
    parameter int N_FIELDS = 4
) (
    input  wire logic                  clk_i,
    input  wire logic                  rst_i,
    input  wire logic                  tick_i,
    input  wire logic [N_FIELDS*32-1:0] fields_i,
    output logic [7:0]                 m_tdata_o,
    output logic                       m_tvalid_o,
    input  wire logic                  m_tready_i
);
    localparam int IDX_W = (N_FIELDS > 1) ? $clog2(N_FIELDS) : 1;
    localparam logic [7:0] CH_R = 8'h52, CH_X = 8'h58, CH_SP = 8'h20,
                           CH_CR = 8'h0D, CH_LF = 8'h0A;

    typedef enum logic [2:0] {S_IDLE, S_R, S_X, S_SP, S_HEX, S_CR, S_LF} state_t;
    state_t                  state_q;
    logic [N_FIELDS*32-1:0]  snap_q;
    logic [IDX_W-1:0]        field_q;
    logic [2:0]              nib_q;     // 0 = most significant nibble
    logic [31:0]             cur;
    logic [3:0]              nib;

    function automatic logic [7:0] hex(input logic [3:0] n);
        hex = (n < 4'd10) ? 8'h30 + {4'd0, n} : 8'h37 + {4'd0, n};  // '0'.. / 'A'..
    endfunction

    always_comb begin
        cur = snap_q[field_q*32 +: 32];
        nib = cur[(7 - nib_q)*4 +: 4];
        m_tvalid_o = state_q != S_IDLE;
        unique case (state_q)
            S_R:     m_tdata_o = CH_R;
            S_X:     m_tdata_o = CH_X;
            S_SP:    m_tdata_o = CH_SP;
            S_HEX:   m_tdata_o = hex(nib);
            S_CR:    m_tdata_o = CH_CR;
            S_LF:    m_tdata_o = CH_LF;
            default: m_tdata_o = 8'h00;
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (tick_i && state_q == S_IDLE) snap_q <= fields_i;
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q <= S_IDLE;
            field_q <= '0;
            nib_q   <= '0;
        end else if (state_q == S_IDLE) begin
            if (tick_i) state_q <= S_R;
        end else if (m_tready_i) begin
            unique case (state_q)
                S_R:  state_q <= S_X;
                S_X:  begin state_q <= S_SP; field_q <= '0; end
                S_SP: begin state_q <= S_HEX; nib_q <= '0; end
                S_HEX: begin
                    nib_q <= nib_q + 3'd1;
                    if (nib_q == 3'd7) begin
                        if (field_q == IDX_W'(N_FIELDS - 1)) begin
                            state_q <= S_CR;
                        end else begin
                            field_q <= field_q + IDX_W'(1);
                            state_q <= S_SP;
                        end
                    end
                end
                S_CR:    state_q <= S_LF;
                default: state_q <= S_IDLE;  // S_LF
            endcase
        end
    end
endmodule
`default_nettype wire
