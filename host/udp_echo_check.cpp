// udp_echo_check: paced sender + echo checker for the eth-core-v0.2 gate (examples/udp_echo).
//
// Datagram i carries a payload fully determined by i: its length is drawn from
// [--min-size, --max-size] and its bytes from a splitmix64 stream seeded by i, so the
// checker regenerates it instead of storing it. Echoes come back on the same socket (the
// FPGA replies to the sender's port) and each is matched against every datagram still
// outstanding (the last kWindow sent, not yet echoed): a match is ok, and an ok echo of
// an older datagram than one already seen counts as reordered (the wire cannot reorder,
// but the host stack can, e.g. loopback across CPUs). An echo matching nothing
// outstanding (corrupt, duplicate) is mismatched. A datagram is lost if it has no
// intact echo by the time it leaves the window or the run ends, so
// echo_ok + lost == sent always. Linux only (POSIX sockets, CLOCK_MONOTONIC).
//
// Pacing busy-waits on an absolute CLOCK_MONOTONIC schedule (t0 + i / pps) and polls the
// socket non-blocking while it waits, so one thread both sends and receives. A send that
// fails with ENOBUFS/EAGAIN is retried with the same datagram. After the last send the
// checker keeps receiving for --drain-ms.
//
// Output: a progress line per second on stderr; a key=value summary on stdout, for the
// results sidecar. Exit code 0 only if every datagram came back intact.

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
constexpr uint64_t kWindow = 256;  // datagrams outstanding before one is declared lost
// Wire bytes per datagram beyond the payload: preamble+SFD 8, Ethernet 14, IPv4 20,
// UDP 8, FCS 4, IFG 12. Payloads under 18 bytes are padded to the 64-byte minimum.
constexpr int kWireOverhead = 8 + 14 + 20 + 8 + 4 + 12;
constexpr int kMinFramePayload = 18;

volatile std::sig_atomic_t g_stop = 0;
void on_signal(int) { g_stop = 1; }

int64_t now_ns() {
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1'000'000'000 + ts.tv_nsec;
}

uint64_t splitmix64(uint64_t& s) {
    uint64_t z = (s += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

struct Gen {
    int min_size;
    int max_size;
    uint64_t seed;

    // Payload of datagram i (deterministic).
    void make(uint64_t i, std::vector<uint8_t>& out) const {
        uint64_t s = seed ^ (i * 0xD1B54A32D192ED03ULL);
        const uint64_t span = static_cast<uint64_t>(max_size - min_size + 1);
        out.resize(static_cast<size_t>(min_size + static_cast<int>(splitmix64(s) % span)));
        for (size_t k = 0; k < out.size(); k += 8) {
            uint64_t r = splitmix64(s);
            for (size_t b = 0; b < 8 && k + b < out.size(); ++b) {
                out[k + b] = static_cast<uint8_t>(r >> (8 * b));
            }
        }
    }
};

int wire_bytes(size_t payload) {
    const int p = static_cast<int>(payload);
    return (p < kMinFramePayload ? kMinFramePayload : p) + kWireOverhead;
}

[[noreturn]] void usage(const char* argv0) {
    std::fprintf(stderr,
                 "usage: %s --dst IP --port N --pps N (--count N | --seconds S)\n"
                 "          [--min-size B] [--max-size B] [--seed N] [--if-ip IP]\n"
                 "          [--drain-ms MS]\n"
                 "  --dst       destination IPv4 (multicast group or unicast)\n"
                 "  --min-size, --max-size  payload length range, 1..%d (default 1..%d)\n"
                 "  --if-ip     local interface address (multicast egress and bind)\n"
                 "  --drain-ms  keep receiving this long after the last send (default 1000)\n",
                 argv0, kMaxPayload, kMaxPayload);
    std::exit(2);
}

struct Args {
    std::string dst;
    std::string if_ip;
    int port = -1;
    int min_size = 1;
    int max_size = kMaxPayload;
    uint64_t seed = 1;
    double pps = 0;
    uint64_t count = 0;
    double seconds = 0;
    int drain_ms = 1000;
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
        else if (k == "--min-size") a.min_size = std::atoi(v);
        else if (k == "--max-size") a.max_size = std::atoi(v);
        else if (k == "--seed") a.seed = std::strtoull(v, nullptr, 0);
        else if (k == "--pps") a.pps = std::atof(v);
        else if (k == "--count") a.count = std::strtoull(v, nullptr, 0);
        else if (k == "--seconds") a.seconds = std::atof(v);
        else if (k == "--drain-ms") a.drain_ms = std::atoi(v);
        else usage(argv[0]);
    }
    bool one_limit = (a.count > 0) != (a.seconds > 0);
    if (a.dst.empty() || a.port < 1 || a.port > 65535 || a.pps <= 0 || !one_limit ||
        a.min_size < 1 || a.max_size > kMaxPayload || a.min_size > a.max_size ||
        a.drain_ms < 0)
        usage(argv[0]);
    return a;
}

struct Checker {
    std::vector<std::vector<uint8_t>> ring = std::vector<std::vector<uint8_t>>(kWindow);
    std::vector<char> got = std::vector<char>(kWindow, 0);
    uint64_t lo = 0;        // oldest datagram not yet finalized
    uint64_t max_seen = 0;  // 1 + highest datagram echoed so far
    uint64_t ok = 0, lost = 0, mismatched = 0, reordered = 0, ok_bytes = 0;

    void finalize_below(uint64_t end) {
        for (; lo < end; ++lo) {
            if (!got[lo % kWindow]) ++lost;
        }
    }

    // Datagram j (= the count sent before it) is about to be sent with payload p.
    void on_send(uint64_t j, const std::vector<uint8_t>& p) {
        if (j >= kWindow) finalize_below(j - kWindow + 1);
        ring[j % kWindow] = p;
        got[j % kWindow] = 0;
    }

    void on_echo(const uint8_t* p, size_t n, uint64_t sent) {
        for (uint64_t j = lo; j < sent; ++j) {
            const auto& w = ring[j % kWindow];
            if (got[j % kWindow] || w.size() != n || std::memcmp(w.data(), p, n) != 0) continue;
            got[j % kWindow] = 1;
            ++ok;
            ok_bytes += n;
            if (j + 1 < max_seen) ++reordered;
            if (j + 1 > max_seen) max_seen = j + 1;
            return;
        }
        ++mismatched;
    }
};

}  // namespace

int main(int argc, char** argv) {
    const Args a = parse(argc, argv);
    const Gen gen{a.min_size, a.max_size, a.seed};

    sockaddr_in dst{};
    dst.sin_family = AF_INET;
    dst.sin_port = htons(static_cast<uint16_t>(a.port));
    if (inet_pton(AF_INET, a.dst.c_str(), &dst.sin_addr) != 1) usage(argv[0]);

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { std::perror("socket"); return 1; }
    const int rcvbuf = 8 << 20;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof rcvbuf);
    const unsigned char ttl = 1, loop = 0;  // direct cable: never route, never loop back
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof ttl);
    setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, sizeof loop);
    sockaddr_in local{};
    local.sin_family = AF_INET;
    local.sin_port = 0;  // ephemeral: the echo comes back to it
    local.sin_addr.s_addr = htonl(INADDR_ANY);
    if (!a.if_ip.empty()) {
        in_addr ifa{};
        if (inet_pton(AF_INET, a.if_ip.c_str(), &ifa) != 1) usage(argv[0]);
        if (setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifa, sizeof ifa) != 0) {
            std::perror("IP_MULTICAST_IF");
            return 1;
        }
    }
    if (bind(fd, reinterpret_cast<sockaddr*>(&local), sizeof local) != 0) {
        std::perror("bind");
        return 1;
    }

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    Checker chk;
    std::vector<uint8_t> buf;
    std::vector<uint8_t> rx(2048);
    const double period_ns = 1e9 / a.pps;
    const int64_t limit_ns = static_cast<int64_t>(a.seconds * 1e9);
    uint64_t sent = 0, retries = 0, sent_bytes = 0, wire = 0;
    int rc = 0;

    auto poll_rx = [&]() {
        for (;;) {
            ssize_t n = recv(fd, rx.data(), rx.size(), MSG_DONTWAIT);
            if (n < 0) return;
            chk.on_echo(rx.data(), static_cast<size_t>(n), sent);
        }
    };

    std::fprintf(stderr, "echo check: %d..%d-byte payloads to %s:%d at %.0f pps\n",
                 a.min_size, a.max_size, a.dst.c_str(), a.port, a.pps);
    const int64_t t0 = now_ns();
    int64_t next_report = t0 + 1'000'000'000;

    while (!g_stop) {
        if (a.count > 0 && sent >= a.count) break;
        const int64_t due = t0 + static_cast<int64_t>(static_cast<double>(sent) * period_ns);
        if (limit_ns > 0 && due - t0 >= limit_ns) break;
        while (now_ns() < due) poll_rx();

        gen.make(sent, buf);
        chk.on_send(sent, buf);
        ssize_t n = sendto(fd, buf.data(), buf.size(), 0, reinterpret_cast<sockaddr*>(&dst),
                           sizeof dst);
        if (n < 0) {
            if (errno == ENOBUFS || errno == EAGAIN || errno == EINTR) {
                ++retries;
                continue;  // same datagram again
            }
            std::perror("sendto");
            rc = 1;
            break;
        }
        ++sent;
        sent_bytes += buf.size();
        wire += static_cast<uint64_t>(wire_bytes(buf.size()));

        const int64_t t = now_ns();
        if (t >= next_report) {
            std::fprintf(stderr, "t=%.0fs sent=%llu ok=%llu lost=%llu mismatched=%llu\n",
                         (t - t0) / 1e9, static_cast<unsigned long long>(sent),
                         static_cast<unsigned long long>(chk.ok),
                         static_cast<unsigned long long>(chk.lost),
                         static_cast<unsigned long long>(chk.mismatched));
            next_report += 1'000'000'000;
        }
    }
    const double elapsed = (now_ns() - t0) / 1e9;
    const int64_t drain_end = now_ns() + static_cast<int64_t>(a.drain_ms) * 1'000'000;
    while (now_ns() < drain_end && chk.ok + chk.lost < sent) poll_rx();
    close(fd);
    chk.finalize_below(sent);
    const uint64_t lost = chk.lost;
    const double pps = elapsed > 0 ? static_cast<double>(sent) / elapsed : 0;
    std::printf("dst=%s:%d\n", a.dst.c_str(), a.port);
    std::printf("size_range=%d..%d\n", a.min_size, a.max_size);
    std::printf("seed=%llu\n", static_cast<unsigned long long>(a.seed));
    std::printf("sent=%llu\n", static_cast<unsigned long long>(sent));
    std::printf("echo_ok=%llu\n", static_cast<unsigned long long>(chk.ok));
    std::printf("lost=%llu\n", static_cast<unsigned long long>(lost));
    std::printf("mismatched=%llu\n", static_cast<unsigned long long>(chk.mismatched));
    std::printf("reordered=%llu\n", static_cast<unsigned long long>(chk.reordered));
    std::printf("payload_bytes_sent=%llu\n", static_cast<unsigned long long>(sent_bytes));
    std::printf("payload_bytes_ok=%llu\n", static_cast<unsigned long long>(chk.ok_bytes));
    std::printf("send_retries=%llu\n", static_cast<unsigned long long>(retries));
    std::printf("elapsed_s=%.3f\n", elapsed);
    std::printf("achieved_pps=%.1f\n", pps);
    std::printf("wire_mbps_each_way=%.3f\n", elapsed > 0 ? wire * 8 / elapsed / 1e6 : 0);
    std::printf("interrupted=%d\n", g_stop ? 1 : 0);
    if (rc == 0 && (lost != 0 || chk.mismatched != 0 || chk.ok != sent)) rc = 3;
    return rc;
}
