"""Build and run the cocotb tests with Verilator: python tb/run.py [test_module ...]"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parent.parent

# test module -> (toplevel, sources, parameter sets)
TESTS = {
    "test_async_fifo": (
        "async_fifo",
        ["rtl/async_fifo.sv"],
        [{"DATA_W": 8, "ADDR_W": 4}, {"DATA_W": 8, "ADDR_W": 11}],
    ),
    "test_mii_rx": ("mii_rx", ["rtl/mii_rx.sv"], [{}]),
    "test_eth_fcs_check": (
        "eth_fcs_check",
        ["rtl/crc32_d8.sv", "rtl/eth_fcs_check.sv"],
        [{}],
    ),
    "test_eth_rx": (
        "eth_rx",
        ["rtl/mii_rx.sv", "rtl/rx_ovf_guard.sv", "rtl/async_fifo.sv", "rtl/crc32_d8.sv",
         "rtl/eth_fcs_check.sv", "rtl/frame_buffer.sv", "rtl/eth_rx.sv"],
        [{"FIFO_ADDR_W": 11, "BUF_ADDR_W": 12, "CUT_THROUGH": 0},
         {"FIFO_ADDR_W": 4, "BUF_ADDR_W": 11, "CUT_THROUGH": 0},
         {"FIFO_ADDR_W": 11, "BUF_ADDR_W": 12, "CUT_THROUGH": 1},
         {"FIFO_ADDR_W": 4, "BUF_ADDR_W": 11, "CUT_THROUGH": 1}],
    ),
    "test_udp_rx": ("udp_rx", ["rtl/udp_rx.sv"], [{}]),
    "test_mdio_link_mon": (
        "mdio_link_mon",
        ["rtl/mdio_link_mon.sv"],
        # Real clock and MDC rates; only the poll period is shortened (30 us). PHY_ADDR 5
        # as well as the Arty's 1: with 1, a swapped PHYAD/REGAD (BMSR = 1) is invisible.
        [{"POLL_CYCLES": 3000}, {"POLL_CYCLES": 3000, "PHY_ADDR": 5}],
    ),
    "test_mii_tx": ("mii_tx", ["rtl/crc32_d8.sv", "rtl/mii_tx.sv"], [{}]),
    "test_udp_tx": ("udp_tx", ["rtl/udp_tx.sv"], [{}]),
    "test_rx_stats": (
        "rx_stats_top",
        ["tb/models/MMCME2_BASE.sv", "tb/models/BUFG.sv", "tb/models/ODDR.sv",
         "examples/rx_stats/xilinx/clk_gen.sv", "examples/rx_stats/reset_sync.sv",
         "examples/rx_stats/uart_tx.sv", "examples/rx_stats/stats_report.sv",
         "rtl/mdio_link_mon.sv",
         "rtl/mii_rx.sv", "rtl/rx_ovf_guard.sv", "rtl/async_fifo.sv", "rtl/crc32_d8.sv",
         "rtl/eth_fcs_check.sv", "rtl/frame_buffer.sv", "rtl/eth_rx.sv", "rtl/udp_rx.sv",
         "examples/rx_stats/rx_stats_top.sv"],
        # Tiny timing so the sim is short: 4 clocks per UART bit, 3 ms report period.
        [{"CLK_HZ": 1_000_000, "BAUD": 250_000, "REPORT_CYCLES": 300_000,
          "PHY_RST_CYCLES": 100, "MAC_START_CYCLES": 400,
          "MDC_HZ": 125_000, "LINK_POLL_CYCLES": 600}],
    ),
    "test_udp_echo": (
        "udp_echo_top",
        ["tb/models/MMCME2_BASE.sv", "tb/models/BUFG.sv", "tb/models/ODDR.sv",
         "examples/rx_stats/xilinx/clk_gen.sv", "examples/rx_stats/reset_sync.sv",
         "examples/rx_stats/uart_tx.sv", "examples/rx_stats/stats_report.sv",
         "rtl/mdio_link_mon.sv",
         "rtl/mii_rx.sv", "rtl/rx_ovf_guard.sv", "rtl/async_fifo.sv", "rtl/crc32_d8.sv",
         "rtl/eth_fcs_check.sv", "rtl/frame_buffer.sv", "rtl/eth_rx.sv", "rtl/udp_rx.sv",
         "rtl/udp_tx.sv", "rtl/mii_tx.sv", "rtl/eth_tx.sv",
         "examples/udp_echo/udp_echo_top.sv"],
        [{"CLK_HZ": 1_000_000, "BAUD": 250_000, "REPORT_CYCLES": 300_000,
          "PHY_RST_CYCLES": 100, "MAC_START_CYCLES": 400,
          "MDC_HZ": 125_000, "LINK_POLL_CYCLES": 600}],
    ),
}


def main(names: list[str]) -> int:
    failed = 0
    for name in names or list(TESTS):
        top, srcs, param_sets = TESTS[name]
        for params in param_sets:
            tag = "_".join(f"{k}{v}" for k, v in params.items()) or "default"
            build_dir = ROOT / "build" / "sim" / f"{name}_{tag}"
            runner = get_runner("verilator")
            runner.build(
                sources=[ROOT / s for s in srcs],
                hdl_toplevel=top,
                parameters=params,
                # --pins-inout-enables: a top-level inout (eth_mdio) becomes a pure input
                # plus __out/__en outputs, so the testbench can resolve the wired bus.
                # Without it, Verilator reads a released ('z) pad as 0, never the PHY.
                build_args=["--assert", "-Wall", "-Wno-fatal", "--timing",
                            "--pins-inout-enables"],
                build_dir=build_dir,
                always=True,
            )
            os.environ.update({k: str(v) for k, v in params.items()})
            results = runner.test(
                hdl_toplevel=top,
                test_module=name,
                test_dir=ROOT / "tb",
                build_dir=build_dir,
            )
            from cocotb_tools.runner import get_results

            _, fails = get_results(results)
            failed += fails
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
