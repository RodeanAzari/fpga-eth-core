"""cocotb tests for eth_rx (mii_rx -> overflow guard -> async FIFO -> FCS check ->
store-and-forward buffer), in both modes (CUT_THROUGH = 0 and 1).

Why these tests matter: this is the whole receive MAC that every consumer (order book,
IQ replay, SerDes stats) builds on. Two promises are checked end to end, from MII
nibbles to core-domain frames:
  1. Only intact frames come out, byte-exact and in order. A frame with a bad FCS, PHY
     error, wrong length or an overflow hole never leaks a single byte downstream.
  2. Nothing disappears silently: every frame that had an SFD is counted in exactly one
     status counter, so sent = ok + crc + rx_err + runt + oversize + lost-to-overflow.
     This is what lets P3 claim "zero drops" and lets the order book mark itself stale.
In cut-through the first promise becomes: every frame of 5 bytes or more comes out as it
arrives, byte-exact, with the verdict on its tlast (m_tuser), and emitted_o tells which
statuses belong to frames that came out. A consumer matching per-frame data (T0) to
frames relies on the order checked in `ct_status_order`.
"""

from __future__ import annotations

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from cocotb.utils import get_sim_time
from eth import MiiDriver, MiiFrame, with_fcs
from tb_common import InOrderScoreboard, get_rng
from tb_common.axis import AxisSink, beats_to_bytes

MAX_FRAME = 1518
STATUS = ("frame_ok_o", "crc_err_o", "rx_err_o", "runt_o", "oversize_o", "ovf_o")
FIFO_DEPTH = 1 << int(os.environ.get("FIFO_ADDR_W", "11"))
CUT = int(os.environ.get("CUT_THROUGH", "0"))


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
    # event logs, in core cycles: (cycle, status, emitted, ovf_frames), first-beat cycles
    counts["statuses"], counts["starts"], counts["sfd_ns"] = [], [], []

    async def watch_core():
        cycle, first = 0, True
        while True:
            await RisingEdge(dut.clk_i)
            cycle += 1
            hits = [s for s in STATUS if int(getattr(dut, s).value)]
            assert len(hits) <= 1, f"two statuses in one cycle: {hits}"
            for s in hits:
                counts[s] += 1
                counts["statuses"].append((cycle, s, int(dut.emitted_o.value),
                                           int(dut.ovf_frames_o.value)))
            if "ovf_o" in hits:
                counts["ovf_frames"] += int(dut.ovf_frames_o.value)
            counts["hwm"] = max(counts["hwm"], int(dut.fifo_level_o.value))
            if int(dut.m_tvalid_o.value) and int(dut.m_tready_i.value):
                if first:
                    counts["starts"].append((cycle, get_sim_time("ns")))
                first = bool(int(dut.m_tlast_o.value))
                assert first or not int(dut.m_tuser_o.value), "tuser set mid-frame"

    async def watch_sfd():
        while True:
            await RisingEdge(dut.mii_clk_i)
            if int(dut.sfd_o.value):
                counts["sfd"] += 1
                counts["sfd_ns"].append(get_sim_time("ns"))

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
    sb = InOrderScoreboard("eth_rx_mixed",
                           fmt=lambda f: f"len={len(f[0])} bad={f[1]} {f[0][:16].hex()}")
    expect = {s: 0 for s in STATUS}
    exp_status: list[tuple[str, int]] = []
    kinds = ["ok"] * 4 + ["crc", "er", "odd", "runt", "oversize"]
    plan = [("ok", bytes(60)), ("ok", bytes(MAX_FRAME))]  # both length limits
    plan += [(k, b"") for k in (rng.choice(kinds) for _ in range(398))]
    for kind, fixed in plan:
        if kind == "runt":  # 0 bytes: a 4-byte frame, which never comes out
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
        emits = len(f.data) > 4 if CUT else kind == "ok"
        exp_status.append((status, int(emits)))
        if emits:  # cut-through: the frame as it was on the wire, verdict on tlast
            sb.expect((bytes(f.data[:-4]), int(kind != "ok")))
        await drv.send(f)

    n_out = sum(e for _, e in exp_status)
    await sink.wait_frames(n_out)
    await ClockCycles(dut.clk_i, 200)
    for fr in sink.frames:
        sb.observe((beats_to_bytes(fr, 1), fr[-1].user))
    sb.check_done()
    assert len(sink.frames) == n_out
    got = {s: counts[s] for s in STATUS}
    assert got == expect | {"ovf_o": 0}, f"status counts {got} != expected {expect}"
    assert counts["sfd"] == len(plan)
    st = [(s, e) for _, s, e, _ in counts["statuses"]]
    if CUT:  # statuses in wire order; emitted_o says which frames came out
        assert st == exp_status
    else:  # frame_buffer reports frame_ok at release, later than the FCS statuses
        assert sorted(st) == sorted(exp_status)
    cocotb.log.info("mixed: %s, FIFO high-water %d/%d", got, counts["hwm"], FIFO_DEPTH)


@cocotb.test()
async def overflow_accounted(dut):
    """The sink stalls long enough to fill the frame buffer and overflow the async
    FIFO, then drains. Lost frames must be counted exactly, and every delivered frame
    must be an intact, in-order member of what was sent: an overflow hole never
    produces a corrupted frame (cut-through: only with tuser set on its tlast)."""
    rng = get_rng("eth_rx_ovf")
    drv, sink, counts = await _setup(dut, rng, p_ready=1.0)
    sink.p_ready = 0.0
    sent = [_payload(rng, 60, 1000) for _ in range(60)]
    for k, p in enumerate(sent):  # 4 bytes behind the wire in cut-through: stalls bite

        if k == 40:
            sink.p_ready = 1.0  # stop stalling: the rest must flow normally
        await drv.send(MiiFrame(with_fcs(p), ifg=24))
    await ClockCycles(dut.clk_i, 2000)

    outs = [(beats_to_bytes(fr, 1), fr[-1].user) for fr in sink.frames]
    got = [g for g, bad in outs if not bad]
    it = iter(sent)
    for k, (g, bad) in enumerate(outs):  # subsequence check: in order, byte-exact
        if bad:  # cut-through only: a frame cut by the overflow is a prefix of one sent
            assert CUT, "store-and-forward delivered a bad frame"
            assert any(with_fcs(s_)[: len(g)] == g for s_ in it), f"cut frame {k} not a prefix"
        else:
            assert any(g == s_ for s_ in it), f"delivered frame {k} (len {len(g)}) not intact"
    assert sum(e for _, _, e, _ in counts["statuses"]) == len(outs)
    assert counts["ovf_o"] > 0, "test did not cause an overflow"
    assert counts["frame_ok_o"] == len(got)
    total = counts["frame_ok_o"] + counts["ovf_frames"] + sum(
        counts[s] for s in ("crc_err_o", "rx_err_o", "runt_o", "oversize_o"))
    assert total == len(sent), f"accounting: {counts} sums to {total}, sent {len(sent)}"
    assert counts["sfd"] == len(sent)
    cocotb.log.info("overflow: delivered %d, lost %d in %d abort(s), other %s",
                    len(got), counts["ovf_frames"], counts["ovf_o"],
                    {s: counts[s] for s in ("crc_err_o", "rx_err_o", "runt_o", "oversize_o")})


@cocotb.test()
async def ct_first_byte_before_frame_end(dut):
    """The point of cut-through: a 1,514-byte frame's first byte leaves within a few
    bytes of the SFD, not after the frame (store-and-forward: after the whole frame)."""
    rng = get_rng("eth_rx_latency")
    drv, sink, counts = await _setup(dut, rng, p_ready=1.0)
    p = _payload(rng, 1514, 1514)
    await drv.send(MiiFrame(with_fcs(p), ifg=24))
    await sink.wait_frames(1)
    first_ns = counts["starts"][0][1] - counts["sfd_ns"][0]
    wire_ns = 1518 * 80  # 80 ns per byte at 100 Mb/s
    cocotb.log.info("first byte %d ns after the SFD (frame %d ns)", first_ns, wire_ns)
    if CUT:  # byte 1 needs bytes 1..5 across the FIFO: 5 x 80 ns + synchronizer
        assert first_ns < 5 * 80 + 200
    else:
        assert first_ns > wire_ns


@cocotb.test(skip=not CUT)
async def ct_status_order(dut):
    """The order a T0 matcher relies on (fpga-itch-orderbook ADR 0013): every status of
    an earlier frame comes strictly before a frame's first beat leaves; a frame's own
    status may come before its start only if the frame is one beat long; statuses with
    emitted_o pair one-to-one with output frames. Stimulus: frames of 1-8 bytes and
    normal frames, a stalling sink, and overflows."""
    rng = get_rng("eth_rx_ct_order")
    drv, sink, counts = await _setup(dut, rng, p_ready=0.3)
    for k in range(300):
        if k == 150:
            sink.p_ready = 0.0  # a full stall: the FIFO overflows, frames get cut
        if k == 250:
            sink.p_ready = 0.5
        n = rng.choice((1, 2, 3, 4, 5, 5, 6, 8, 64, 200))
        data = bytes(rng.randrange(256) for _ in range(n))
        await drv.send(MiiFrame(data if n < 64 else with_fcs(data[:-4]), ifg=24))
    await ClockCycles(dut.clk_i, 20000)
    sts, starts = counts["statuses"], [c for c, _ in counts["starts"]]
    assert counts["ovf_o"] > 0, "test did not cause an overflow"
    emitted = [k for k, st in enumerate(sts) if st[2]]
    assert len(emitted) == len(starts) == len(sink.frames)
    for j, (k, start) in enumerate(zip(emitted, starts, strict=True)):
        prev = sts[k - 1][0] if k else 0
        assert prev < start, f"frame {j}: earlier status at {prev}, start at {start}"
        if sts[k][0] < start:
            assert len(sink.frames[j]) == 1, f"frame {j}: judged before it started"
    late = sum(1 for k, st in zip(emitted, starts, strict=True) if sts[k][0] < st)
    cocotb.log.info("ct order: %d statuses, %d frames out, %d judged before start, "
                    "%d overflow statuses", len(sts), len(starts), late, counts["ovf_o"])
