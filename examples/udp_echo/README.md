# udp_echo: transmit-path example and eth-core-v0.2 hardware harness

A second non-ITCH top level for the Digilent Arty A7-100T. It uses only fpga-eth-core's
documented interfaces: `eth_rx` → `udp_rx` → `udp_tx` → `eth_tx`. Every UDP datagram
received for one group/port is sent back unchanged to the sender's MAC/IP/port, which
`udp_rx` learns from the received frame, so no ARP is needed. The host checks every echo.

```
CLK100MHZ ─ clk_gen (MMCM) ─┬─ 125 MHz core
                            └─ 25 MHz ─ ODDR ─▶ eth_ref_clk (the PHY has no crystal)
PHY MII RX ─▶ eth_rx ─▶ udp_rx ──payload──▶ udp_tx ─▶ eth_tx ─▶ PHY MII TX (eth_tx_clk)
                          └── src MAC/IP/port ──┘ (reply address)
counters ─▶ stats_report ─▶ uart_tx
```

Shared helpers (`clk_gen`, `reset_sync`, `stats_report`, `uart_tx`) come from
`examples/rx_stats`.

## What the host does

Send UDP to 239.1.1.1:26400 (parameters `GROUP_IP`, `UDP_PORT`). The echo comes back from
192.168.10.2:26400 (`OWN_IP`, `UDP_PORT`) to the sending socket. `host/udp_echo_check`
sends payloads of random length (1 to 1,472 bytes, each one regenerable from its index)
and matches every echo byte for byte:

```
make host
taskset -c 2 build/host/udp_echo_check --dst 239.1.1.1 --port 26400 --if-ip <host IP on the cable> \
    --pps 10000 --seconds 600 > run.txt     # exit 0 only if echo_ok == sent
```

`taskset` pins the sender to one CPU. If the sending thread migrates, a multi-queue
NIC can put consecutive datagrams on different queues and reorder them on the wire.
Loopback on this host reorders a few per 20,000 for the same reason (see
`host/test_udp_seq_send.py`).

Host notes:
- The echo's source is 192.168.10.2. If the cable interface is on another subnet, a
  strict reverse-path filter (`rp_filter=1`) can drop it. Either put the interface on
  192.168.10.0/24 or relax `rp_filter` on it.
- Under WSL2 mirrored networking, the Hyper-V firewall blocks all inbound traffic to WSL
  by default, so no echo arrives (the board's `tx_sent` still counts them). Allow UDP
  from the board only, in an Administrator PowerShell:
  `New-NetFirewallHyperVRule -Name fpga-udp-echo -DisplayName "Arty UDP echo" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol UDP -RemoteAddresses 192.168.10.2 -Action Allow`
- On the WSL2 host, intact echoes were seen to arrive more than 256 datagrams late
  (tens of ms at 8,000–15,000/s); whether the receive path or a descheduled checker
  thread causes it is not established. `udp_echo_check` therefore declares a datagram
  lost only after 1 s without its echo.

Payloads average 736.5 bytes, about 802 bytes on the wire each with the 66 bytes of
overhead, so 100 Mbit/s carries roughly 15,500 datagrams/s each way.

## UART output (115200 8N1, one line per second)

`RX` followed by 15 fields of 8 hex digits, cumulative since the MAC left reset:

| # | Field | Meaning |
|---|---|---|
| 0 | uptime_s | seconds since the MAC left reset |
| 1 | eth_ok | good frames out of `eth_rx` (any destination) |
| 2 | crc_err | bad FCS |
| 3 | rx_err | PHY rx_er, or frame ended on an odd nibble |
| 4 | runt | < 64 bytes on the wire |
| 5 | oversize | > 1518 bytes after FCS strip |
| 6 | ovf_lost | frames lost to RX FIFO overflow |
| 7 | udp_ok | datagrams delivered for the group/port |
| 8 | udp_filtered | frames not for us |
| 9 | ip_csum_err | IPv4 header checksum wrong |
| 10 | udp_malformed | bad header or lengths |
| 11 | tx_sent | echo frames handed to the MAC (`udp_tx` `sent_o`) |
| 12 | tx_oversize | payloads too long to send (must be 0) |
| 13 | tx_underrun | frames spoiled by an MII underrun (must be 0) |
| 14 | fifo_hwm | RX async FIFO high-water mark, bytes (core-side view) |

**The gate passes** when `udp_echo_check` reports `echo_ok == sent`, `lost = 0` and
`mismatched = 0`, and the UART shows `udp_ok = tx_sent = sent`,
`ovf_lost = tx_oversize = tx_underrun = 0`.

LEDs: LD4 1 Hz heartbeat, LD5 echo activity, LD6 sticky error (any of fields 2, 3, 6, 9,
10, 12, 13 non-zero), LD7 MAC out of reset.

## Clock-domain crossings

| # | Signal | From → to | Synchronizer | Constraint |
|---|---|---|---|---|
| 1 | RX async FIFO write pointer (Gray) | rx_clk → core | 2-flop ASYNC_REG | `set_max_delay -datapath_only` (`constr/async_fifo.xdc`) |
| 2 | RX async FIFO read pointer (Gray) | core → rx_clk | 2-flop ASYNC_REG | same |
| 3 | TX async FIFO write pointer (Gray) | core → tx_clk | 2-flop ASYNC_REG | same |
| 4 | TX async FIFO read pointer (Gray) | tx_clk → core | 2-flop ASYNC_REG | same |
| 5 | `eth_tx` underrun toggle | tx_clk → core | 2-flop ASYNC_REG + edge detect | `set_max_delay -datapath_only 8 ns` |
| 6 | `!ck_rst \|\| !locked` → core reset | pin/MMCM → core | `reset_sync`, 3 flops | `set_false_path` to stage 0 |
| 7 | MAC reset request → rx_clk reset | core → rx_clk | `reset_sync`, 3 flops | same |
| 8 | MAC reset request → tx_clk reset | core → tx_clk | `reset_sync`, 3 flops | same |

Both FIFOs are block RAM (forced in `async_fifo`), so each FIFO's two memory ports sit
inside the RAM, with no fabric path between them; only the Gray pointers cross. The
first build of this example showed why that matters. Its 64-deep TX FIFO had mapped to
distributed RAM, whose asynchronous read is a fabric crossing, and synthesis had merged
a Gray register into its equal binary bit. Vivado flagged both as "unsafe" in
`report_clock_interaction`. See the CHANGELOG.

## MII transmit timing

The DP83848 (TI SNLS250E, 100 Mb/s MII transmit timing) needs TXD[3:0]/TX_EN set up
10 ns before the rising edge of TX_CLK (T2.4.2) and held 0 ns after it (T2.4.3).
TX_CLK comes from the PHY. `mii_tx` drives the pins from IOB flops on the rising edge,
and the constraints are in `constr/udp_echo_timing.xdc`.

## Build and run

```
make lint          # includes udp_echo_top (Xilinx primitives from tb/models/)
make sim           # tb/test_udp_echo.py: MII frames in, echoes decoded from the TX pins
make example-echo  # Vivado batch build (run vivado-env first); reports in docs/reports/udp_echo/
```

## Results

From `make example-echo` with Vivado 2025.2, xc7a100tcsg324-1, 125 MHz core clock:

| | Value | Source |
|---|---|---|
| Timing | WNS +0.312 ns (core), WHS +0.060 ns, all constraints met; every crossing classified "Max Delay Datapath Only" | [timing_summary.rpt](../../docs/reports/udp_echo/timing_summary.rpt) |
| MII output setup margin | +20.645 ns (DP83848 T2.4.2: 10 ns setup to TX_CLK); input setup +6.299 ns (T2.5.2) | same |
| Utilization (whole example) | 1,119 LUT, 2,367 FF, 3 BRAM36 tiles (`udp_tx` and `eth_tx` one BRAM18 each), 1 MMCM | [utilization.rpt](../../docs/reports/udp_echo/utilization.rpt) |
| Simulation: echo, 1..1472 B | 120 echoes byte-exact to 4 rotating senders; 12 foreign + 12 bad-FCS frames not echoed; counters exact | `tb/test_udp_echo.py` |
| Hardware: echo gate | [TBD] | — |
