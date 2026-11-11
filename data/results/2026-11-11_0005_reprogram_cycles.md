# fpga-coord 0005: reprogram-then-stream cycles (2026-11-11) — fix NOT demonstrated

Question: does holding the MAC in reset until MDIO reports link up (`mdio_link_mon`,
commit `4276c33`) stop the RX FIFO corruption P3 reported after reprogramming
(`fifo_level_o` 4095, impossible frame counts)?

**Answer so far: unknown.** The harness never reproduced the fault on the ungated design
(0/100), so a clean gated run cannot show the fix works; and the only corruption seen
was on the gated design.

| | |
|---|---|
| Harness | `scripts/reprogram_cycles.sh` (this commit): program, wait for the MAC to run (UART `uptime_s` ≥ 1), stream `udp_seq_send` (1,472-byte payloads), read the last UART report. Pass: fresh design, `fifo_hwm` ≤ 2,048, `udp_ok` = sent, `seq_err` = `seq_lost` = `ovf_lost` = `crc_err` = `rx_err` = 0 |
| Gated bitstream | `rx_stats` at `06a9a6d` (with `mdio_link_mon`), SHA-256 prefix `1d381ad7165d0608`, WNS +0.197 ns |
| Control bitstream | `rx_stats` at `eth-core-v0.2` (MAC starts 200 ms after lock, no link gate), SHA-256 prefix `27ccfaa332acbf11`, WNS +0.348 ns |
| Programmer | openFPGALoader v1.1.1 (`-b arty_a7_100t`, SRAM); run 1's first cycle used Vivado 2025.2 (`PROG=vivado`, ~2.5 min per cycle under load, replaced) |
| Host | WSL2, ASIX AX88179 via usbipd, 192.168.10.1, `pfifo`; load average ~13 (other sessions) |

## Runs

| Run | Build | Cycles | Rate | Passed | Corrupted (`fifo_hwm` > 2,048) | Other failures |
|---|---|---|---|---|---|---|
| 1 `_run1_no_logs.csv` | gated | 100 | 8,000 pps × 8,000 | 87 | **1 (cycle 69)** | 12: 2–92 datagrams missing, no FPGA error counter |
| 2 `_run2_settle3.csv` | gated, 3 s settle before sending | 50 | 8,000 pps × 8,000 | 48 | 0 | 2: 106 and 1 missing |
| 3 `_run3_gated_2kpps.csv` | gated | 100 | 2,000 pps × 4,000 | **100** | 0 | 0 |
| 4 `_run4_control_v02_2kpps.csv` | control (v0.2) | 100 | 2,000 pps × 4,000 | 70 | **0** | 30: first datagrams sent before link up (harness artifact, below) |

Per-cycle UART streams, programmer and sender output: `<run>.d/` (runs 2–4).

## Interpretation

- **Cycle 69 (run 1)** read `fifo_hwm` 4095 and `eth_ok` 311,515,485 in ~4 s (78 M/s; the
  RTL ceiling is ~2 M/s), the signature P3 reported. But its first report came 0.85 s after
  programming (every other cycle in run 1 ≥ 3.7 s) and `uptime_s` read 13 after ~4.4 s: most
  likely the new bitstream did not take and cycle 68's design (up ~9 s) kept running and
  corrupted without any reprogram or link event. Run 1 kept no logs, so this is not
  confirmed. If true, reset gating at link-up cannot be the whole cure.
- **The control never corrupted** in 100 reprograms with the MAC out of reset ~2 s before
  link up, the scenario P3 described (P3: 7/60 replays, 1/20 traffic-free). So this
  harness, board and host do not reproduce the fault on demand; run 3's 100/100 does not
  demonstrate the fix.
- **Missing datagrams with no FPGA error counter** (runs 1, 2) are frames that never
  reached eth_rx: the sender at 98 % of line rate through a USB adapter on a loaded host.
  They disappear at 2,000 pps (run 3). Not related to 0005.
- **Run 4's 30 failures are the harness:** without the gate, "MAC up" is not "link up",
  so the sender started before the link existed; the first ~200–2,200 datagrams were lost
  on the host (`seq_lost` 0: the FPGA's baseline is the first datagram it sees; cycle 77
  saw none). The corruption check (`fifo_hwm`) is unaffected.

## Next (not done)

- Reproduce first: get P3's exact conditions (their bitstream's start-up timing, core
  clock 100 MHz vs 125 here, Vivado programming, link-up ≥ 3.1 s) or trigger link flaps
  on a running design (unplug/replug, host `ip link set down/up`) with logs on.
- Cycle 69 suggests a fault in a running design; instrument it (ILA on the async FIFO
  pointers and rx_clk) rather than more blind cycles.
