"""Loopback test for udp_echo_check.

Why: the eth-core-v0.2 hardware gate is read off this tool's summary ("every echo came
back intact"). If it matched echoes loosely, miscounted a loss, or accepted a corrupted
echo, the gate would pass on a broken TX path. Here a Python echo server on 127.0.0.1
plays the FPGA: a clean run must report every datagram ok and exit 0; a run where the
server drops one datagram and corrupts one byte of another must report exactly lost=2
(the dropped one and the one whose only echo was corrupt), mismatched=1, and exit
non-zero. Loopback can reorder datagrams across CPUs, so order is not asserted here. The payload lengths seen by the server must span the
whole 1..1472 range, since covering every length is the point of the gate.

A third run holds back HOLD consecutive echoes and releases them together, like the late
echoes seen on the WSL2 host. Every one of them is intact, only late, so the
run must report every datagram ok: a checker that judges loss by how many datagrams
followed (not by age) would call them lost, and the gate would fail on a working board.

Usage: python3 host/test_udp_echo_check.py <path to udp_echo_check>
"""

import socket
import subprocess
import sys
import threading

COUNT = 5000
PPS = 10000


HOLD = range(1000, 1600)  # 60 ms of echoes at PPS, far more than a 256-datagram window


def run(exe: str, drop: int | None, corrupt: int | None, hold: range = range(0)):
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    srv.bind(("127.0.0.1", 0))
    srv.settimeout(3.0)
    port = srv.getsockname()[1]
    sizes: list[int] = []
    held: list[tuple[bytes, tuple[str, int]]] = []

    def echo():
        k = 0
        try:
            while True:
                data, peer = srv.recvfrom(2048)
                sizes.append(len(data))
                if k == corrupt:
                    data = bytes([data[0] ^ 0x40]) + data[1:]
                if k in hold:
                    held.append((data, peer))
                elif k != drop:
                    if hold and k == hold.stop:
                        for d, p in held:
                            srv.sendto(d, p)
                    srv.sendto(data, peer)
                k += 1
        except TimeoutError:
            pass

    t = threading.Thread(target=echo)
    t.start()
    proc = subprocess.run(
        [exe, "--dst", "127.0.0.1", "--port", str(port), "--pps", str(PPS),
         "--count", str(COUNT), "--seed", "7"],
        capture_output=True, text=True, timeout=30,
    )
    t.join()
    srv.close()
    summary = dict(line.split("=", 1) for line in proc.stdout.splitlines())
    return proc.returncode, summary, sizes


def main() -> int:
    exe = sys.argv[1]
    rc, s, sizes = run(exe, None, None)
    assert rc == 0, (rc, s)
    assert int(s["sent"]) == COUNT and int(s["echo_ok"]) == COUNT, s
    assert int(s["lost"]) == 0 and int(s["mismatched"]) == 0, s
    assert len(sizes) == COUNT and min(sizes) <= 5 and max(sizes) >= 1468, (min(sizes), max(sizes))
    assert int(s["payload_bytes_ok"]) == sum(sizes), s

    rc, s, _ = run(exe, drop=100, corrupt=200)
    assert rc == 3, (rc, s)
    assert int(s["lost"]) == 2 and int(s["mismatched"]) == 1, s
    assert int(s["echo_ok"]) == COUNT - 2, s

    rc, s, _ = run(exe, None, None, hold=HOLD)
    assert rc == 0, (rc, s)
    assert int(s["echo_ok"]) == COUNT and int(s["lost"]) == 0, s
    assert int(s["mismatched"]) == 0, s
    print(f"PASS: clean run {COUNT}/{COUNT} ok, lengths {min(sizes)}..{max(sizes)}; "
          "injected drop + corruption reported as lost=2 mismatched=1; "
          f"{len(HOLD)} echoes held back and released late: all ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
