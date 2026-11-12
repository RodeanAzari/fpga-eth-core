"""fpga-coord 0005: eth_rx when the PHY's rx_clk stops while the MAC is reset.

Why this matters: P3 saw the RX FIFO report an impossible level (fifo_level_o 4095) and
frame counts far above line rate after the PHY link came up, cleared by a MAC restart;
the 0005 board runs saw one more on a design that re-enters reset on link loss. The async
FIFO's contract (rtl/async_fifo.sv header) needs both domain resets asserted together,
each for at least one edge of its own clock. The examples drive the rx_clk-domain reset
from a reset synchronizer clocked by rx_clk, which can only change while rx_clk runs. If
the PHY stops rx_clk while the core side resets (link loss, PHY reset), the core side's
read pointer returns to 0 and the write pointer does not.

Before the fix (eth-core-v0.3 and earlier) this reproduced the fault: fifo_level_o
3,193-3,262 on a 2,048 FIFO, and old frames out again as good (9 ok for 5 sent). Since
rx_reset_bridge, eth_rx makes its own rx reset from rst_i and resets the FIFO's read side
only inside the write side's reset. Checked with the old consumer wiring (mii_rst_i from
a model of examples/rx_stats/reset_sync.sv: 3 flops on rx_clk, starting asserted) and
the new (mii_rst_i tied 0), with rx_clk running and stopped across the reset. The
contract: after a MAC reset the FIFO is empty and only the frames sent afterwards come
out, each counted once; while rx_clk is stopped after a reset, in_reset_o stays high.
"""

from __future__ import annotations

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer
from eth import MiiDriver, MiiFrame, with_fcs
from tb_common import get_rng
from tb_common.axis import AxisSink, beats_to_bytes

FIFO_DEPTH = 1 << int(os.environ.get("FIFO_ADDR_W", "11"))
STAGES = 3  # examples/rx_stats/reset_sync.sv


class Bench:
    def __init__(self, dut) -> None:
        self.dut = dut
        self.mac_rst = 1  # the core-side reset request (rx_stats_top mac_rst_q)
        self.sync = [1] * STAGES  # reset_sync's flops: power-up asserted
        self.mii_clk = None
        self.external = True  # mii_rst_i from a reset_sync model; False: tied 0
        self.hwm = 0
        self.ok = 0

    def start_mii_clk(self) -> None:
        self.mii_clk = cocotb.start_soon(Clock(self.dut.mii_clk_i, 40, unit="ns").start())

    def stop_mii_clk(self) -> None:
        self.mii_clk.cancel()
        self.dut.mii_clk_i.value = 0

    async def reset_sync(self) -> None:
        """mii_rst_i as reset_sync drives it: moves only on rx_clk edges."""
        while True:
            await RisingEdge(self.dut.mii_clk_i)
            self.sync = [self.mac_rst, *self.sync[:-1]]
            self.dut.mii_rst_i.value = self.sync[-1] if self.external else 0

    async def watch(self) -> None:
        dut = self.dut
        while True:
            await RisingEdge(dut.clk_i)
            if not int(dut.rst_i.value):
                self.hwm = max(self.hwm, int(dut.fifo_level_o.value))
                self.ok += int(dut.frame_ok_o.value)

    def set_mac_rst(self, v: int) -> None:
        self.mac_rst = v
        self.dut.rst_i.value = v


async def run(dut, stop_clk: bool, external: bool):
    rng = get_rng(f"eth_rx_reset_{int(stop_clk)}{int(external)}")
    b = Bench(dut)
    b.external = external
    cocotb.start_soon(Clock(dut.clk_i, 8, unit="ns").start())
    dut.mii_rst_i.value = 1
    b.set_mac_rst(1)
    b.start_mii_clk()
    cocotb.start_soon(b.reset_sync())
    cocotb.start_soon(b.watch())
    drv = MiiDriver(dut, dut.mii_clk_i)
    sink = AxisSink(dut, dut.clk_i, "m_", rng=rng, p_ready=1.0)
    await ClockCycles(dut.mii_clk_i, 8)
    b.set_mac_rst(0)
    await ClockCycles(dut.mii_clk_i, 8)
    # run 1: enough bytes that the write pointer stands far from 0 (and past the depth)
    before = []
    while sum(map(len, before)) < FIFO_DEPTH + FIFO_DEPTH // 2:
        p = bytes(rng.randrange(256) for _ in range(rng.randint(200, 1400)))
        before.append(p)
        await drv.send(MiiFrame(with_fcs(p), ifg=24))
    await sink.wait_frames(len(before))
    await ClockCycles(dut.clk_i, 200)
    assert b.ok == len(before)
    # MAC reset pulse (link loss); rx_clk stopped for its whole length in the fault run
    if stop_clk:
        b.stop_mii_clk()
    b.set_mac_rst(1)
    await ClockCycles(dut.clk_i, 1000)
    b.set_mac_rst(0)
    await Timer(2, unit="us")
    if stop_clk:
        # the reset cannot complete without rx_clk: eth_rx says so and holds
        assert int(dut.in_reset_o.value), "in_reset_o low while rx_clk is stopped"
        b.start_mii_clk()
    await ClockCycles(dut.mii_clk_i, 20)
    assert not int(dut.in_reset_o.value), "in_reset_o still high 20 rx_clk after restart"
    # run 2: a few frames after the reset
    n_before_frames = len(sink.frames)
    b.ok, b.hwm = 0, 0
    after = [bytes(rng.randrange(256) for _ in range(rng.randint(60, 600))) for _ in range(5)]
    for p in after:
        await drv.send(MiiFrame(with_fcs(p), ifg=24))
    await ClockCycles(dut.clk_i, 20_000)
    got = [beats_to_bytes(f, 1) for f in sink.frames[n_before_frames:]]
    return b.hwm, b.ok, got, after


def check(hwm: int, ok: int, got: list[bytes], after: list[bytes]) -> None:
    seen = (f"fifo_level_o max {hwm} (depth {FIFO_DEPTH}), {len(got)} frames out, {ok} ok, "
            f"{sum(g in after for g in got)} of them sent after the reset (sent {len(after)})")
    assert hwm <= FIFO_DEPTH and got == after and ok == len(after), seen


@cocotb.test()
async def mac_reset_rx_clk_running_external_rst(dut):
    """Old wiring, rx_clk running: unchanged behaviour."""
    check(*await run(dut, stop_clk=False, external=True))


@cocotb.test()
async def mac_reset_rx_clk_stopped_external_rst(dut):
    """0005: old wiring (a reset_sync on rx_clk that cannot move) with rx_clk stopped."""
    check(*await run(dut, stop_clk=True, external=True))


@cocotb.test()
async def mac_reset_rx_clk_stopped_no_external_rst(dut):
    """0005: new wiring (mii_rst_i tied 0) with rx_clk stopped."""
    check(*await run(dut, stop_clk=True, external=False))


@cocotb.test()
async def mac_reset_rx_clk_running_no_external_rst(dut):
    """New wiring, rx_clk running."""
    check(*await run(dut, stop_clk=False, external=False))
