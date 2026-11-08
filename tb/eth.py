"""Ethernet test helpers: FCS reference and an MII receive-side driver.

The reference CRC is zlib.crc32, which is the 802.3 CRC-32 (reflected, init and final
XOR 0xFFFFFFFF); the FCS goes on the wire least-significant byte first.
"""

from __future__ import annotations

import random
import struct
import zlib
from dataclasses import dataclass

import cocotb
from cocotb.triggers import FallingEdge, First, RisingEdge, Timer

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


@dataclass
class TxWireFrame:
    """One tx_en burst as seen on the MII transmit pins."""
    nibbles: list[int]   # every nibble while tx_en was high, preamble included
    idle_before: int     # tx_en-low clocks before this burst (None-like -1 for the first)

    def decode(self) -> tuple[bytes, bool]:
        """(bytes after the SFD, framing ok). Framing ok = exactly 15 preamble nibbles of
        0x5, then the SFD's 0xD, then an even number of nibbles (low nibble first)."""
        pre = PREAMBLE_NIBBLES
        ok = (len(self.nibbles) > pre and self.nibbles[:pre] == [0x5] * pre
              and self.nibbles[pre] == 0xD and (len(self.nibbles) - pre - 1) % 2 == 0)
        body = self.nibbles[pre + 1:]
        data = bytes(body[i] | (body[i + 1] << 4) for i in range(0, len(body) - 1, 2))
        return data, ok


class MiiTxMonitor:
    """Samples mii_txd/tx_en on the falling edge of tx_clk (the DUT drives them from
    rising-edge flops, so they are settled mid-cycle) and collects one TxWireFrame per
    tx_en burst."""

    def __init__(self, clk, txd, tx_en) -> None:
        self.clk, self.txd, self.tx_en = clk, txd, tx_en
        self.frames: list[TxWireFrame] = []

    async def run(self) -> None:
        cur: list[int] | None = None
        idle = -1  # unknown before the first frame
        while True:
            await FallingEdge(self.clk)
            if int(self.tx_en.value):
                if cur is None:
                    cur = []
                cur.append(int(self.txd.value))
            else:
                if cur is not None:
                    self.frames.append(TxWireFrame(cur, idle))
                    cur, idle = None, 0
                if idle >= 0:
                    idle += 1


def wire_image(frame: bytes, min_data: int = 60) -> bytes:
    """What a correct MAC puts after the SFD for `frame`: zero padding to min_data
    bytes, then the FCS."""
    return with_fcs(frame + bytes(max(0, min_data - len(frame))))


class Clause22Phy:
    """MDIO PHY model, IEEE 802.3 clause 22, written from the standard (not the RTL).

    Samples MDIO on MDC rising edges; syncs on >= 32 ones followed by the 0 of ST;
    decodes ST/OP/PHYAD/REGAD; if PHYAD is its own, answers TA (Z, 0) and 16 data bits
    MSB first, each changing tco_ns after an MDC rising edge (DP83848 max: 300 ns).
    Only BMSR (register 1) is modelled: link status (bit 2) is latched-low, so the first
    read after a loss returns 0 (22.2.4.2.13).

    Handles: mdc (DUT output), oe/o (the DUT's MDIO enable and value), line (the DUT's
    MDIO input, driven here as the wired bus: DUT when enabled, else this PHY, else the
    pull-up). Protocol violations by the DUT land in .errors; tests assert it is empty.
    """

    def __init__(self, mdc, oe, o, line, addr: int, tco_ns: int = 300):
        self.mdc, self.oe, self.o, self.line = mdc, oe, o, line
        self.addr = addr
        self.tco_ns = tco_ns
        self.bmsr = 0x7849          # DP83848 reset value; bit 2 is replaced by the link
        self.link = False
        self.link_lost = False
        self.drive: int | None = None
        self.frames: list[list[int]] = []   # 32 preamble ones + 14 header bits, per read
        self.reads = 0                       # reads answered
        self.errors: list[str] = []
        cocotb.start_soon(self._bus())
        cocotb.start_soon(self._run())

    def set_link(self, up: bool) -> None:
        if self.link and not up:
            self.link_lost = True
        self.link = up

    def _bmsr_value(self) -> int:
        up = self.link and not self.link_lost
        self.link_lost = False
        return (self.bmsr & ~0x4) | (0x4 if up else 0)

    def _update(self) -> None:
        dut_drives = int(self.oe.value) == 1
        if dut_drives and self.drive is not None:
            self.errors.append("bus contention: DUT and PHY both drive MDIO")
        if dut_drives:
            self.line.value = int(self.o.value)
        else:
            self.line.value = 1 if self.drive is None else self.drive

    def _set_drive(self, value: int | None) -> None:
        self.drive = value
        self._update()

    async def _bus(self):
        # Event-driven: re-resolve the wired bus whenever either side changes.
        while True:
            self._update()
            await First(self.oe.value_change, self.o.value_change)

    async def _bit(self) -> int:
        await RisingEdge(self.mdc)
        return int(self.line.value)

    async def _drive_after_edge(self, value: int | None):
        await RisingEdge(self.mdc)
        await Timer(self.tco_ns, unit="ns")
        self._set_drive(value)

    async def _run(self):
        while True:
            ones = 0
            while True:
                b = await self._bit()
                if b:
                    ones += 1
                elif ones >= 32:
                    break
                else:
                    ones = 0
            hdr = [0] + [await self._bit() for _ in range(13)]
            self.frames.append([1] * 32 + hdr)
            phyad = int("".join(map(str, hdr[4:9])), 2)
            regad = int("".join(map(str, hdr[9:14])), 2)
            is_read = hdr[0:4] == [0, 1, 1, 0]
            # TA, first bit: the station must have released the line (both are Z).
            await RisingEdge(self.mdc)
            if int(self.oe.value):
                self.errors.append("station still drives MDIO in TA")
            if not is_read or phyad != self.addr:
                continue
            self.reads += 1
            value = self._bmsr_value() if regad == 1 else 0xFFFF
            # Already past the TA1 edge: drive TA2 = 0, then data; release after.
            await Timer(self.tco_ns, unit="ns")
            self._set_drive(0)
            for i in range(15, -1, -1):
                await self._drive_after_edge((value >> i) & 1)
            await self._drive_after_edge(None)
