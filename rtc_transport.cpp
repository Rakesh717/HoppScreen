#include "rtc_transport.h"
#include "rtc_packetizer.h"
#include <rtc/rtc.hpp>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>

namespace {
struct Session {
    std::shared_ptr<rtc::PeerConnection> pc;
    std::shared_ptr<rtc::Track> track;
    std::shared_ptr<rtc::RtpPacketizationConfig> config;
    std::mutex gatherMutex;
    std::condition_variable gathered;
    bool complete = false, started = false;
    uint16_t seq = uint16_t(arc4random());
    uint32_t origin = arc4random();
    int64_t firstPts = 0;
};
std::mutex mutex;
std::shared_ptr<Session> active;

std::vector<hopp::Bytes> parameterSets(const uint8_t *p, size_t n) {
    if (n < 7 || p[0] != 1 || (p[4] & 3) != 3)
        throw std::runtime_error("invalid avcC");
    size_t pos = 6;
    std::vector<hopp::Bytes> out;
    auto take = [&](unsigned count) {
        for (unsigned i = 0; i < count; ++i) {
            if (pos + 2 > n)
                throw std::runtime_error("truncated avcC");
            size_t len = (size_t(p[pos]) << 8) | p[pos + 1];
            pos += 2;
            if (!len || pos + len > n)
                throw std::runtime_error("truncated parameter set");
            out.emplace_back(p + pos, p + pos + len);
            pos += len;
        }
    };
    take(p[5] & 31);
    if (pos >= n)
        throw std::runtime_error("missing PPS count");
    take(p[pos++]);
    if (out.size() < 2)
        throw std::runtime_error("missing parameter sets");
    return out;
}
} // namespace

extern "C" char *hopp_rtc_offer(const char *sdp, void (*keyframe)(void), bool *ok) {
    std::lock_guard lock(mutex);
    *ok = false;
    try {
        rtc::Description offer(sdp, "offer");
        if (offer.mediaCount() != 1)
            throw std::runtime_error("spike accepts exactly one video m-line");
        auto entry = offer.media(0);
        auto video = std::get_if<rtc::Description::Media *>(&entry);
        if (!video || (*video)->type() != "video" ||
            (*video)->direction() != rtc::Description::Direction::RecvOnly)
            throw std::runtime_error("recvonly video required");
        int pt = -1;
        std::string profile;
        for (int candidate : (*video)->payloadTypes()) {
            auto map = (*video)->rtpMap(candidate);
            std::string params;
            for (auto &p : map->fmtps)
                params += p;
            // Existing encoder is High/ConstrainedHigh. Do not pretend it is Baseline.
            if (map->format == "H264" && params.find("packetization-mode=1") != std::string::npos &&
                params.find("profile-level-id=64") != std::string::npos) {
                pt = candidate;
                profile = params;
                break;
            }
        }
        if (pt < 0)
            throw std::runtime_error("offer must include H264 High, packetization-mode=1");
        auto session = std::make_shared<Session>();
        rtc::Configuration cfg;
        cfg.disableAutoNegotiation = true;
        session->pc = std::make_shared<rtc::PeerConnection>(cfg);
        session->pc->onStateChange([](rtc::PeerConnection::State state) {
            fprintf(stderr, "[rtc] state=%d\n", int(state));
        });
        std::weak_ptr<Session> weak = session;
        session->pc->onGatheringStateChange([weak](rtc::PeerConnection::GatheringState state) {
            if (state == rtc::PeerConnection::GatheringState::Complete)
                if (auto s = weak.lock()) {
                    std::lock_guard lock(s->gatherMutex);
                    s->complete = true;
                    s->gathered.notify_all();
                }
        });
        rtc::Description::Video desc((*video)->mid(), rtc::Description::Direction::SendOnly);
        desc.addH264Codec(pt, profile);
        uint32_t ssrc = arc4random();
        desc.addSSRC(ssrc, "hoppscreen", "hoppscreen", "screen");
        session->track = session->pc->addTrack(desc);
        session->config = std::make_shared<rtc::RtpPacketizationConfig>(ssrc, "hoppscreen", pt, 90000);
        auto sr = std::make_shared<rtc::RtcpSrReporter>(session->config);
        sr->addToChain(std::make_shared<rtc::RtcpNackResponder>(512));
        sr->addToChain(std::make_shared<rtc::PliHandler>(keyframe));
        sr->addToChain(std::make_shared<rtc::RembHandler>([](unsigned bps) {
            fprintf(stderr, "[rtc] REMB=%u bps (observed only; encoder remains manually capped)\n", bps);
        }));
        session->track->setMediaHandler(sr);
        session->track->onOpen([keyframe] { keyframe(); });
        session->pc->setRemoteDescription(offer);
        session->pc->setLocalDescription(rtc::Description::Type::Answer);
        std::unique_lock gatherLock(session->gatherMutex);
        if (!session->gathered.wait_for(gatherLock, std::chrono::seconds(10),
                                        [&] { return session->complete; }))
            throw std::runtime_error("ICE gathering timed out");
        std::string answer = std::string(*session->pc->localDescription());
        if (active)
            active->pc->close();
        active = session;
        fprintf(stderr, "[rtc] answer ready PT=%d SSRC=%u; single receiver replaces previous\n", pt, ssrc);
        *ok = true;
        return strdup(answer.c_str());
    } catch (const std::exception &e) {
        fprintf(stderr, "[rtc] offer rejected: %s\n", e.what());
        return strdup(e.what());
    }
}

extern "C" void hopp_rtc_frame(const uint8_t *data, size_t size, const uint8_t *config,
                                size_t configSize, int64_t pts, bool key) {
    // Never wait behind signaling or build an unbounded capture queue.
    std::unique_lock lock(mutex, std::try_to_lock);
    if (!lock || !active || !active->track->isOpen() || (!active->started && !key))
        return;
    try {
        auto nals = hopp::avcc(data, size);
        if (key) {
            auto sets = parameterSets(config, configSize);
            nals.insert(nals.begin(), sets.begin(), sets.end());
        }
        auto &s = *active;
        if (!s.started) {
            s.firstPts = pts;
            s.started = true;
            fprintf(stderr, "[rtc] first IDR sent\n");
        }
        uint32_t ts = s.origin + uint32_t((pts - s.firstPts) * 90 / 1000);
        s.config->timestamp = ts;
        auto packets = hopp::payloads(nals);
        for (size_t i = 0; i < packets.size(); ++i) {
            auto packet = hopp::rtp(packets[i], s.config->payloadType, s.seq++, ts, s.config->ssrc,
                                    i + 1 == packets.size());
            s.track->send(reinterpret_cast<const std::byte *>(packet.data()), packet.size());
        }
    } catch (const std::exception &e) {
        fprintf(stderr, "[rtc] frame dropped: %s\n", e.what());
    }
}
