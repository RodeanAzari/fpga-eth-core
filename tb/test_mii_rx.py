"""cocotb tests for mii_rx.

Why these tests matter: everything above the MAC trusts this block's byte boundaries.
A reversed nibble order or a mis-detected SFD corrupts every byte of every frame, and a
lost error flag lets a damaged frame through as good. So the tests check, against an
independent nibble-level driver: exact bytes in exact order for every frame length the
link can carry, one SFD pulse per frame (the T0 event), and the error flag on exactly
the frames that had rx_er or ended on an odd nibble.
"""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from eth import MIN_IFG_NIBBLES, MiiDriver, MiiFrame
from tb_common import InOrderScoreboard, get_rng
from tb_common.axis import AxisMonitor, beats_to_bytes


async def _setup(dut, name: str):
    cocotb.start_soon(Clock(dut.clk_i, 40, unit="ns").start())
    drv = MiiDriver(dut, dut.clk_i)
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0
    sb = InOrderScoreboard(name, fmt=lambda f: f"len={len(f[0])} err={f[1]} {f[0][:16].hex()}")

    def on_frame(frame):
        # tuser must be 0 on every beat but the last.
        assert all(b.user == 0 for b in frame[:-1]), f"{name}: tuser set mid-frame"
        sb.observe((beats_to_bytes(frame, 1), frame[-1].user))

    mon = AxisMonitor(dut, dut.clk_i, "m_", callback=on_frame)
    sfd = {"n": 0}

    async def count_sfd():
        while True:
            await RisingEdge(dut.clk_i)
            sfd["n"] += int(dut.sfd_o.value)

    cocotb.start_soon(count_sfd())
    return drv, sb, mon, sfd


async def _finish(dut, sb, mon, n_frames: int) -> None:
    await mon.wait_frames(n_frames)
    await ClockCycles(dut.clk_i, 20)
    sb.check_done()
    assert len(mon.frames) == n_frames, f"{len(mon.frames) - n_frames} spurious frame(s)"


@cocotb.test()
async def random_frames(dut):
    """300 frames, 1..1522 bytes, random preamble length (the PHY may eat some) and
    inter-frame gap down to 1 clock: bytes and order exact, no error flag."""
    rng = get_rng("mii_random")
    drv, sb, mon, sfd = await _setup(dut, "mii_random")
    lengths = [1, 2, 3, 64, 1518, 1522] + [rng.randint(1, 1522) for _ in range(294)]
    for n in lengths:
        data = bytes(rng.randrange(256) for _ in range(n))
        sb.expect((data, 0))
        await drv.send(MiiFrame(data, preamble=rng.randint(1, 15),
                                ifg=rng.choice([1, 2, MIN_IFG_NIBBLES, rng.randint(1, 60)])))
    await _finish(dut, sb, mon, len(lengths))
    assert sfd["n"] == len(lengths), f"sfd pulses {sfd['n']} != frames {len(lengths)}"


@cocotb.test()
async def errors_flagged(dut):
    """rx_er anywhere in the frame, or a trailing odd nibble, sets tuser on that frame's
    last beat only. The bytes still come through (the FCS checker drops the frame), and
    the following good frame is unaffected."""
    rng = get_rng("mii_errors")
    drv, sb, mon, sfd = await _setup(dut, "mii_errors")
    count = 0
    for _ in range(100):
        n = rng.randint(1, 200)
        data = bytes(rng.randrange(256) for _ in range(n))
        kind = rng.choice(["er", "odd", "good"])
        f = MiiFrame(data)
        if kind == "er":
            f.er_at = rng.randrange(2 * n)
        elif kind == "odd":
            f.extra_nibble = True
        sb.expect((data, int(kind != "good")))
        await drv.send(f)
        count += 1
    await _finish(dut, sb, mon, count)
    assert sfd["n"] == count


@cocotb.test()
async def no_sfd_ignored(dut):
    """Carrier with preamble but no SFD (false carrier), or an SFD nibble not preceded
    by a preamble nibble, emits nothing and no T0 pulse; the next good frame is exact."""
    rng = get_rng("mii_nosfd")
    drv, sb, mon, sfd = await _setup(dut, "mii_nosfd")
    good = bytes(rng.randrange(256) for _ in range(80))
    await drv.send(MiiFrame(b"", preamble=10, sfd=False))
    # 0xD as the very first nibble of a carrier event: no preamble, so not an SFD.
    await drv.send(MiiFrame(b"\x12\x34", preamble=0))
    sb.expect((good, 0))
    await drv.send(MiiFrame(good))
    await _finish(dut, sb, mon, 1)
    assert sfd["n"] == 1
