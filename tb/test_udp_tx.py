"""cocotb tests for udp_tx.

Why these tests matter: every consumer's results (BBO updates, CADUs, SerDes stats)
leave the board through this block, addressed to a host it learned from received
traffic. A wrong IPv4 checksum or length makes the host kernel drop the datagram
silently; a destination sampled at the wrong time sends a payload to the previous
sender; a length off by one corrupts or truncates the last record. Each output frame is
parsed by an independent RFC 894/791/768 reader (struct + the RFC 1071 checksum) and
compared field by field with what was asked for.

Sideband timing is tested adversarially: after a payload's first beat the destination
inputs are scrambled every cycle, so any implementation that samples them later than
the first beat sends to garbage and fails.
"""

from __future__ import annotations

import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge
from eth import ip_checksum
from tb_common import InOrderScoreboard, get_rng
from tb_common.axis import AxisBeat, AxisSink, AxisSource, beats_to_bytes

MAX_PAYLOAD = 1472
TTL = 64


def parse(frame: bytes):
    """Independent reader: returns the fields a host stack would act on, or raises."""
    dst_mac, src_mac, etype = frame[0:6], frame[6:12], frame[12:14]
    assert etype == b"\x08\x00", f"EtherType {etype.hex()}"
    ip = frame[14:34]
    assert ip[0] == 0x45, f"version/IHL {ip[0]:#x}"
    assert ip_checksum(ip) == 0, "IPv4 header checksum does not verify"
    totlen, ident, frag, ttl, proto = struct.unpack(">HHHBB", ip[2:10])
    assert totlen == len(frame) - 14, f"total length {totlen}, frame carries {len(frame) - 14}"
    assert frag == 0x4000 and proto == 17 and ttl == TTL, (frag, proto, ttl)
    sport, dport, ulen, ucsum = struct.unpack(">HHHH", frame[34:42])
    assert ulen == totlen - 20, f"UDP length {ulen} vs IP {totlen}"
    assert ucsum == 0
    return (dst_mac, src_mac, int.from_bytes(ip[12:16], "big"),
            int.from_bytes(ip[16:20], "big"), sport, dport, frame[42:])


def needs_second_fold(src_ip: int, dst_ip: int, ln: int) -> bool:
    """True when the first end-around-carry fold of the header sum carries again, the
    case a single-fold checksum gets wrong (about 1 in 10^4 random headers)."""
    words = [0x4500, 20 + 8 + ln, 0, 0x4000, (TTL << 8) | 17,
             src_ip >> 16, src_ip & 0xFFFF, dst_ip >> 16, dst_ip & 0xFFFF]
    s = sum(words)
    return ((s & 0xFFFF) + (s >> 16)) > 0xFFFF


def _rand_dest(rng):
    return (bytes(rng.randrange(256) for _ in range(6)), rng.randrange(1 << 32),
            rng.randrange(1 << 16), rng.randrange(1 << 16))


async def _run(dut, name: str, n: int, p_valid: float, p_ready: float, mix: bool) -> None:
    rng = get_rng(name)
    cocotb.start_soon(Clock(dut.clk_i, 8, unit="ns").start())
    src = AxisSource(dut, dut.clk_i, "s_", rng=rng, p_valid=p_valid)
    sb = InOrderScoreboard(name, fmt=lambda x: f"dst={x[0].hex()} len={len(x[6])}")
    sink = AxisSink(dut, dut.clk_i, "m_", rng=rng, p_ready=p_ready,
                    callback=lambda fr: sb.observe(parse(beats_to_bytes(fr, 1))))
    counts = {"sent_o": 0, "oversize_o": 0}

    async def watch():
        while True:
            await RisingEdge(dut.clk_i)
            for s in counts:
                counts[s] += int(getattr(dut, s).value)

    cocotb.start_soon(watch())
    dut.s_tuser_i.value = 0
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0

    n_sent = n_over = 0
    for k in range(n):
        cfg_mac = bytes(rng.randrange(256) for _ in range(6))
        cfg_ip = rng.randrange(1 << 32)
        dut.cfg_mac_i.value = int.from_bytes(cfg_mac, "big")
        dut.cfg_ip_i.value = cfg_ip
        kind = rng.choice(["ok"] * 8 + ["oversize", "discard"]) if mix else "ok"
        if kind == "oversize":
            ln = rng.randint(MAX_PAYLOAD + 1, MAX_PAYLOAD + 100)
        else:
            ln = rng.choice([1, 2, 17, 18, MAX_PAYLOAD, rng.randint(1, MAX_PAYLOAD)])
        payload = bytes(rng.randrange(256) for _ in range(ln))
        dmac, dip, dport, sport = _rand_dest(rng)
        if k % 10 == 0:  # directed: force the double-fold checksum case
            while not needs_second_fold(cfg_ip, dip, ln):
                dip = rng.randrange(1 << 32)
        dut.dst_mac_i.value = int.from_bytes(dmac, "big")
        dut.dst_ip_i.value = dip
        dut.dst_port_i.value = dport
        dut.src_port_i.value = sport
        user = 1 if kind == "discard" else 0
        if kind == "ok":
            sb.expect((dmac, cfg_mac, cfg_ip, dip, sport, dport, payload))
            n_sent += 1
        elif kind == "oversize":
            n_over += 1

        async def scramble():
            # From the cycle after the first beat is accepted, the sideband is garbage.
            # Sampled and driven on falling edges: mid-cycle, so this never races the
            # rising edge where the DUT samples (a valid && ready seen mid-cycle is a
            # handshake on the next rising edge).
            await FallingEdge(dut.clk_i)
            while not (int(dut.s_tvalid_i.value) and int(dut.s_tready_o.value)):
                await FallingEdge(dut.clk_i)
            while True:
                await FallingEdge(dut.clk_i)
                d = _rand_dest(rng)
                dut.dst_mac_i.value = int.from_bytes(d[0], "big")
                dut.dst_ip_i.value, dut.dst_port_i.value, dut.src_port_i.value = d[1:]

        task = cocotb.start_soon(scramble())
        await src.send(AxisBeat(b, last=(i == ln - 1), user=user if i == ln - 1 else 0)
                       for i, b in enumerate(payload))
        task.cancel()
        # cfg_* is sampled after tlast: hold it until this payload's frame is out.
        await sink.wait_frames(n_sent)
    await ClockCycles(dut.clk_i, 20)
    sb.check_done()
    assert counts == {"sent_o": n_sent, "oversize_o": n_over}, (counts, n_sent, n_over)
    cocotb.log.info("%s: %d sent, %d oversize, %d discarded", name, n_sent, n_over,
                    n - n_sent - n_over)


@cocotb.test()
async def random_full_rate(dut):
    """300 payloads 1..1472 B, random destinations and source config, full rate."""
    await _run(dut, "udp_tx_full", 300, 1.0, 1.0, mix=False)


@cocotb.test()
async def random_backpressure_mixed(dut):
    """300 payloads with input gaps and output stalls, plus oversize payloads (dropped,
    counted once) and tuser-discarded ones (dropped silently, as requested)."""
    await _run(dut, "udp_tx_bp", 300, 0.6, 0.4, mix=True)


@cocotb.test()
async def no_gaps_in_frame(dut):
    """With the sink always ready, a frame must leave at exactly 1 byte/cycle from its
    first header byte to its last payload byte. eth_tx's no-underrun contract rests on
    this."""
    rng = get_rng("udp_tx_gaps")
    cocotb.start_soon(Clock(dut.clk_i, 8, unit="ns").start())
    src = AxisSource(dut, dut.clk_i, "s_", rng=rng, p_valid=0.5)
    dut.m_tready_i.value = 1
    dut.s_tuser_i.value = 0
    for sig in ("cfg_mac_i", "cfg_ip_i", "dst_mac_i", "dst_ip_i", "dst_port_i", "src_port_i"):
        getattr(dut, sig).value = 0
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0
    runs: list[tuple[int, int]] = []  # (beats, cycles) per frame

    async def measure():
        beats = cycles = 0
        while True:
            await RisingEdge(dut.clk_i)
            v = int(dut.m_tvalid_o.value)
            if beats or v:
                cycles += 1
                beats += v
            if v and int(dut.m_tlast_o.value):
                runs.append((beats, cycles))
                beats = cycles = 0

    cocotb.start_soon(measure())
    for ln in [1, 2, 100, MAX_PAYLOAD] + [rng.randint(1, MAX_PAYLOAD) for _ in range(20)]:
        await src.send(AxisBeat(rng.randrange(256), last=(i == ln - 1)) for i in range(ln))
    await ClockCycles(dut.clk_i, 2000)
    assert len(runs) == 24
    for beats, cycles in runs:
        assert beats == cycles, f"frame of {beats} beats took {cycles} cycles"
