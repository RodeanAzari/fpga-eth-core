"""Convert an rx_stats UART log (one `RX` line of 15 hex fields per second) to CSV."""

import sys

FIELDS = [
    "uptime_s", "eth_ok", "crc_err", "rx_err", "runt", "oversize", "ovf_lost", "udp_ok",
    "udp_filtered", "ip_csum_err", "udp_malformed", "payload_bytes", "seq_err", "seq_lost",
    "fifo_hwm",
]


def main() -> None:
    print(",".join(FIELDS))
    with open(sys.argv[1], encoding="ascii", errors="replace") as log:
        for line in log:
            parts = line.split()
            if len(parts) == len(FIELDS) + 1 and parts[0] == "RX":
                print(",".join(str(int(p, 16)) for p in parts[1:]))


if __name__ == "__main__":
    main()
