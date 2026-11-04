"""Ethernet test helpers: FCS reference and an MII receive-side driver.

The reference CRC is zlib.crc32, which is the 802.3 CRC-32 (reflected, init and final
XOR 0xFFFFFFFF); the FCS goes on the wire least-significant byte first.
"""

from __future__ import annotations

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

    def __init__(self, dut, clk) -> None:
        self.dut = dut
        self.clk = clk
        dut.mii_rxd_i.value = 0
        dut.mii_rx_dv_i.value = 0
        dut.mii_rx_er_i.value = 0

    async def _nibble(self, nib: int, dv: int, er: int = 0) -> None:
        await FallingEdge(self.clk)
        self.dut.mii_rxd_i.value = nib
        self.dut.mii_rx_dv_i.value = dv
        self.dut.mii_rx_er_i.value = er

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
