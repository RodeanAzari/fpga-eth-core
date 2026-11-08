"""cocotb tests for mdio_link_mon (MDIO clause-22 BMSR poller -> debounced link_up_o).

Why these tests matter: consumers hold eth_rx in reset until link_up_o (fpga-coord
request 0005: the RX FIFO came up corrupted when the PHY linked after the MAC left
reset). So link_up_o must never claim a link the PHY did not report, must drop on the
first read that shows a loss (BMSR link status is latched-low, 802.3 22.2.4.2.13), and
must not be fooled by an absent PHY, whose pulled-up MDIO line reads all ones.

The PHY model (eth.Clause22Phy) implements 802.3 clause 22 from the standard, not from
the RTL, and answers at the DP83848's worst-case 300 ns output delay. Two parameter sets:
PHY_ADDR 1 (the Arty) and 5, because with address 1 a swapped PHYAD/REGAD (BMSR is
register 1) would go unnoticed.
"""

from __future__ import annotations

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from eth import Clause22Phy
from tb_common import get_rng

CLK_NS = 10            # 100 MHz, as on the Arty
POLL_CYCLES = int(os.environ["POLL_CYCLES"])
PHY_ADDR = int(os.environ.get("PHY_ADDR", "1"))
READ_CYCLES = 64 * 40  # 64 MDC periods of 400 ns


async def _setup(dut, addr: int = PHY_ADDR):
    cocotb.start_soon(Clock(dut.clk_i, CLK_NS, unit="ns").start())
    dut.mdio_i.value = 1
    phy = Clause22Phy(dut.mdc_o, dut.mdio_oe_o, dut.mdio_o, dut.mdio_i, addr)
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 4)
    dut.rst_i.value = 0
    return phy


async def _polls(dut, n: int):
    await ClockCycles(dut.clk_i, n * POLL_CYCLES)


@cocotb.test()
async def frame_is_clause22_bmsr_read(dut):
    """Each poll is 32 ones, ST=01, OP=10 (read), PHYAD, REGAD=1, at MDC <= 2.5 MHz."""
    phy = await _setup(dut)
    # MDC period: time between rising edges must be >= 400 ns.
    await RisingEdge(dut.mdc_o)
    t0 = cocotb.utils.get_sim_time("ns")
    await RisingEdge(dut.mdc_o)
    assert cocotb.utils.get_sim_time("ns") - t0 >= 400
    await _polls(dut, 3)
    assert len(phy.frames) >= 2
    addr_bits = [int(b) for b in f"{PHY_ADDR:05b}"]
    for bits in phy.frames:
        assert bits == [1] * 32 + [0, 1, 1, 0] + addr_bits + [0, 0, 0, 0, 1], bits
    assert phy.reads == len(phy.frames)
    assert phy.errors == []


@cocotb.test()
async def link_up_needs_two_reads_and_drops_on_one(dut):
    """link_up_o rises only after two consecutive link reads; one loss read drops it."""
    phy = await _setup(dut)
    await _polls(dut, 3)
    assert int(dut.phy_ok_o.value) == 1
    assert int(dut.link_up_o.value) == 0

    phy.set_link(True)
    start = phy.reads
    while phy.reads < start + 1:
        await RisingEdge(dut.clk_i)
    await ClockCycles(dut.clk_i, READ_CYCLES)   # first up read completes
    assert int(dut.link_up_o.value) == 0, "rose after a single up read"
    while phy.reads < start + 2:
        await RisingEdge(dut.clk_i)
    await ClockCycles(dut.clk_i, READ_CYCLES)
    assert int(dut.link_up_o.value) == 1

    # A short loss that is already over by the next read: latched-low still reports it.
    phy.set_link(False)
    phy.set_link(True)
    start = phy.reads
    while phy.reads < start + 1:
        await RisingEdge(dut.clk_i)
    await ClockCycles(dut.clk_i, READ_CYCLES)
    assert int(dut.link_up_o.value) == 0, "missed a latched link loss"
    await _polls(dut, 3)
    assert int(dut.link_up_o.value) == 1
    assert phy.errors == []


@cocotb.test()
async def link_bit_is_bmsr_bit_2_only(dut):
    """link_up_o follows bit 2 exactly: other BMSR bits never stand in for it."""
    phy = await _setup(dut)
    rng = get_rng("mdio_bmsr_bits")
    for _ in range(12):
        phy.bmsr = rng.getrandbits(16)
        up = rng.random() < 0.5
        phy.link = up
        await _polls(dut, 3)
        assert int(dut.link_up_o.value) == int(up), f"bmsr={phy.bmsr:#06x} up={up}"
    assert phy.errors == []


@cocotb.test()
async def absent_phy_is_not_link_up(dut):
    """No PHY at the polled address: the line reads all ones, yet link_up_o stays 0."""
    phy = await _setup(dut, addr=(PHY_ADDR + 6) % 32)
    phy.set_link(True)
    await _polls(dut, 5)
    assert phy.reads == 0
    assert len(phy.frames) >= 4
    assert phy.errors == []
    assert int(dut.phy_ok_o.value) == 0
    assert int(dut.link_up_o.value) == 0


@cocotb.test()
async def reset_clears_link_up(dut):
    """Reset drops link_up_o and phy_ok_o at once."""
    phy = await _setup(dut)
    phy.set_link(True)
    await _polls(dut, 4)
    assert int(dut.link_up_o.value) == 1
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 2)
    assert int(dut.link_up_o.value) == 0
    assert int(dut.phy_ok_o.value) == 0
    dut.rst_i.value = 0
    assert phy.errors == []
