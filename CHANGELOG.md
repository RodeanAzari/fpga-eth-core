# Changelog

Releases are tagged only after their gate test passes (see `~/fpga-coord/dependencies.toml`).

## Unreleased
- `async_fifo`: dual-clock Gray-pointer FIFO, AXI-Stream on both sides, first-word-fall-through
  read, write-side and read-side occupancy outputs.
  - Formal (`make formal`): no overflow or underflow, Gray encoding, synchronizer-chain
    monotonicity, data integrity of an arbitrary tagged word. k-induction PASS at depth 24
    on a depth-4 instance; cover of full and drained-empty reached.
  - Three planted bugs each fail the proof: write allowed at full, binary (non-Gray)
    read pointer, read from the wrong address.
  - cocotb (`make sim`): 3 clock-ratio and backpressure scenarios at depth 16 and 2048,
    3,000 random words each, in order, full reached exactly at DEPTH.
- `mii_rx`: MII nibble->byte (low nibble first), preamble/SFD hunt, `sfd_o` T0 pulse,
  tuser on the last byte for rx_er or an odd final nibble. cocotb: 300 random frames
  1-1522 B with preamble 1-15 nibbles and IFG down to 1 clock; 100 error frames; false
  carrier ignored.
- `crc32_d8` + `eth_fcs_check`: FCS checked against residue 0xDEBB20E3 and stripped; one
  status pulse per frame (ok / crc_err / rx_err / runt < 64 B). cocotb: 400 mixed frames
  at full rate and under random backpressure, plus boundary lengths (1-5, 63, 64, 1518 B).
- Planted bugs (reversed nibble order; wrong CRC residue) fail all 6 new tests.
- Tests use `tb-common` at `tb-common-v0.1` (pinned in `requirements.txt`).
