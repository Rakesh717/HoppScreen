#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace hopp {
using Bytes = std::vector<uint8_t>;
// Validate the whole AU before emitting anything. VT uses four-byte AVCC lengths.
inline std::vector<Bytes> avcc(const uint8_t *p, size_t n) {
    std::vector<Bytes> out;
    while (n) {
        if (n < 4)
            throw std::runtime_error("truncated AVCC length");
        size_t len = (size_t(p[0]) << 24) | (size_t(p[1]) << 16) | (size_t(p[2]) << 8) | p[3];
        p += 4;
        n -= 4;
        if (!len || len > n || (p[0] & 0x80) || !(p[0] & 31) || (p[0] & 31) >= 24)
            throw std::runtime_error("invalid AVCC NAL");
        out.emplace_back(p, p + len);
        p += len;
        n -= len;
    }
    return out;
}

// RFC 6184 non-interleaved mode: single NAL, STAP-A, FU-A. Payload <= 1200 bytes.
inline std::vector<Bytes> payloads(const std::vector<Bytes> &nals, size_t mtu = 1200) {
    if (mtu < 3 || mtu > 65535)
        throw std::runtime_error("invalid RTP payload limit");
    std::vector<Bytes> out;
    for (size_t i = 0; i < nals.size();) {
        const auto &nal = nals[i];
        if (nal.empty())
            throw std::runtime_error("empty NAL");
        if (nal.size() > mtu) {
            for (size_t pos = 1; pos < nal.size();) {
                size_t len = std::min(mtu - 2, nal.size() - pos);
                Bytes fu{uint8_t((nal[0] & 0xe0) | 28),
                         uint8_t((nal[0] & 31) | (pos == 1 ? 0x80 : 0) |
                                 (pos + len == nal.size() ? 0x40 : 0))};
                fu.insert(fu.end(), nal.begin() + pos, nal.begin() + pos + len);
                out.push_back(std::move(fu));
                pos += len;
            }
            ++i;
            continue;
        }
        size_t end = i, total = 1;
        uint8_t nri = 0;
        while (end < nals.size() && !nals[end].empty() && total + 2 + nals[end].size() <= mtu) {
            total += 2 + nals[end].size();
            nri = std::max(nri, uint8_t(nals[end][0] & 0x60));
            ++end;
        }
        if (end > i + 1) {
            Bytes stap{uint8_t(nri | 24)};
            for (; i < end; ++i) {
                const auto &small = nals[i];
                stap.push_back(uint8_t(small.size() >> 8));
                stap.push_back(uint8_t(small.size()));
                stap.insert(stap.end(), small.begin(), small.end());
            }
            out.push_back(std::move(stap));
        } else {
            out.push_back(nal);
            ++i;
        }
    }
    return out;
}

inline Bytes rtp(const Bytes &payload, uint8_t pt, uint16_t seq, uint32_t ts, uint32_t ssrc,
                 bool marker) {
    Bytes out{0x80,
              uint8_t(pt | (marker ? 0x80 : 0)),
              uint8_t(seq >> 8),
              uint8_t(seq),
              uint8_t(ts >> 24),
              uint8_t(ts >> 16),
              uint8_t(ts >> 8),
              uint8_t(ts),
              uint8_t(ssrc >> 24),
              uint8_t(ssrc >> 16),
              uint8_t(ssrc >> 8),
              uint8_t(ssrc)};
    out.insert(out.end(), payload.begin(), payload.end());
    return out;
}
} // namespace hopp
