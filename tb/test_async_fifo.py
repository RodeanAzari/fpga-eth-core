"""cocotb tests for async_fifo.

Why these tests matter: the MII RX path cannot be backpressured, so the FIFO must never
drop, duplicate or reorder a byte across the 25 MHz PHY clock / core clock boundary, and
its full flag must assert exactly when the write side would otherwise overwrite unread
data. The formal proof covers this at depth 4; these tests cover the real depth and
clock ratios, plus the high-water mark the overflow logic relies on.
"""

from __future__ import annotations

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer
from tb_common import InOrderScoreboard, get_rng
from tb_common.axis import AxisBeat, AxisSink, AxisSource

DATA_W = int(os.environ.get("DATA_W", "8"))
ADDR_W = int(os.environ.get("ADDR_W", "4"))
DEPTH = 1 << ADDR_W


async def _reset(dut) -> None:
    dut.wr_rst_i.value = 1
    dut.rd_rst_i.value = 1
    await ClockCycles(dut.wr_clk_i, 4)
    await ClockCycles(dut.rd_clk_i, 4)
    dut.wr_rst_i.value = 0
    dut.rd_rst_i.value = 0
    await ClockCycles(dut.wr_clk_i, 2)


async def _track_hwm(dut, stats: dict) -> None:
    while True:
        await RisingEdge(dut.wr_clk_i)
        stats["hwm"] = max(stats["hwm"], int(dut.wr_level_o.value))


async def _run(dut, name: str, wr_ns: float, rd_ns: float, p_valid: float, p_ready: float,
               n: int = 3000) -> dict:
    rng = get_rng(name)
    cocotb.start_soon(Clock(dut.wr_clk_i, wr_ns, unit="ns").start())
    await Timer(rng.randrange(100, int(rd_ns * 1000)), unit="ps")  # random clock phase
    cocotb.start_soon(Clock(dut.rd_clk_i, rd_ns, unit="ns").start())
    src = AxisSource(dut, dut.wr_clk_i, "s_", rng=rng, p_valid=p_valid)
    dut.m_tready_i.value = 0
    await _reset(dut)
    sb = InOrderScoreboard(name, fmt=lambda w: f"{w:#x}")
    sink = AxisSink(dut, dut.rd_clk_i, "m_", rng=rng, p_ready=p_ready,
                    callback=lambda f: sb.observe(f[0].data))  # no tlast: 1 beat/frame
    stats = {"hwm": 0}
    cocotb.start_soon(_track_hwm(dut, stats))
    words = [rng.randrange(1 << DATA_W) for _ in range(n)]
    for w in words:
        sb.expect(w)
    await src.send(AxisBeat(w) for w in words)
    await sink.wait_frames(n)
    # Nothing extra may appear after the last word.
    await ClockCycles(dut.rd_clk_i, 10)
    sb.check_done()
    assert sink.beats_seen == n, f"{name}: {sink.beats_seen - n} spurious word(s)"
    assert int(dut.wr_level_o.value) == 0
    cocotb.log.info("%s: wr_level high-water mark %d/%d", name, stats["hwm"], DEPTH)
    return stats


@cocotb.test()
async def mii_to_core_bursty(dut):
    """25 MHz writer into a 125 MHz reader with random stalls: the Phase B use case."""
    await _run(dut, "mii_to_core", wr_ns=40.0, rd_ns=8.0, p_valid=0.9, p_ready=0.5)


@cocotb.test()
async def fast_writer_fills(dut):
    """Writer 3x faster than a stalling reader: the FIFO must fill to exactly DEPTH,
    hold s_tready low while full, and still lose nothing."""
    stats = await _run(dut, "fast_writer", wr_ns=8.0, rd_ns=24.3, p_valid=1.0, p_ready=0.3)
    assert stats["hwm"] == DEPTH, f"never reached full (hwm {stats['hwm']})"


@cocotb.test()
async def slow_writer_drains(dut):
    """Reader much faster than writer: the FIFO runs empty and must not under-run or
    emit a word twice."""
    stats = await _run(dut, "slow_writer", wr_ns=41.7, rd_ns=7.9, p_valid=0.4, p_ready=1.0)
    assert stats["hwm"] <= 3
