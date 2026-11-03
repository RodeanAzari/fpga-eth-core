# fpga-eth-core

Payload-agnostic 10/100 Ethernet (MII) MAC and IPv4/UDP RX/TX for Xilinx 7-series, written in
SystemVerilog. It knows nothing above the UDP payload interface. The OrderBook (P2), CCSDS
receiver (P3) and SerDes lab (P4) projects consume it as a git submodule at release tags.

**Status:** under construction toward `eth-core-v0.1` (the RX path). The consumer guide
(interfaces, clocking, resets, resource cost, example top level) lands with `eth-core-v0.2`.

| Block | File | Verified by |
|---|---|---|
| Async FIFO (Gray pointers) | `rtl/async_fifo.sv` | `make formal` (k-induction), `make sim` |

## Build

Requires Verilator ≥ 5.036, oss-cad-suite (Yosys and SymbiYosys), and Python with cocotb 2.1.

```
make lint     # verilator -Wall, zero warnings
make formal   # SymbiYosys proofs
make sim      # cocotb + Verilator
make ci       # all of the above
```
