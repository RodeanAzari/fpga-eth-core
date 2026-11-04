`default_nettype none
// crc32_d8: one-byte update of the Ethernet CRC-32 (IEEE 802.3 clause 3.2.9).
//
// Reflected form: polynomial 0x04C11DB7 bit-reversed to 0xEDB88320, data LSB first.
// The caller holds the register, initialises it to 0xFFFFFFFF, and either
//   - TX: sends ~crc LSB-byte first as the FCS, or
//   - RX: runs the update over data AND FCS; a good frame leaves 0xDEBB20E3.
// Purely combinational (8 unrolled shift steps, ~3 LUT levels); latency 0 cycles.
module crc32_d8 (
    input  wire logic [31:0] crc_i,
    input  wire logic [7:0]  data_i,
    output logic      [31:0] crc_o
);
    localparam logic [31:0] POLY_REFLECTED = 32'hEDB8_8320;

    always_comb begin
        crc_o = crc_i ^ {24'd0, data_i};
        for (int i = 0; i < 8; i++) begin
            crc_o = crc_o[0] ? ((crc_o >> 1) ^ POLY_REFLECTED) : (crc_o >> 1);
        end
    end
endmodule
`default_nettype wire
