// udp_seq_send: paced UDP sender for the eth-core sustained-stream test.
//
// Each datagram's payload starts with a big-endian 64-bit sequence number that increases
// by one per datagram (the rest is zero). This is the payload contract of
// examples/rx_stats, which counts every gap. Linux only (POSIX sockets, CLOCK_MONOTONIC).
//
// Pacing busy-waits on an absolute CLOCK_MONOTONIC schedule (t0 + i / pps), so a late
// datagram does not shift the ones after it. A send that fails with ENOBUFS/EAGAIN is
// retried with the same sequence number (counted as send_retries), so a host-side
// queue-full never shows up as a gap on the receiver. Any other send error aborts.
//
// Output: a progress line per second on stderr; a key=value summary on stdout, for the
// results sidecar. Ctrl-C stops cleanly and still prints the summary.

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

namespace {

constexpr int kMaxPayload = 1472;  // 1500 MTU - 20 IPv4 - 8 UDP
constexpr int kSeqBytes = 8;
// Bytes on the wire per datagram beyond the payload: preamble+SFD 8, Ethernet header 14,
// IPv4 20, UDP 8, FCS 4, inter-frame gap 12. Payloads under 18 bytes are padded to the
// 64-byte minimum frame.
constexpr int kWireOverhead = 8 + 14 + 20 + 8 + 4 + 12;
constexpr int kMinFramePayload = 18;  // 64 - 14 - 20 - 8 - 4

volatile std::sig_atomic_t g_stop = 0;
void on_signal(int) { g_stop = 1; }

int64_t now_ns() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1'000'000'000 + ts.tv_nsec;
}

void put_be64(uint8_t* p, uint64_t v) {
    for (int i = 7; i >= 0; --i) {
        p[i] = static_cast<uint8_t>(v & 0xFF);
        v >>= 8;
    }
}

int wire_bytes(int payload) {
    return (payload < kMinFramePayload ? kMinFramePayload : payload) + kWireOverhead;
}

[[noreturn]] void usage(const char* argv0) {
    std::fprintf(stderr,
                 "usage: %s --dst IP --port N --pps N (--count N | --seconds S)\n"
                 "          [--size BYTES] [--if-ip IP] [--start-seq N]\n"
                 "  --dst      destination IPv4 (multicast group or unicast)\n"
                 "  --size     payload bytes, %d..%d (default %d)\n"
                 "  --if-ip    local interface address for multicast (IP_MULTICAST_IF)\n"
                 "  --start-seq first sequence number (default 0)\n",
                 argv0, kSeqBytes, kMaxPayload, kMaxPayload);
    std::exit(2);
}

struct Args {
    std::string dst;
    std::string if_ip;
    int port = -1;
    int size = kMaxPayload;
    double pps = 0;
    uint64_t count = 0;
    double seconds = 0;
    uint64_t start_seq = 0;
};

Args parse(int argc, char** argv) {
    Args a;
    for (int i = 1; i < argc; ++i) {
        std::string k = argv[i];
        if (i + 1 >= argc) usage(argv[0]);
        const char* v = argv[++i];
        if (k == "--dst") a.dst = v;
        else if (k == "--if-ip") a.if_ip = v;
        else if (k == "--port") a.port = std::atoi(v);
        else if (k == "--size") a.size = std::atoi(v);
        else if (k == "--pps") a.pps = std::atof(v);
        else if (k == "--count") a.count = std::strtoull(v, nullptr, 0);
        else if (k == "--seconds") a.seconds = std::atof(v);
        else if (k == "--start-seq") a.start_seq = std::strtoull(v, nullptr, 0);
        else usage(argv[0]);
    }
    bool one_limit = (a.count > 0) != (a.seconds > 0);
    if (a.dst.empty() || a.port < 1 || a.port > 65535 || a.pps <= 0 || !one_limit ||
        a.size < kSeqBytes || a.size > kMaxPayload)
        usage(argv[0]);
    return a;
}

}  // namespace

int main(int argc, char** argv) {
    const Args a = parse(argc, argv);

    sockaddr_in dst{};
    dst.sin_family = AF_INET;
    dst.sin_port = htons(static_cast<uint16_t>(a.port));
    if (inet_pton(AF_INET, a.dst.c_str(), &dst.sin_addr) != 1) usage(argv[0]);

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { std::perror("socket"); return 1; }
    const unsigned char ttl = 1, loop = 0;  // direct cable: never route, never loop back
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof ttl);
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, sizeof loop);
    if (!a.if_ip.empty()) {
        in_addr ifa{};
        if (inet_pton(AF_INET, a.if_ip.c_str(), &ifa) != 1) usage(argv[0]);
        if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifa, sizeof ifa) != 0) {
            std::perror("IP_MULTICAST_IF");
            return 1;
        }
    }

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    std::vector<uint8_t> buf(static_cast<size_t>(a.size), 0);
    const double period_ns = 1e9 / a.pps;
    const int64_t limit_ns = static_cast<int64_t>(a.seconds * 1e9);
    std::fprintf(stderr, "sending %d-byte payloads to %s:%d at %.0f pps (%.2f Mbit/s on the wire)\n",
                 a.size, a.dst.c_str(), a.port, a.pps, a.pps * wire_bytes(a.size) * 8 / 1e6);

    uint64_t sent = 0, retries = 0;
    int rc = 0;
    const int64_t t0 = now_ns();
    int64_t next_report = t0 + 1'000'000'000;
    uint64_t sent_at_report = 0;

    while (!g_stop) {
        if (a.count > 0 && sent >= a.count) break;
        const int64_t due = t0 + static_cast<int64_t>(static_cast<double>(sent) * period_ns);
        if (limit_ns > 0 && due - t0 >= limit_ns) break;
        while (now_ns() < due) {
        }

        put_be64(buf.data(), a.start_seq + sent);
        ssize_t n = sendto(fd, buf.data(), buf.size(), 0, reinterpret_cast<sockaddr*>(&dst),
                           sizeof dst);
        if (n < 0) {
            if (errno == ENOBUFS || errno == EAGAIN || errno == EINTR) {
                ++retries;
                continue;  // same sequence number again
            }
            std::perror("sendto");
            rc = 1;
            break;
        }
        ++sent;

        const int64_t t = now_ns();
        if (t >= next_report) {
            std::fprintf(stderr, "t=%.0fs sent=%llu pps=%llu retries=%llu\n", (t - t0) / 1e9,
                         static_cast<unsigned long long>(sent),
                         static_cast<unsigned long long>(sent - sent_at_report),
                         static_cast<unsigned long long>(retries));
            sent_at_report = sent;
            next_report += 1'000'000'000;
        }
    }
    const double elapsed = (now_ns() - t0) / 1e9;
    close(fd);

    const double pps = elapsed > 0 ? static_cast<double>(sent) / elapsed : 0;
    std::printf("dst=%s:%d\n", a.dst.c_str(), a.port);
    std::printf("payload_bytes=%d\n", a.size);
    std::printf("sent=%llu\n", static_cast<unsigned long long>(sent));
    std::printf("first_seq=%llu\n", static_cast<unsigned long long>(a.start_seq));
    std::printf("last_seq=%llu\n",
                static_cast<unsigned long long>(sent > 0 ? a.start_seq + sent - 1 : a.start_seq));
    std::printf("send_retries=%llu\n", static_cast<unsigned long long>(retries));
    std::printf("elapsed_s=%.3f\n", elapsed);
    std::printf("achieved_pps=%.1f\n", pps);
    std::printf("payload_mbps=%.3f\n", pps * a.size * 8 / 1e6);
    std::printf("wire_mbps=%.3f\n", pps * wire_bytes(a.size) * 8 / 1e6);
    std::printf("interrupted=%d\n", g_stop ? 1 : 0);
    return rc;
}
