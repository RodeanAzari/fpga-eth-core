# fpga-eth-core

Payload-agnostic 10/100 Ethernet (MII) MAC and IPv4/UDP RX/TX for Xilinx 7-series, written in
SystemVerilog. It knows nothing above the UDP payload interface. The OrderBook (P2), CCSDS
receiver (P3) and SerDes lab (P4) projects consume it as a git submodule at release tags.

**Status:** under construction toward `eth-core-v0.1` (the RX path). The consumer guide
(interfaces, clocking, resets, resource cost, example top level) lands with `eth-core-v0.2`.

| Block | File | Verified by |
|---|---|---|
| Async FIFO (Gray pointers) | `rtl/async_fifo.sv` | `make formal` (k-induction), `make sim` |
| MII RX (nibble→byte, SFD, T0 pulse) | `rtl/mii_rx.sv` | `make sim` |
| CRC-32 byte update | `rtl/crc32_d8.sv` | `make sim` (via FCS check, zlib reference) |
| FCS check + strip, frame status | `rtl/eth_fcs_check.sv` | `make sim` |
| FIFO overflow guard (per-frame loss count) | `rtl/rx_ovf_guard.sv` | `make sim` (via `eth_rx`) |
| Store-and-forward frame buffer | `rtl/frame_buffer.sv` | `make sim` (via `eth_rx`) |
| Eth/IPv4/UDP RX filter, runtime group/port | `rtl/udp_rx.sv` | `make sim` vs. independent RFC parser |
| **RX top:** MII → good frames in core domain | `rtl/eth_rx.sv` | `make sim`: MII-level frames, status accounting, forced overflow |

## Build

Requires Verilator ≥ 5.036, oss-cad-suite (Yosys and SymbiYosys), and Python with
`pip install -r requirements.txt` (cocotb 2.1, `tb-common` at a tag).

```
make lint     # verilator -Wall, zero warnings
make formal   # SymbiYosys proofs
make sim      # cocotb + Verilator
make ci       # all of the above
```
