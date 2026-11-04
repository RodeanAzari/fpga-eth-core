"""cocotb tests for udp_rx.

Why these tests matter: this filter decides which bytes the application ever sees. A
wrong accept feeds foreign traffic (or a corrupt IPv4 header) into the order book; a
wrong reject loses feed packets that only show up later as unexplained gaps; keeping
Ethernet padding corrupts the last MoldUDP64 message of short packets. Every frame is
judged by an independent Python reference (`expected`) that parses the raw bytes per
RFC 894/791/768, and the DUT must agree on the status, the payload bytes and the
sender metadata, frame by frame, including after the filter is reconfigured at runtime.
"""

from __future__ import annotations

import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from eth import UdpFrame, ip_checksum, mcast_mac
from tb_common import InOrderScoreboard, get_rng
from tb_common.axis import AxisBeat, AxisSink, AxisSource, beats_to_bytes

STATUS = ("ok_o", "filtered_o", "ip_csum_err_o", "malformed_o")
OWN_MAC = bytes.fromhex("02000a0b0c0d")
GROUP = 0xEF010101  # 239.1.1.1
PORT = 26400


def expected(frame: bytes, mac: bytes, ip: int, port: int):
    """Reference verdict: (status, payload or None, truncated, (src_mac, src_ip, sport))."""
    # A frame that ends before the end of the (IHL-sized) IP + UDP headers is malformed
    # whatever it is addressed to: no verdict is reached before that point.
    if len(frame) < 15:
        return "malformed_o", None, False, None
    ver, ihl = frame[14] >> 4, frame[14] & 0xF
    hl = ihl * 4 if ihl >= 5 else 20
    if len(frame) < 14 + hl + 8:
        return "malformed_o", None, False, None
    want = mcast_mac(ip) if ip >> 28 == 0xE else mac
    if frame[0:6] != want or frame[12:14] != b"\x08\x00":
        return "filtered_o", None, False, None
    if ver != 4 or ihl < 5:
        return "malformed_o", None, False, None
    hdr = bytearray(frame[14:14 + hl])
    if ip_checksum(bytes(hdr)) != 0:  # a valid header sums to 0xFFFF -> complement 0
        return "ip_csum_err_o", None, False, None
    totlen, = struct.unpack(">H", hdr[2:4])
    frag, = struct.unpack(">H", hdr[6:8])
    proto, dst_ip = hdr[9], int.from_bytes(hdr[16:20], "big")
    sport, dport, ulen = struct.unpack(">HHH", frame[14 + hl:14 + hl + 6])
    if proto != 17 or frag & 0x3FFF or dst_ip != ip or dport != port:
        return "filtered_o", None, False, None
    if totlen < hl + 8 or ulen < 8 or ulen > totlen - hl:
        return "malformed_o", None, False, None
    if ulen == 8:
        return "filtered_o", None, False, None
    start = 14 + hl + 8
    payload = frame[start:start + ulen - 8]
    meta = (int.from_bytes(frame[6:12], "big"), int.from_bytes(hdr[12:16], "big"), sport)
    truncated = len(payload) < ulen - 8
    return ("malformed_o" if truncated else "ok_o"), payload, truncated, meta


def _random_frame(rng, cfg_ip: int, cfg_port: int) -> bytes:
    kind = rng.choice(["ok"] * 6 + ["mac", "etype", "ip", "port", "tcp", "frag", "csum",
                                    "ver", "ihl_lo", "ulen_big", "ulen_small", "trunc",
                                    "tiny", "empty", "opts"])
    n = rng.choice([1, 2, 17, 18, 100, rng.randint(1, 1472)])
    f = UdpFrame(bytes(rng.randrange(256) for _ in range(n)), cfg_ip, cfg_port,
                 src_ip=rng.randrange(1 << 32), src_port=rng.randrange(1 << 16),
                 src_mac=bytes(rng.randrange(256) for _ in range(6)))
    if kind == "mac":
        f.dst_mac = mcast_mac(cfg_ip ^ 0x1)
    elif kind == "etype":
        f.ethertype = rng.choice([0x0806, 0x86DD, 0x8100])
    elif kind == "ip":
        f.dst_ip = cfg_ip ^ (1 << 24)  # same multicast MAC (bit 24 not mapped), other IP
    elif kind == "port":
        f.dst_port = cfg_port ^ (1 << rng.randrange(16))
    elif kind == "tcp":
        f.proto = 6
    elif kind == "frag":
        f.frag = rng.choice([0x2000, 0x0001, 0x00B9])  # MF, or a non-zero offset
    elif kind == "csum":
        f.bad_csum = True
    elif kind == "ver":
        f.version = 6
    elif kind == "ihl_lo":
        f.ihl = rng.randint(0, 4)
    elif kind == "ulen_big":
        f.udp_len = n + 9 + rng.randint(0, 50)
    elif kind == "ulen_small":
        f.udp_len = rng.randint(0, 7)
    elif kind == "empty":
        f.payload = b""
    elif kind == "opts":
        f.ihl = rng.randint(6, 15)
    frame = f.build()
    if kind == "trunc":  # the IP/UDP lengths promise more than the frame carries
        frame = frame[:rng.randint(14 + 20 + 8 + 1, max(43, len(frame) - 1))]
    if kind == "tiny":
        frame = frame[:rng.randint(1, 41)]
    return frame


async def _run(dut, name: str, schedule, p_valid: float, p_ready: float) -> int:
    """schedule: list of (cfg (mac, ip, port), [frames]). Config changes only between
    frames, after the DUT has drained, as the interface contract requires."""
    rng = get_rng(name)
    cocotb.start_soon(Clock(dut.clk_i, 8, unit="ns").start())
    src = AxisSource(dut, dut.clk_i, "s_", rng=rng, p_valid=p_valid)
    dut.rst_i.value = 1
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0
    out_sb = InOrderScoreboard(f"{name}_payload",
                               fmt=lambda x: f"len={len(x[0])} trunc={x[1]} meta={x[2]}")
    st_sb = InOrderScoreboard(f"{name}_status")

    def on_frame(frame):
        assert all(b.user == 0 for b in frame[:-1]), f"{name}: tuser mid-datagram"
        meta = (int(dut.src_mac_o.value), int(dut.src_ip_o.value), int(dut.src_port_o.value))
        out_sb.observe((beats_to_bytes(frame, 1), frame[-1].user, meta))

    sink = AxisSink(dut, dut.clk_i, "m_", rng=rng, p_ready=p_ready, callback=on_frame)

    async def watch_status():
        while True:
            await RisingEdge(dut.clk_i)
            hits = [s for s in STATUS if int(getattr(dut, s).value)]
            assert len(hits) <= 1, f"{name}: two status pulses {hits}"
            if hits:
                st_sb.observe(hits[0])

    cocotb.start_soon(watch_status())
    n_out, n_frames, tally = 0, 0, {s: 0 for s in STATUS}
    for (mac, ip, port), frames in schedule:
        dut.cfg_mac_i.value = int.from_bytes(mac, "big")
        dut.cfg_ip_i.value = ip
        dut.cfg_port_i.value = port
        for fr in frames:
            status, payload, trunc, meta = expected(fr, mac, ip, port)
            st_sb.expect(status)
            tally[status] += 1
            if payload:
                out_sb.expect((payload, int(trunc), meta))
                n_out += 1
        await src.send(AxisBeat(b, last=(k == len(fr) - 1)) for fr in frames
                       for k, b in enumerate(fr))
        n_frames += len(frames)
        await sink.wait_frames(n_out)
        await ClockCycles(dut.clk_i, 10)
    out_sb.check_done()
    st_sb.check_done()
    assert len(sink.frames) == n_out
    cocotb.log.info("%s: %d frames, %s", name, n_frames, tally)
    return n_frames


def _schedule(rng, n_per: int):
    cfgs = [
        (OWN_MAC, GROUP, PORT),
        (OWN_MAC, 0xEF000001, 1),          # another group, port 1: runtime reconfig
        (OWN_MAC, 0xC0A80A02, 5000),       # unicast: dst MAC must be cfg_mac
        (OWN_MAC, 0xE0FFFFFF, 0xFFFF),     # 224.255.255.255, highest port
    ]
    sched = []
    for mac, ip, port in cfgs:
        frames = [_random_frame(rng, ip, port) for _ in range(n_per)]
        if ip >> 28 != 0xE:
            for k in range(len(frames)):  # unicast: address the good frames to OWN_MAC
                if frames[k][0:3] == b"\x01\x00\x5e":
                    frames[k] = OWN_MAC + frames[k][6:]
        sched.append(((mac, ip, port), frames))
    return sched


@cocotb.test()
async def random_mixed(dut):
    """800 frames, 4 runtime configurations, full rate."""
    await _run(dut, "udp_mixed", _schedule(get_rng("udp_mixed_gen"), 200), 1.0, 1.0)


@cocotb.test()
async def random_backpressure(dut):
    """Same mix with random input gaps and output stalls."""
    await _run(dut, "udp_bp", _schedule(get_rng("udp_bp_gen"), 200), 0.6, 0.4)


@cocotb.test()
async def padding_stripped(dut):
    """Payloads of 1..17 bytes sit in a frame padded to 60 bytes: exactly the UDP payload
    comes out, never the zero padding (it would corrupt the last MoldUDP64 message)."""
    rng = get_rng("udp_pad")
    frames = [UdpFrame(bytes(rng.randrange(1, 256) for _ in range(n)), GROUP, PORT).build()
              for n in range(1, 19)]
    assert all(len(f) == 60 for f in frames[:17])
    await _run(dut, "udp_pad", [((OWN_MAC, GROUP, PORT), frames)], 1.0, 1.0)
