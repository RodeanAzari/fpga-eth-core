"""cocotb test for examples/rx_stats (the eth-core-v0.1 hardware harness).

Why this test matters: the hardware gate ("10 minutes, zero drops") is read off this
design's UART line. If a counter is wired to the wrong event, the sequence check misses
a gap, or the report garbles a field, the hardware result means nothing. So the test
sends known traffic over MII, including one deliberate sequence gap, one bad FCS and
one datagram for another port, decodes the UART line exactly as the host will, and
checks every field.

Simulation note: the MMCM stand-in passes CLK100MHZ straight through, so the core runs
at the 100 MHz input; the top is built with tiny CLK_HZ/BAUD/period parameters.
"""

from __future__ import annotations

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge
from eth import MiiDriver, MiiFrame, UdpFrame, with_fcs
from tb_common import get_rng

CLKS_PER_BIT = int(os.environ["CLK_HZ"]) // int(os.environ["BAUD"])
GROUP, PORT = 0xEF010101, 26400
FIELDS = ["uptime_s", "eth_ok", "crc_err", "rx_err", "runt", "oversize", "ovf_lost",
          "udp_ok", "udp_filtered", "ip_csum_err", "udp_malformed", "payload_bytes",
          "seq_err", "seq_lost", "fifo_hwm"]


async def uart_lines(dut, out: list[str]) -> None:
    """8N1 receiver on uart_rxd_out, sampling mid-bit in core clocks."""
    clk, line = dut.CLK100MHZ, ""
    while True:
        await FallingEdge(dut.uart_rxd_out)
        await ClockCycles(clk, CLKS_PER_BIT + CLKS_PER_BIT // 2)
        byte = 0
        for i in range(8):
            byte |= int(dut.uart_rxd_out.value) << i
            await ClockCycles(clk, CLKS_PER_BIT)
        assert int(dut.uart_rxd_out.value) == 1, "UART framing error (stop bit low)"
        line += chr(byte)
        if line.endswith("\r\n"):
            out.append(line)
            line = ""


def parse(line: str) -> dict[str, int]:
    parts = line.split()
    assert parts[0] == "RX" and len(parts) == 1 + len(FIELDS), f"bad line {line!r}"
    return {k: int(v, 16) for k, v in zip(FIELDS, parts[1:], strict=True)}


@cocotb.test()
async def counters_over_uart(dut):
    rng = get_rng("rx_stats")
    cocotb.start_soon(Clock(dut.CLK100MHZ, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.eth_rx_clk, 40, unit="ns").start())
    drv = MiiDriver(dut, dut.eth_rx_clk, rxd=dut.eth_rxd, dv=dut.eth_rx_dv, er=dut.eth_rxerr)
    dut.ck_rst.value = 1
    lines: list[str] = []
    cocotb.start_soon(uart_lines(dut, lines))

    await ClockCycles(dut.CLK100MHZ, 20)  # let the reset synchronizers assert
    assert int(dut.led[3].value) == 0 and int(dut.eth_rstn.value) == 0
    while not int(dut.led[3].value):  # MAC out of reset
        await RisingEdge(dut.CLK100MHZ)
    assert int(dut.eth_rstn.value) == 1

    seqs = list(range(1000, 1030)) + list(range(1031, 1060))  # 1030 never sent
    payload_bytes = 0
    for s in seqs:
        body = s.to_bytes(8, "big") + bytes(rng.randrange(256) for _ in range(rng.randint(0, 200)))
        payload_bytes += len(body)
        await drv.send(MiiFrame(with_fcs(UdpFrame(body, GROUP, PORT).build())))
    bad = bytearray(with_fcs(UdpFrame(bytes(20), GROUP, PORT).build()))
    bad[30] ^= 0x10
    await drv.send(MiiFrame(bytes(bad)))
    await drv.send(MiiFrame(with_fcs(UdpFrame(bytes(20), GROUP, PORT + 1).build())))

    n = len(lines)
    while len(lines) < n + 2:  # the first full line after the traffic
        await ClockCycles(dut.CLK100MHZ, 1000)
    got = parse(lines[-1])
    want = {"eth_ok": len(seqs) + 1, "crc_err": 1, "rx_err": 0, "runt": 0, "oversize": 0,
            "ovf_lost": 0, "udp_ok": len(seqs), "udp_filtered": 1, "ip_csum_err": 0,
            "udp_malformed": 0, "payload_bytes": payload_bytes, "seq_err": 1,
            "seq_lost": 1}
    for k, v in want.items():
        assert got[k] == v, f"{k}: UART says {got[k]}, expected {v}  ({lines[-1].strip()})"
    assert got["uptime_s"] >= 1 and 0 < got["fifo_hwm"] < 2048
    assert int(dut.led[2].value) == 1  # sticky error LED: the CRC error
    cocotb.log.info("UART: %s", lines[-1].strip())
