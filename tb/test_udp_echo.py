"""cocotb test for examples/udp_echo (the eth-core-v0.2 hardware harness), end to end
from MII RX pins to MII TX pins.

Why this test matters: it is the simulation twin of the v0.2 gate. It proves the
generic TX path with payloads of every length 1..1472 bytes, and that replies go to the
address learned from the received traffic. Several hosts (random MAC/IP/port) send in
turn, so a reply sent to the wrong (previous) sender fails. Foreign traffic (wrong
port, bad FCS) must produce no echo; every echo must be a frame a real NIC accepts
(preamble, FCS, IPv4 checksum all verified independently), and the UART counters must
account for every frame.

Simulation note: the MMCM stand-in passes CLK100MHZ through, so the core runs at
100 MHz; rx_clk and tx_clk are independent 25 MHz clocks with different phases.
"""

from __future__ import annotations

import os
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer
from eth import MiiDriver, MiiFrame, MiiTxMonitor, UdpFrame, with_fcs
from tb_common import InOrderScoreboard, get_rng
from test_rx_stats import uart_lines
from test_udp_tx import parse as parse_udp

GROUP, PORT = 0xEF010101, 26400
OWN_MAC, OWN_IP = bytes.fromhex("02000a0b0c0d"), 0xC0A80A02
FIELDS = ["uptime_s", "eth_ok", "crc_err", "rx_err", "runt", "oversize", "ovf_lost",
          "udp_ok", "udp_filtered", "ip_csum_err", "udp_malformed", "tx_sent",
          "tx_oversize", "tx_underrun", "fifo_hwm"]
GOOD_RESIDUE = 0x2144DF1C  # zlib.crc32 over data + a correct FCS


def parse_line(line: str) -> dict[str, int]:
    parts = line.split()
    assert parts[0] == "RX" and len(parts) == 1 + len(FIELDS), f"bad line {line!r}"
    return {k: int(v, 16) for k, v in zip(FIELDS, parts[1:], strict=True)}


@cocotb.test()
async def echo_all_lengths(dut):
    rng = get_rng("udp_echo")
    cocotb.start_soon(Clock(dut.CLK100MHZ, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.eth_rx_clk, 40, unit="ns").start())
    await Timer(13, unit="ns")  # tx_clk: same frequency, unrelated phase
    cocotb.start_soon(Clock(dut.eth_tx_clk, 40, unit="ns").start())
    drv = MiiDriver(dut, dut.eth_rx_clk, rxd=dut.eth_rxd, dv=dut.eth_rx_dv, er=dut.eth_rxerr)
    mon = MiiTxMonitor(dut.eth_tx_clk, dut.eth_txd, dut.eth_tx_en)
    cocotb.start_soon(mon.run())
    lines: list[str] = []
    dut.ck_rst.value = 1
    cocotb.start_soon(uart_lines(dut, lines))
    await ClockCycles(dut.CLK100MHZ, 20)
    while not int(dut.led[3].value):
        await RisingEdge(dut.CLK100MHZ)

    hosts = [(bytes([0x02]) + bytes(rng.randrange(256) for _ in range(5)),
              rng.randrange(1 << 32), rng.randrange(1024, 65536)) for _ in range(4)]
    sb = InOrderScoreboard("udp_echo", fmt=lambda x: f"dst={x[0].hex()} len={len(x[6])}")
    lengths = [1, 2, 17, 18, 1472] + [rng.randint(1, 1472) for _ in range(115)]
    n_echo = n_foreign = n_crc = 0
    for k, ln in enumerate(lengths):
        mac, ip, port = hosts[k % len(hosts)] if k % 7 else hosts[rng.randrange(len(hosts))]
        payload = bytes(rng.randrange(256) for _ in range(ln))
        frame = with_fcs(UdpFrame(payload, GROUP, PORT, src_mac=mac, src_ip=ip,
                                  src_port=port).build())
        await drv.send(MiiFrame(frame, ifg=rng.randint(24, 60)))
        sb.expect((mac, OWN_MAC, OWN_IP, ip, PORT, port, payload))
        n_echo += 1
        if k % 10 == 3:  # foreign traffic between echoes: no reply allowed
            other = with_fcs(UdpFrame(payload, GROUP, PORT + 1, src_mac=mac).build())
            await drv.send(MiiFrame(other))
            n_foreign += 1
        if k % 10 == 6:
            bad = bytearray(frame)
            bad[rng.randrange(len(bad))] ^= 0x01
            await drv.send(MiiFrame(bytes(bad)))
            n_crc += 1

    for _ in range(400):  # up to ~20 ms of sim for the last echoes
        if len(mon.frames) >= n_echo:
            break
        await ClockCycles(dut.eth_tx_clk, 1000)
    await ClockCycles(dut.eth_tx_clk, 2000)

    gaps = [f.idle_before for f in mon.frames[1:]]
    for k, wf in enumerate(mon.frames):
        data, framing = wf.decode()
        assert framing, f"echo {k}: bad preamble/nibble framing"
        assert zlib.crc32(data) == GOOD_RESIDUE, f"echo {k}: FCS does not check"
        # Trim the 802.3 padding the way a host does, by the IPv4 total length; the
        # padding must be zeros and only present to reach the 60-byte minimum.
        body = data[:-4]
        end = 14 + int.from_bytes(body[16:18], "big")
        assert body[end:] == bytes(len(body) - end), f"echo {k}: non-zero padding"
        assert len(body) == max(end, 60), f"echo {k}: {len(body)} bytes for IP length {end - 14}"
        sb.observe(parse_udp(body[:end]))
    sb.check_done()
    assert min(gaps) >= 24, f"IFG below 96 bit times: {min(gaps)}"

    # The next UART line after all traffic must account for every frame.
    n_lines = len(lines)
    while len(lines) < n_lines + 2:
        await ClockCycles(dut.CLK100MHZ, 1000)
    c = parse_line(lines[-1])
    want = {"eth_ok": n_echo + n_foreign, "crc_err": n_crc, "udp_ok": n_echo,
            "udp_filtered": n_foreign, "tx_sent": n_echo, "rx_err": 0, "runt": 0,
            "oversize": 0, "ovf_lost": 0, "ip_csum_err": 0, "udp_malformed": 0,
            "tx_oversize": 0, "tx_underrun": 0}
    got = {k: c[k] for k in want}
    assert got == want, f"UART counters {got} != {want}"
    cocotb.log.info("echo: %d echoed (1..1472 B), %d foreign, %d bad FCS; fifo_hwm %d",
                    n_echo, n_foreign, n_crc, c["fifo_hwm"])
