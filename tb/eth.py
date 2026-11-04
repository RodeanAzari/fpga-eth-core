"""Ethernet test helpers: FCS reference and an MII receive-side driver.

The reference CRC is zlib.crc32, which is the 802.3 CRC-32 (reflected, init and final
XOR 0xFFFFFFFF); the FCS goes on the wire least-significant byte first.
"""

from __future__ import annotations

import random
import struct
import zlib
from dataclasses import dataclass

from cocotb.triggers import FallingEdge

PREAMBLE_NIBBLES = 15  # 7 x 0x55 plus the low nibble of the SFD (0x5)
MIN_IFG_NIBBLES = 24   # 96 bit times at 4 bits per clock


def fcs(data: bytes) -> bytes:
    return zlib.crc32(data).to_bytes(4, "little")


def with_fcs(data: bytes) -> bytes:
    return data + fcs(data)


@dataclass
class MiiFrame:
    data: bytes                      # every byte after the SFD (FCS included if wanted)
    preamble: int = PREAMBLE_NIBBLES  # 0x5 nibbles before the SFD's 0xD nibble
    ifg: int = MIN_IFG_NIBBLES       # rx_dv-low clocks after the frame
    er_at: int | None = None         # nibble index (after the SFD) to raise rx_er on
    extra_nibble: bool = False       # dribble nibble: frame ends on an odd nibble
    sfd: bool = True                 # False: preamble only (false carrier / no SFD)


class MiiDriver:
    """Drives mii_rxd/rx_dv/rx_er on the falling edge, so they are stable at the
    rising edge where the DUT samples them (clause 22 receive timing)."""

    def __init__(self, dut, clk, rxd=None, dv=None, er=None) -> None:
        """rxd/dv/er: signal handles; default to the DUT's mii_rxd_i/mii_rx_dv_i/
        mii_rx_er_i (block-level port names)."""
        self.clk = clk
        self.rxd = rxd if rxd is not None else dut.mii_rxd_i
        self.dv = dv if dv is not None else dut.mii_rx_dv_i
        self.er = er if er is not None else dut.mii_rx_er_i
        self.rxd.value = 0
        self.dv.value = 0
        self.er.value = 0

    async def _nibble(self, nib: int, dv: int, er: int = 0) -> None:
        await FallingEdge(self.clk)
        self.rxd.value = nib
        self.dv.value = dv
        self.er.value = er

    async def send(self, f: MiiFrame) -> None:
        for _ in range(f.preamble):
            await self._nibble(0x5, 1)
        if f.sfd:
            await self._nibble(0xD, 1)
            nibs = []
            for b in f.data:
                nibs += [b & 0xF, b >> 4]  # low nibble first
            if f.extra_nibble:
                nibs.append(0xA)
            for k, n in enumerate(nibs):
                await self._nibble(n, 1, int(k == f.er_at))
        for _ in range(f.ifg):
            await self._nibble(0, 0)


def ip_checksum(hdr: bytes) -> int:
    """RFC 1071 ones'-complement checksum of an IPv4 header (checksum field zeroed)."""
    s = sum(int.from_bytes(hdr[i:i + 2], "big") for i in range(0, len(hdr), 2))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF


def mcast_mac(ip: int) -> bytes:
    """RFC 1112 s6.4: 01:00:5E + low 23 bits of the group address."""
    return bytes([0x01, 0x00, 0x5E]) + (ip & 0x7FFFFF).to_bytes(3, "big")


@dataclass
class UdpFrame:
    """An Ethernet II / IPv4 / UDP frame without FCS. Every field can be overridden to
    build malformed or foreign frames; build() pads to the 60-byte Ethernet minimum."""
    payload: bytes
    dst_ip: int
    dst_port: int
    dst_mac: bytes | None = None   # default: multicast MAC of dst_ip
    src_mac: bytes = bytes.fromhex("0200deadbeef")
    src_ip: int = 0xC0A80A01       # 192.168.10.1
    src_port: int = 40000
    ethertype: int = 0x0800
    version: int = 4
    ihl: int = 5                   # options are filled with NOPs (0x01)
    proto: int = 17
    frag: int = 0x4000             # DF set, not a fragment
    ip_totlen: int | None = None   # default: correct
    udp_len: int | None = None     # default: correct
    bad_csum: bool = False

    def build(self) -> bytes:
        udp_len = len(self.payload) + 8 if self.udp_len is None else self.udp_len
        hl = max(self.ihl, 0) * 4
        totlen = hl + len(self.payload) + 8 if self.ip_totlen is None else self.ip_totlen
        hdr = bytearray(struct.pack(">BBHHHBBH4s4s", (self.version << 4) | (self.ihl & 0xF),
                                    0, totlen & 0xFFFF, 0x1234, self.frag, 64, self.proto, 0,
                                    self.src_ip.to_bytes(4, "big"),
                                    self.dst_ip.to_bytes(4, "big")))
        hdr += b"\x01" * max(hl - 20, 0)
        csum = ip_checksum(bytes(hdr))
        if self.bad_csum:
            csum ^= 1 << random.Random(totlen).randrange(16)
        hdr[10:12] = csum.to_bytes(2, "big")
        udp = struct.pack(">HHHH", self.src_port, self.dst_port, udp_len & 0xFFFF, 0)
        dst_mac = mcast_mac(self.dst_ip) if self.dst_mac is None else self.dst_mac
        frame = dst_mac + self.src_mac + self.ethertype.to_bytes(2, "big") + bytes(hdr) \
            + udp + self.payload
        return frame + bytes(max(0, 60 - len(frame)))
