"""Convert an rx_stats or udp_echo UART log (one `RX` line of 15 hex fields per second) to CSV.

Usage: python3 host/rx_stats_csv.py [--echo] <uart.log>   (--echo: udp_echo field names)
"""

import sys

COMMON = [
    "uptime_s", "eth_ok", "crc_err", "rx_err", "runt", "oversize", "ovf_lost", "udp_ok",
    "udp_filtered", "ip_csum_err", "udp_malformed",
]
RX_STATS = [*COMMON, "payload_bytes", "seq_err", "seq_lost", "fifo_hwm"]
UDP_ECHO = [*COMMON, "tx_sent", "tx_oversize", "tx_underrun", "fifo_hwm"]


def main() -> None:
    args = sys.argv[1:]
    fields = UDP_ECHO if args and args[0] == "--echo" else RX_STATS
    path = args[-1]
    print(",".join(fields))
    with open(path, encoding="ascii", errors="replace") as log:
        for line in log:
            parts = line.split()
            if len(parts) == len(fields) + 1 and parts[0] == "RX":
                print(",".join(str(int(p, 16)) for p in parts[1:]))


if __name__ == "__main__":
    main()
