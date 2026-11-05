"""Loopback test for udp_seq_send.

Why: the hardware gate compares the FPGA's udp_ok and sequence counters against what the
sender says it sent. If the sender skipped or repeated a sequence number, encoded it
little-endian, sent the wrong size, or miscounted, the FPGA would report a false drop
(or hide a real one). This test receives on 127.0.0.1 and checks every datagram.

Usage: python3 host/test_udp_seq_send.py <path to udp_seq_send>
"""

import socket
import subprocess
import sys

COUNT = 20000
PPS = 40000  # 0.5 s; well inside what loopback delivers without receive-buffer loss
SIZE = 100
START = 0xFFFF_FFFF_FFFF_FF00  # crosses the 2^64 wrap: catches a narrower counter


def main() -> int:
    exe = sys.argv[1]
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    rx.bind(("127.0.0.1", 0))
    port = rx.getsockname()[1]
    rx.settimeout(2.0)

    proc = subprocess.Popen(
        [exe, "--dst", "127.0.0.1", "--port", str(port), "--pps", str(PPS),
         "--count", str(COUNT), "--size", str(SIZE), "--start-seq", str(START)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    seqs = []
    try:
        while len(seqs) < COUNT:
            data = rx.recv(2048)
            assert len(data) == SIZE, f"datagram {len(seqs)}: {len(data)} bytes, want {SIZE}"
            assert data[8:] == bytes(SIZE - 8), f"datagram {len(seqs)}: non-zero filler"
            seqs.append(int.from_bytes(data[:8], "big"))
    except TimeoutError:
        pass
    out, _ = proc.communicate(timeout=10)
    summary = dict(line.split("=", 1) for line in out.splitlines())

    assert proc.returncode == 0, f"exit code {proc.returncode}"
    assert len(seqs) == COUNT, f"received {len(seqs)} of {COUNT}"
    want = [(START + i) % 2**64 for i in range(COUNT)]
    first_bad = next((i for i, (g, w) in enumerate(zip(seqs, want)) if g != w), None)
    assert first_bad is None, f"seq[{first_bad}] = {seqs[first_bad]:#x}, want {want[first_bad]:#x}"
    assert int(summary["sent"]) == COUNT, summary
    assert int(summary["first_seq"]) == START, summary
    assert int(summary["last_seq"]) == want[-1], summary
    print(f"PASS: {COUNT} datagrams, contiguous big-endian sequence, summary matches; "
          f"achieved {summary['achieved_pps']} pps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
