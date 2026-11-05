"""cocotb tests for mii_tx.

Why these tests matter: this is the last thing between every consumer's results and
the wire. The host's NIC silently drops any frame whose preamble, nibble order, padding
or FCS is wrong, so a TX bug looks like "nothing arrives" with no clue why. Each frame
on the pins is compared with an independent image (zlib CRC-32, zero padding to 60
bytes, 15 x 0x5 + 0xD preamble, low nibble first), and the gap between back-to-back
frames must be exactly 96 bit times: shorter breaks the 802.3 contract, longer wastes
line rate the IQ-replay and stats streams need.

The underrun test checks the fail-loud promise: when the producer starves the MII
mid-frame, the frame must go out with a WRONG FCS (so no receiver accepts a truncated
frame as good), underrun_o must count it, and the stream must recover so the next frame
is perfect.
"""

from __future__ import annotations

import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from eth import MIN_IFG_NIBBLES, MiiTxMonitor, wire_image
from tb_common import InOrderScoreboard, get_rng
from tb_common.axis import AxisBeat, AxisSource


async def _setup(dut, rng):
    cocotb.start_soon(Clock(dut.clk_i, 40, unit="ns").start())
    src = AxisSource(dut, dut.clk_i, "s_", rng=rng)
    mon = MiiTxMonitor(dut.clk_i, dut.mii_txd_o, dut.mii_tx_en_o)
    cocotb.start_soon(mon.run())
    underruns = [0]

    async def count_underruns():
        while True:
            await RisingEdge(dut.clk_i)
            underruns[0] += int(dut.underrun_o.value)

    cocotb.start_soon(count_underruns())
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0
    return src, mon, underruns


def _beats(frame: bytes):
    return [AxisBeat(b, last=(k == len(frame) - 1)) for k, b in enumerate(frame)]


async def _drain(dut, mon, n: int) -> None:
    for _ in range(20000):
        if len(mon.frames) >= n:
            break
        await RisingEdge(dut.clk_i)
    await ClockCycles(dut.clk_i, 40)


@cocotb.test()
async def back_to_back(dut):
    """300 frames of 1..1514 bytes (every length class: below, at and above the
    60-byte pad threshold) offered back to back: each must be byte-exact on the wire,
    and every gap must be exactly 24 idle clocks."""
    rng = get_rng("mii_tx_b2b")
    src, mon, underruns = await _setup(dut, rng)
    lengths = [1, 2, 59, 60, 61, 1514] + [rng.randint(1, 1514) for _ in range(294)]
    frames = [bytes(rng.randrange(256) for _ in range(n)) for n in lengths]
    sb = InOrderScoreboard("mii_tx_b2b", fmt=lambda x: f"len={len(x[0])} framing={x[1]}")
    for f in frames:
        sb.expect((wire_image(f), True))
    await src.send(b for f in frames for b in _beats(f))
    await _drain(dut, mon, len(frames))
    for wf in mon.frames:
        sb.observe(wf.decode())
    sb.check_done()
    gaps = [wf.idle_before for wf in mon.frames[1:]]
    assert set(gaps) == {MIN_IFG_NIBBLES}, f"IFG not exactly 24: {sorted(set(gaps))}"
    assert underruns[0] == 0
    cocotb.log.info("b2b: %d frames, IFG %s", len(frames), set(gaps))


@cocotb.test()
async def underrun_spoils_fcs(dut):
    """Starved frames (the producer offers a byte on 20% of cycles; mii_tx needs one
    every 2) interleaved with well-fed ones. A starved frame must never reach the wire
    with a valid FCS; underrun_o must equal the number of spoiled frames; every
    well-fed frame, including the one right after an underrun, must be perfect."""
    rng = get_rng("mii_tx_underrun")
    src, mon, underruns = await _setup(dut, rng)
    plan = [(rng.random() < 0.5, bytes(rng.randrange(256) for _ in range(rng.randint(30, 600))))
            for _ in range(80)]
    for starved, f in plan:
        src.p_valid = 0.2 if starved else 1.0
        await src.send(_beats(f))
        # Let a frame start before the next one is offered, so p_valid applies per frame.
        await ClockCycles(dut.clk_i, 2)
    await _drain(dut, mon, len(plan))

    assert len(mon.frames) == len(plan), f"{len(mon.frames)} wire frames for {len(plan)} sent"
    spoiled = 0
    for k, ((starved, f), wf) in enumerate(zip(plan, mon.frames, strict=True)):
        data, framing = wf.decode()
        assert framing, f"frame {k}: bad preamble/nibble alignment"
        if data == wire_image(f):
            continue
        assert starved, f"frame {k}: well-fed frame corrupted"
        # Spoiled: whatever was sent, its FCS must not check (zlib over data+FCS of a
        # good frame is the residue 0x2144DF1C, i.e. ~0xDEBB20E3).
        assert zlib.crc32(data) != 0x2144DF1C, f"frame {k}: truncated frame with a valid FCS"
        assert len(data) >= 64, f"frame {k}: spoiled frame not padded to the minimum"
        spoiled += 1
    assert spoiled > 10, f"only {spoiled} underruns: the test did not starve the MII"
    assert underruns[0] == spoiled, f"underrun_o counted {underruns[0]}, spoiled {spoiled}"
    cocotb.log.info("underrun: %d of %d frames spoiled and counted", spoiled, len(plan))
