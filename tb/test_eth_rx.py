"""cocotb tests for eth_rx (mii_rx -> overflow guard -> async FIFO -> FCS check ->
store-and-forward buffer).

Why these tests matter: this is the whole receive MAC that every consumer (order book,
IQ replay, SerDes stats) builds on. Two promises are checked end to end, from MII
nibbles to core-domain frames:
  1. Only intact frames come out, byte-exact and in order. A frame with a bad FCS, PHY
     error, wrong length or an overflow hole never leaks a single byte downstream.
  2. Nothing disappears silently: every frame that had an SFD is counted in exactly one
     status counter, so sent = ok + crc + rx_err + runt + oversize + lost-to-overflow.
     This is what lets P3 claim "zero drops" and lets the order book mark itself stale.
"""

from __future__ import annotations

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from eth import MiiDriver, MiiFrame, with_fcs
from tb_common import InOrderScoreboard, get_rng
from tb_common.axis import AxisSink, beats_to_bytes

MAX_FRAME = 1518
STATUS = ("frame_ok_o", "crc_err_o", "rx_err_o", "runt_o", "oversize_o", "ovf_o")
FIFO_DEPTH = 1 << int(os.environ.get("FIFO_ADDR_W", "11"))


async def _setup(dut, rng, p_ready: float):
    cocotb.start_soon(Clock(dut.mii_clk_i, 40, unit="ns").start())
    cocotb.start_soon(Clock(dut.clk_i, 8, unit="ns").start())
    drv = MiiDriver(dut, dut.mii_clk_i)
    dut.mii_rst_i.value = 1
    dut.rst_i.value = 1
    await ClockCycles(dut.mii_clk_i, 4)
    dut.mii_rst_i.value = 0
    dut.rst_i.value = 0
    counts = {s: 0 for s in STATUS} | {"ovf_frames": 0, "sfd": 0, "hwm": 0}

    async def watch_core():
        while True:
            await RisingEdge(dut.clk_i)
            hits = [s for s in STATUS if int(getattr(dut, s).value)]
            for s in hits:
                counts[s] += 1
            if "ovf_o" in hits:
                counts["ovf_frames"] += int(dut.ovf_frames_o.value)
            counts["hwm"] = max(counts["hwm"], int(dut.fifo_level_o.value))

    async def watch_sfd():
        while True:
            await RisingEdge(dut.mii_clk_i)
            counts["sfd"] += int(dut.sfd_o.value)

    cocotb.start_soon(watch_core())
    cocotb.start_soon(watch_sfd())
    sink = AxisSink(dut, dut.clk_i, "m_", rng=rng, p_ready=p_ready)
    return drv, sink, counts


def _payload(rng, lo: int, hi: int) -> bytes:
    return bytes(rng.randrange(256) for _ in range(rng.randint(lo, hi)))


@cocotb.test()
async def mixed_traffic(dut):
    """400 frames of every kind with random gaps and a stalling sink: exactly the good
    frames come out, intact and in order, and each frame lands in one counter."""
    rng = get_rng("eth_rx_mixed")
    drv, sink, counts = await _setup(dut, rng, p_ready=0.5)
    sb = InOrderScoreboard("eth_rx_mixed", fmt=lambda b: f"len={len(b)} {b[:16].hex()}")
    expect = {s: 0 for s in STATUS}
    kinds = ["ok"] * 4 + ["crc", "er", "odd", "runt", "oversize"]
    plan = [("ok", bytes(60)), ("ok", bytes(MAX_FRAME))]  # both length limits
    plan += [(k, b"") for k in (rng.choice(kinds) for _ in range(398))]
    for kind, fixed in plan:
        if kind == "runt":
            payload = _payload(rng, 0, 59)
        elif kind == "oversize":
            payload = _payload(rng, MAX_FRAME + 1, MAX_FRAME + 80)
        else:
            payload = fixed or _payload(rng, 60, 1514)
        wire = bytearray(with_fcs(payload))
        f = MiiFrame(bytes(wire), ifg=rng.randint(24, 40))
        if kind == "crc":
            bit = rng.randrange(8 * len(wire))
            wire[bit // 8] ^= 1 << (bit % 8)
            f.data = bytes(wire)
        elif kind == "er":
            f.er_at = rng.randrange(2 * len(wire))
        elif kind == "odd":
            f.extra_nibble = True
        status = {"ok": "frame_ok_o", "crc": "crc_err_o", "er": "rx_err_o",
                  "odd": "rx_err_o", "runt": "runt_o", "oversize": "oversize_o"}[kind]
        expect[status] += 1
        if kind == "ok":
            sb.expect(payload)
        await drv.send(f)

    n_ok = expect["frame_ok_o"]
    await sink.wait_frames(n_ok)
    await ClockCycles(dut.clk_i, 200)
    for fr in sink.frames:
        sb.observe(beats_to_bytes(fr, 1))
    sb.check_done()
    assert len(sink.frames) == n_ok
    got = {s: counts[s] for s in STATUS}
    assert got == expect | {"ovf_o": 0}, f"status counts {got} != expected {expect}"
    assert counts["sfd"] == len(plan)
    cocotb.log.info("mixed: %s, FIFO high-water %d/%d", got, counts["hwm"], FIFO_DEPTH)


@cocotb.test()
async def overflow_accounted(dut):
    """The sink stalls long enough to fill the frame buffer and overflow the async
    FIFO, then drains. Lost frames must be counted exactly, and every delivered frame
    must be an intact, in-order member of what was sent: an overflow hole never
    produces a corrupted frame."""
    rng = get_rng("eth_rx_ovf")
    drv, sink, counts = await _setup(dut, rng, p_ready=1.0)
    sink.p_ready = 0.0
    sent = [_payload(rng, 60, 1000) for _ in range(60)]
    for k, p in enumerate(sent):
        if k == 40:
            sink.p_ready = 1.0  # stop stalling: the rest must flow normally
        await drv.send(MiiFrame(with_fcs(p), ifg=24))
    await ClockCycles(dut.clk_i, 2000)

    got = [beats_to_bytes(fr, 1) for fr in sink.frames]
    it = iter(sent)
    for k, g in enumerate(got):  # subsequence check: in order, byte-exact
        assert any(g == s for s in it), f"delivered frame {k} (len {len(g)}) not intact/in order"
    assert counts["ovf_o"] > 0, "test did not cause an overflow"
    assert counts["frame_ok_o"] == len(got)
    total = counts["frame_ok_o"] + counts["ovf_frames"] + sum(
        counts[s] for s in ("crc_err_o", "rx_err_o", "runt_o", "oversize_o"))
    assert total == len(sent), f"accounting: {counts} sums to {total}, sent {len(sent)}"
    assert counts["sfd"] == len(sent)
    cocotb.log.info("overflow: delivered %d, lost %d in %d abort(s), other %s",
                    len(got), counts["ovf_frames"], counts["ovf_o"],
                    {s: counts[s] for s in ("crc_err_o", "rx_err_o", "runt_o", "oversize_o")})
