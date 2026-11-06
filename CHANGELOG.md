# Changelog

Releases are tagged only after their gate test passes (see `~/fpga-coord/dependencies.toml`).

## Unreleased
- Nothing yet.

## eth-core-v0.2 — gate passed 2026-11-05, tag pending
- Gate (`dependencies.toml`): TX generic-payload echo test, lengths 1–1,472 B; host MAC/IP
  learning; consumer guide + non-ITCH example design.
- Test: `udp_echo` on the Arty A7-100T (100 Mbit/s FD), `udp_echo_check --pps 15000
  --seconds 600` (seed 1) from the host; every echo matched byte for byte.
- Result: PASS. 9,000,000 sent, 9,000,000 echoed intact (6,630,957,811 payload bytes),
  0 lost, 0 mismatched; every length 1–1,472 sent ≥ 5,782 times. Board: `udp_ok` =
  `tx_sent` = 9,000,000, every RX error counter 0, `tx_oversize` = `tx_underrun` = 0.
  Reply address learned from received frames (no ARP).
- Evidence: `data/results/2026-11-05_v0.2_udp_echo_sustained.{csv,md}`, raw UART log and
  checker output alongside. Consumer guide: README; non-ITCH examples: `rx_stats`, `udp_echo`.
- Consumers: TX interface as documented in the README consumer guide (payload length
  counted from tlast, no length input); nothing to change since v0.1.
- `host/udp_echo_check`: a datagram is lost only 1 s after sending without an intact echo
  (was: after 256 later datagrams), and the socket is drained before every send. On this
  host, intact echoes arriving > 256 datagrams late were miscounted as lost + mismatched.
  New loopback case (600 echoes released late) fails on the old checker.
- `host/rx_stats_csv.py --echo`: CSV for `udp_echo` UART logs.
- `examples/udp_echo/README.md`: the Hyper-V firewall rule needed under WSL2.

## eth-core-v0.1 — 2026-11-05
- Gate (`dependencies.toml`): RX link up, CRC, async FIFO formally proven, UDP payload out,
  >= 10 min sustained with zero drops, FIFO high-water mark reported.
- Test: `rx_stats` on the Arty A7-100T (100 Mbit/s FD), `udp_seq_send --pps 8000 --size 1472
  --seconds 610` from the host, counters over UART.
- Result: PASS. 4,880,000 sent, 4,880,000 delivered byte-exact; CRC, RX, runt, oversize,
  FIFO-overflow, IP-checksum and malformed counters all 0; RX FIFO high-water mark 1 byte.
  `seq_err` 3,976 is host-side reordering (pktmon: Windows I225-LM driver), not loss.
- Evidence: `data/results/2026-11-05_v0.1_rx_stats_sustained.{csv,md}`, raw UART log and
  sender summary alongside. Formal: `make formal` (see the `async_fifo` entry below).
- Consumers: RX interface as documented in the README consumer guide; nothing to change.
- Also added: `host/rx_stats_csv.py` (UART log → CSV).

### Contents at this tag
The TX path below is included but is hardware-gated only at `eth-core-v0.2`.

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
- **TX path (toward eth-core-v0.2).**
  - `mii_tx`: preamble/SFD, low nibble first, zero padding to 60 bytes, FCS, and exactly
    24 idle nibbles between back-to-back frames. The MII cannot stall, so an underrun
    ends the frame with a deliberately wrong FCS and pulses `underrun_o`. A truncated
    frame never goes out with a valid FCS.
  - `eth_tx`: core-domain frames → async FIFO → `mii_tx`. The underrun pulse returns to
    the core domain through a toggle synchronizer.
  - `udp_tx`: generic UDP payload in (AXI-Stream, tlast), Ethernet/IPv4/UDP frame out.
    The payload is buffered store-and-forward and its **length is counted from tlast**,
    so there is no length input (decided 2026-11-05: simpler for every consumer, and
    no length/tlast mismatch is possible). Destination MAC/IP/port and source port are
    sampled with the first beat; wire them to `udp_rx`'s `src_*` outputs to reply to a
    learned host. RFC 791 header checksum, DF set, ID 0, UDP checksum 0. `s_tuser` on
    tlast discards the payload; oversize (> 1,472 B) is dropped and counted.
  - cocotb:
    - `mii_tx`: 300 back-to-back frames of 1–1,514 B byte-exact against a zlib/padding
      image, IFG exactly 24. In the underrun test (80 frames), every starved frame went
      out with a bad FCS, `underrun_o` matched the spoiled count, and the following
      frames were perfect.
    - `udp_tx`: 539 frames parsed by an independent RFC reader with full-rate and
      backpressured input and output. Destination inputs are scrambled after the first
      beat, and directed cases exercise the checksum's second end-around carry.
      Sending is gapless (1 byte/cycle), oversize and discard are counted correctly.
  - 8 planted bugs each fail a test: high nibble first, IFG one short, FCS not spoiled
    on underrun, padding to 59, destination sampled at tlast, single-fold checksum, UDP
    length off by one, oversize not counted.
- `examples/udp_echo`: the second non-ITCH example and the v0.2 hardware harness. It
  echoes each datagram to the sender's learned MAC/IP/port and prints 15 counters over
  UART. cocotb end to end, MII pins to MII pins: 120 echoes of 1–1,472 B byte-exact to 4
  rotating senders; foreign and bad-FCS frames are not echoed; the UART counters are exact.
- `host/udp_echo_check` (C++20): paced sender of random-length (1–1,472 B) payloads,
  each regenerable from its index. Every echo is matched byte for byte; the summary
  reports lost / mismatched / reordered. `make host-test`: loopback against a Python
  echo server; an injected drop and an injected corruption are reported exactly.
- Build: `syn/build_example.tcl <rx_stats|udp_echo>` replaces `syn/build_rx_stats.tcl`;
  `make example-echo`. The `eth_tx_clk` pin is in `constr/arty_a7_100_pins_tx.xdc`
  (from the Digilent master XDC). MII TX output delays come from DP83848 SNLS250E
  T2.4.2/T2.4.3.
- `async_fifo`: the memory is now always block RAM (`ram_style = "block"`), and the Gray
  pointer registers are `DONT_TOUCH`. Found in the first `udp_echo` build, where
  `report_clock_interaction` flagged the core ↔ tx_clk crossings as "unsafe":
  - The 64-deep TX FIFO had mapped to distributed RAM. Its asynchronous read made the
    memory itself a fabric crossing (write clock → `m_tdata_o`), which only the Gray
    pointers' constraint was meant to cover.
  - Synthesis had merged `wr_gray_q[MSB]` into its equal `wr_bin_q[MSB]`, so the
    `*wr_gray_q_reg*` max-delay missed that bit and it was timed as a synchronous path.
    The RX FIFO escaped only because the merge happened to keep the Gray name.
  - With both changes, the Gray pointers are the only crossing in every instance, and
    `constr/async_fifo.xdc` is unchanged. Cost: at least one BRAM18 per FIFO. `eth_tx`'s
    FIFO default goes from 64 to 2,048 deep (one BRAM18 at 9 bits, a whole frame).
    Formal proof re-run. Vivado 2025.2: `udp_echo` WNS +0.312 ns at 125 MHz, MII TX
    output setup +20.645 ns, 1,119 LUT / 2,367 FF / 3 BRAM36, 0 critical warnings, every
    crossing "Max Delay Datapath Only" (`docs/reports/udp_echo/`). `rx_stats` rebuilt:
    WNS +0.348 ns (`docs/reports/rx_stats/`). Not yet run on hardware.
- `host/test_udp_seq_send.py`: checks each sequence number arrives once and the set is
  contiguous, instead of strict arrival order. WSL2 loopback reorders a few datagrams per
  20,000 (4 of 5 runs failed on 2026-11-05 with every datagram present). The planted
  little-endian and 32-bit-counter bugs still fail it. The hardware gate commands now pin
  the sender with `taskset`, so a multi-queue NIC cannot reorder on the wire.
