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
- `rx_ovf_guard`: MII-domain guard in front of the async FIFO. A frame that loses a byte is
  discarded; an abort beat (tlast, tuser[1], tdata = frames lost) then reaches the core
  domain, so overflow is counted per frame, never silent.
- `frame_buffer`: store-and-forward; releases a frame only after a good tlast verdict,
  rewinds on bad, drops oversize (> MAX_FRAME) frames without deadlock.
- `eth_rx`: top of the RX path (mii_rx -> guard -> async FIFO -> FCS check -> buffer).
  Exactly one status pulse per frame with an SFD: ok / crc_err / rx_err / runt / oversize
  / ovf (+ lost-frame count). cocotb at FIFO depth 2048 and 16: 400 mixed frames from MII
  nibbles, good frames byte-exact and in order, every status count exact; forced overflow:
  sent = delivered + lost, no corrupted frame delivered.
- Planted bugs (guard undercounts lost frames; buffer releases bad frames) each fail.
- `udp_rx`: Ethernet II / IPv4 / UDP filter with runtime `cfg_mac`/`cfg_ip`/`cfg_port`
  (multicast MAC derived from the group per RFC 1112, or own MAC for unicast). IHL
  options skipped, header checksum verified, fragments rejected, Ethernet padding
  stripped by UDP length, sender MAC/IP/port latched for TX learning. One status per
  frame: ok / filtered / ip_csum_err / malformed. cocotb: 1,618 frames judged by an
  independent RFC parser across 4 runtime configs with backpressure; planted bugs
  (checksum ignored, padding leak, 24-bit multicast mapping) each fail.
- `examples/rx_stats`: Arty A7-100T receive harness (MMCM 125 MHz core + ODDR-forwarded
  25 MHz PHY reference, reset sequencing, eth_rx + udp_rx, payload sequence check, 15
  counters over UART once per second). cocotb: MII traffic in, UART line decoded and
  every field checked (planted counter swap fails). Vivado 2025.2: timing met, WNS
  +0.663 ns at 125 MHz, MII input setup +6.3 ns, 892 LUT / 1,710 FF / 2 BRAM36
  (`docs/reports/rx_stats/`). Not yet run on hardware.
- `async_fifo`: `rd_gray_q` declared before use (Vivado warning); XDC pointer filter
  limited to sequential cells. Formal proof re-run: PASS.
- Tests use `tb-common` at `tb-common-v0.1` (pinned in `requirements.txt`).
- `host/udp_seq_send` (C++20): paced UDP sender with a big-endian 64-bit sequence number
  per datagram (the rx_stats payload contract); retries host queue-full with the same
  sequence number; key=value summary for results sidecars. `make host-test`: 20,000
  datagrams over loopback, every one checked; fails on planted little-endian encoding
  and a 32-bit counter.
