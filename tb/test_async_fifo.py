"""cocotb tests for async_fifo.

Why these tests matter: the MII RX path cannot be backpressured, so the FIFO must never
drop, duplicate or reorder a byte across the 25 MHz PHY clock / core clock boundary, and
its full flag must assert exactly when the write side would otherwise overwrite unread
data. The formal proof covers this at depth 4; these tests cover the real depth and
clock ratios, plus the high-water mark the overflow logic relies on.
"""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

DATA_W = int(os.environ.get("DATA_W", "8"))
ADDR_W = int(os.environ.get("ADDR_W", "4"))
DEPTH = 1 << ADDR_W


def _rng(name: str) -> random.Random:
    seed = int(os.environ.get("SEED", random.randrange(1 << 31)))
    cocotb.log.info("%s: SEED=%d", name, seed)
    return random.Random(seed)


async def _reset(dut) -> None:
    dut.s_tvalid_i.value = 0
    dut.s_tdata_i.value = 0
    dut.m_tready_i.value = 0
    dut.wr_rst_i.value = 1
    dut.rd_rst_i.value = 1
    await ClockCycles(dut.wr_clk_i, 4)
    await ClockCycles(dut.rd_clk_i, 4)
    dut.wr_rst_i.value = 0
    dut.rd_rst_i.value = 0
    await ClockCycles(dut.wr_clk_i, 2)


async def _writer(dut, words: list[int], rng: random.Random, p_valid: float, stats: dict) -> None:
    i = 0
    while i < len(words):
        await RisingEdge(dut.wr_clk_i)
        # Sample the handshake of the cycle that just ended.
        if dut.s_tvalid_i.value == 1 and dut.s_tready_o.value == 1:
            i += 1
        stats["hwm"] = max(stats["hwm"], int(dut.wr_level_o.value))
        if i < len(words) and (dut.s_tvalid_i.value == 1 or rng.random() < p_valid):
            # AXI-Stream: once valid, hold data until accepted.
            dut.s_tvalid_i.value = 1
            dut.s_tdata_i.value = words[i]
        else:
            dut.s_tvalid_i.value = 0
    dut.s_tvalid_i.value = 0


async def _reader(dut, n: int, rng: random.Random, p_ready: float) -> list[int]:
    got: list[int] = []
    while len(got) < n:
        await RisingEdge(dut.rd_clk_i)
        if dut.m_tvalid_o.value == 1 and dut.m_tready_i.value == 1:
            got.append(int(dut.m_tdata_o.value))
        dut.m_tready_i.value = 1 if rng.random() < p_ready else 0
    dut.m_tready_i.value = 0
    return got


async def _run(dut, name: str, wr_ns: float, rd_ns: float, p_valid: float, p_ready: float,
               n: int = 3000) -> dict:
    rng = _rng(name)
    cocotb.start_soon(Clock(dut.wr_clk_i, wr_ns, unit="ns").start())
    await Timer(rng.randrange(100, int(rd_ns * 1000)), unit="ps")  # random clock phase
    cocotb.start_soon(Clock(dut.rd_clk_i, rd_ns, unit="ns").start())
    await _reset(dut)
    words = [rng.randrange(1 << DATA_W) for _ in range(n)]
    stats = {"hwm": 0}
    w = cocotb.start_soon(_writer(dut, words, rng, p_valid, stats))
    got = await _reader(dut, n, rng, p_ready)
    await w
    for k, (exp, act) in enumerate(zip(words, got, strict=True)):
        assert act == exp, f"{name}: word {k}: expected {exp:#x}, got {act:#x}"
    # Nothing extra may appear after the last word.
    await ClockCycles(dut.rd_clk_i, 10)
    assert dut.m_tvalid_o.value == 0, f"{name}: spurious word after the stream ended"
    assert int(dut.wr_level_o.value) == 0
    cocotb.log.info("%s: %d words in order, wr_level high-water mark %d/%d",
                    name, n, stats["hwm"], DEPTH)
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
