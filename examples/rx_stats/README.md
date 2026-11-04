# rx_stats: receive-path example and eth-core-v0.1 hardware harness

A non-ITCH top level for the Digilent Arty A7-100T that uses only fpga-eth-core's
documented RX interface (`eth_rx` → `udp_rx`). It receives UDP datagrams for one
group/port, checks a sequence number in each payload, and prints every counter over the
USB-UART once per second.

```
CLK100MHZ ─ clk_gen (MMCM) ─┬─ 125 MHz core
                            └─ 25 MHz ─ ODDR ─▶ eth_ref_clk (the PHY has no crystal)
PHY MII ─▶ eth_rx ─▶ udp_rx ─▶ sequence check + counters ─▶ stats_report ─▶ uart_tx
```

## Payload contract (what the host sends)

UDP to 239.1.1.1:26400 (parameters `GROUP_IP`, `UDP_PORT`). Payload bytes 0–7 are a
big-endian sequence number that increases by 1 per datagram; the rest is arbitrary.

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
| 11 | payload_bytes | UDP payload bytes delivered (mod 2^32) |
| 12 | seq_err | datagrams whose sequence was not previous + 1 |
| 13 | seq_lost | sum of forward sequence gaps |
| 14 | fifo_hwm | RX async FIFO high-water mark, bytes (core-side view, may read 2–3 low) |

**Zero drops** for the gate means: `seq_err = seq_lost = ovf_lost = 0` and
`udp_ok` = datagrams the host sent.

LEDs: LD4 1 Hz heartbeat, LD5 datagram activity, LD6 sticky error (any of fields 2, 3,
6, 9, 10, 12 non-zero), LD7 MAC out of reset. The red RESET button restarts everything.

## Clock-domain crossings

| # | Signal | From → to | Synchronizer | Constraint |
|---|---|---|---|---|
| 1 | async FIFO write pointer (Gray) | rx_clk → core | 2-flop ASYNC_REG | `set_max_delay -datapath_only` (`constr/async_fifo.xdc`) |
| 2 | async FIFO read pointer (Gray) | core → rx_clk | 2-flop ASYNC_REG | same |
| 3 | `!ck_rst \|\| !locked` → core reset | pin/MMCM → core | `reset_sync`, 3 flops | `set_false_path` to stage 0 |
| 4 | MAC reset request → rx_clk reset | core → rx_clk | `reset_sync`, 3 flops | `set_false_path` to stage 0 |

The FIFO memory is one BRAM; its write and read ports sit in their own clock domains
with no fabric path between them. Vivado's `report_cdc` lists 1–2 above as CDC-6
("multi-bit synchronized"): expected for Gray-coded pointers, which change one bit per
step.

## Build and run

```
make lint          # includes rx_stats_top (Xilinx primitives from tb/models/)
make sim           # tb/test_rx_stats.py: MII traffic in, UART line decoded and checked
make example       # Vivado batch build (run vivado-env first); reports in docs/reports/rx_stats/
```

## Results

From `make example` with Vivado 2025.2, xc7a100tcsg324-1, 125 MHz core clock:

| | Value | Source |
|---|---|---|
| Timing | WNS +0.663 ns (core), WHS +0.035 ns, all constraints met | [timing_summary.rpt](../../docs/reports/rx_stats/timing_summary.rpt) |
| Worst path | `udp_rx` verdict logic (`ip_totlen_q` → `ip_csum_err_o`) | same |
| MII input setup margin | +6.299 ns (DP83848 T2.5.2: RX_CLK→data 10–30 ns) | same |
| Utilization (whole example) | 892 LUT, 1,710 FF, 2 BRAM36 tiles, 1 MMCM, 3 BUFG | [utilization.rpt](../../docs/reports/rx_stats/utilization.rpt) |
| Hardware: link up, sustained stream | [TBD] | — |
