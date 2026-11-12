"""cocotb tests for eth_fcs_check.

Why these tests matter: store-and-forward (Phases B-D) acts on a frame only once its FCS
is proven good, so this block's verdict is the one thing standing between a corrupted
frame and the order book. The tests check that every good frame passes with its FCS
stripped and tuser clear, every damaged frame (any single bit flip, upstream error,
runt) is flagged on its last beat, and that each frame produces exactly one status
pulse of the right kind, in order, so the error counters add up to the frame count.
Random valid/ready gaps on both sides prove the verdict survives backpressure.
"""

from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from eth import with_fcs
from tb_common import InOrderScoreboard, get_rng
from tb_common.axis import AxisBeat, AxisSink, AxisSource, beats_to_bytes

STATUS = ("frame_ok_o", "crc_err_o", "rx_err_o", "runt_o")


def _beats(frame: bytes, err: int) -> list[AxisBeat]:
    return [AxisBeat(b, last=(k == len(frame) - 1), user=err if k == len(frame) - 1 else 0)
            for k, b in enumerate(frame)]


async def _run(dut, name: str, frames: list[tuple[bytes, int, str]],
               p_valid: float, p_ready: float) -> None:
    """frames: (wire bytes incl. FCS, upstream error bit, expected status name)."""
    rng = get_rng(name)
    cocotb.start_soon(Clock(dut.clk_i, 8, unit="ns").start())
    src = AxisSource(dut, dut.clk_i, "s_", rng=rng, p_valid=p_valid)
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0

    out_sb = InOrderScoreboard(f"{name}_data", fmt=lambda f: f"len={len(f[0])} bad={f[1]}")
    st_sb = InOrderScoreboard(f"{name}_status")

    def on_frame(frame):
        assert all(b.user == 0 for b in frame[:-1]), f"{name}: tuser set mid-frame"
        out_sb.observe((beats_to_bytes(frame, 1), frame[-1].user))

    sink = AxisSink(dut, dut.clk_i, "m_", rng=rng, p_ready=p_ready, callback=on_frame)

    async def watch_status():
        while True:
            await RisingEdge(dut.clk_i)
            hits = [s for s in STATUS if int(getattr(dut, s).value)]
            assert len(hits) <= 1, f"{name}: two status pulses at once {hits}"
            if hits:  # emitted_o: did this frame put a beat on m_* (cut-through consumers)
                st_sb.observe((hits[0], int(dut.emitted_o.value)))

    cocotb.start_soon(watch_status())

    n_out = 0
    for wire, err, status in frames:
        st_sb.expect((status, int(len(wire) > 4)))
        if len(wire) > 4:  # 4 bytes or fewer carry no payload: no output beats
            out_sb.expect((wire[:-4], int(status != "frame_ok_o")))
            n_out += 1
    await src.send(b for wire, err, _ in frames for b in _beats(wire, err))
    await sink.wait_frames(n_out)
    await ClockCycles(dut.clk_i, 20)
    out_sb.check_done()
    st_sb.check_done()
    assert len(sink.frames) == n_out


def _mixed(rng, n: int) -> list[tuple[bytes, int, str]]:
    frames = []
    for _ in range(n):
        kind = rng.choice(["ok", "ok", "crc", "rx", "runt"])
        if kind == "runt":
            payload = bytes(rng.randrange(256) for _ in range(rng.randint(0, 59)))
        else:
            payload = bytes(rng.randrange(256) for _ in range(rng.randint(60, 1514)))
        wire = bytearray(with_fcs(payload))
        if kind == "crc":
            bit = rng.randrange(8 * len(wire))  # anywhere, the FCS itself included
            wire[bit // 8] ^= 1 << (bit % 8)
        status = {"ok": "frame_ok_o", "crc": "crc_err_o", "rx": "rx_err_o",
                  "runt": "runt_o"}[kind]
        frames.append((bytes(wire), int(kind == "rx"), status))
    return frames


@cocotb.test()
async def mixed_full_rate(dut):
    """200 mixed frames back to back, no stalls: 1 byte/cycle throughput."""
    await _run(dut, "fcs_full_rate", _mixed(get_rng("fcs_full_rate_gen"), 200), 1.0, 1.0)


@cocotb.test()
async def mixed_backpressure(dut):
    """Same mix with random gaps on input and random stalls on output."""
    await _run(dut, "fcs_bp", _mixed(get_rng("fcs_bp_gen"), 200), 0.7, 0.5)


@cocotb.test()
async def boundary_lengths(dut):
    """Exactly 64 bytes is the shortest legal frame; 63 is a runt even with a good CRC.
    Frames of 1..5 bytes exercise the FCS delay line before it fills; an upstream
    error outranks a runt."""
    rng = get_rng("fcs_bounds")
    frames = [
        (with_fcs(bytes(60)), 0, "frame_ok_o"),
        (with_fcs(bytes(59)), 0, "runt_o"),
        (with_fcs(bytes(rng.randrange(256) for _ in range(60))), 0, "frame_ok_o"),
        (b"\x01", 0, "runt_o"),
        (b"\x01\x02\x03\x04", 0, "runt_o"),
        (b"\x01\x02\x03\x04\x05", 0, "runt_o"),
        (with_fcs(bytes(10)), 1, "rx_err_o"),
        (with_fcs(bytes(1514)), 0, "frame_ok_o"),
    ]
    await _run(dut, "fcs_bounds", frames, 1.0, 1.0)
