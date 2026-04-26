#include "NativeWebRTCAnswerer.h"
#include "Logger.h"

#include <chrono>
#include <regex>
#include <sstream>

#if JNN_WITH_NATIVE_WEBRTC
#include <rtc/rtc.hpp>
#endif

namespace {

std::string extractSdpAttribute(const std::string& sdp, const std::string& name) {
    const std::regex re("(^|\\r?\\n)a=" + name + R"(:([^\r\n]+))", std::regex::icase);
    std::smatch m;
    if (std::regex_search(sdp, m, re) && m.size() > 2) return m[2].str();
    return {};
}

std::string extractFingerprint(const std::string& sdp) {
    const std::regex re(R"((^|\r?\n)a=fingerprint:sha-256\s+([^\r\n]+))", std::regex::icase);
    std::smatch m;
    if (std::regex_search(sdp, m, re) && m.size() > 2) return m[2].str();
    return {};
}

} // namespace

struct NativeWebRTCAnswerer::Impl {
#if JNN_WITH_NATIVE_WEBRTC
    std::shared_ptr<rtc::PeerConnection> pc;
#endif
    std::mutex mutex;
    std::condition_variable cv;
    bool localDescriptionReady = false;
    std::string localSdp;
    bool sessionAcceptSent = false;
};

NativeWebRTCAnswerer::NativeWebRTCAnswerer() : impl_(std::make_unique<Impl>()) {}

NativeWebRTCAnswerer::~NativeWebRTCAnswerer() {
    resetSession();
}

void NativeWebRTCAnswerer::setIceServers(std::vector<IceServer> servers) {
    iceServers_ = std::move(servers);
}

void NativeWebRTCAnswerer::setLocalCandidateCallback(LocalCandidateCallback cb) {
    onLocalCandidate_ = std::move(cb);
}

void NativeWebRTCAnswerer::resetSession() {
#if JNN_WITH_NATIVE_WEBRTC
    std::shared_ptr<rtc::PeerConnection> old;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        old = std::move(impl_->pc);
        impl_->pc.reset();
        impl_->localDescriptionReady = false;
        impl_->localSdp.clear();
        impl_->sessionAcceptSent = false;
    }
    if (old) {
        Logger::info("NativeWebRTCAnswerer: resetting previous PeerConnection");
        try { old->close(); } catch (...) {}
    }
#else
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->localDescriptionReady = false;
    impl_->localSdp.clear();
    impl_->sessionAcceptSent = false;
#endif
}

bool NativeWebRTCAnswerer::createAnswer(const JingleSession& session, Answer& outAnswer) {
#if !JNN_WITH_NATIVE_WEBRTC
    (void)session;
    Logger::warn("NativeWebRTCAnswerer: built without libdatachannel; no native answer created");
    return false;
#else
    resetSession();

    Logger::info("NativeWebRTCAnswerer: creating libdatachannel PeerConnection");

    rtc::Configuration config;
    for (const auto& server : iceServers_) {
        if (server.uri.empty()) continue;
        Logger::info("NativeWebRTCAnswerer: ICE server: ", server.uri);
        config.iceServers.emplace_back(server.uri);
    }

    auto pc = std::make_shared<rtc::PeerConnection>(config);
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->pc = pc;
    }

    pc->onStateChange([](rtc::PeerConnection::State state) {
        Logger::info("NativeWebRTCAnswerer: PeerConnection state=", static_cast<int>(state));
    });

    pc->onGatheringStateChange([](rtc::PeerConnection::GatheringState state) {
        Logger::info("NativeWebRTCAnswerer: gathering state=", static_cast<int>(state));
    });

    pc->onLocalDescription([this](rtc::Description desc) {
        const std::string sdp = std::string(desc);
        const std::string type = desc.typeString();
        Logger::info("NativeWebRTCAnswerer: local SDP description generated, type=", type);
        if (type != "answer") {
            Logger::warn("NativeWebRTCAnswerer: ignoring non-answer local description type=", type);
            return;
        }
        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            impl_->localSdp = sdp;
            impl_->localDescriptionReady = true;
        }
        impl_->cv.notify_all();
    });

    pc->onLocalCandidate([this](rtc::Candidate candidate) {
        const std::string text = candidate.candidate();
        Logger::info("NativeWebRTCAnswerer: local ICE candidate=", text);

        LocalIceCandidate parsed;
        if (!parseLocalCandidateLine(text, parsed)) {
            Logger::warn("NativeWebRTCAnswerer: could not parse local candidate: ", text);
            return;
        }
        parsed.mid = candidate.mid();

        // Jitsi meet.jit.si currently accepts srflx/host here, while some libjuice relay lines are rejected
        // as bad-request in Jingle transport-info. The TURN URI is still kept in PeerConnection for ICE.
        if (parsed.type == "relay") {
            Logger::info("NativeWebRTCAnswerer: skipping local relay candidate for Jingle transport-info: ", text);
            return;
        }

        if (onLocalCandidate_) onLocalCandidate_(parsed);
    });

    pc->onTrack([this](std::shared_ptr<rtc::Track> track) {
        std::string mid;
        try { mid = track->mid(); } catch (...) { mid = "unknown"; }
        Logger::info("NativeWebRTCAnswerer: remote track received, mid=", mid);

        try {
            const std::string mediaType = track->description().type();
            if (mediaType == "video") {
                track->setMediaHandler(std::make_shared<rtc::VP8RtpDepacketizer>());
                track->chainMediaHandler(std::make_shared<rtc::RtcpReceivingSession>());
                track->onFrame([this, mid](rtc::binary frame, rtc::FrameInfo info) {
                    const auto n = ++videoPackets_;
                    videoBytes_ += static_cast<std::uint64_t>(frame.size());
                    if ((n % 30) == 0) {
                        Logger::info("NativeWebRTCAnswerer: VP8 frames=", n, " bytes=", videoBytes_.load());
                    }
                });
            } else {
                track->chainMediaHandler(std::make_shared<rtc::RtcpReceivingSession>());
            }
        } catch (const std::exception& e) {
            Logger::warn("NativeWebRTCAnswerer: could not attach media handler: ", e.what());
        }

        track->onOpen([this, mid]() {
            Logger::info("NativeWebRTCAnswerer: track opened, mid=", mid);
        });

        track->onClosed([mid]() {
            Logger::info("NativeWebRTCAnswerer: track closed, mid=", mid);
        });

        track->onMessage([this, mid](rtc::binary data) {
            const auto size = static_cast<std::uint64_t>(data.size());
            if (mid == "audio") {
                const auto n = ++audioPackets_;
                audioBytes_ += size;
                if ((n % 500) == 0) Logger::info("NativeWebRTCAnswerer: RTP audio packets=", n, " bytes=", audioBytes_.load());
            } else {
                const auto n = ++videoPackets_;
                videoBytes_ += size;
                if ((n % 300) == 0) Logger::info("NativeWebRTCAnswerer: RTP video packets=", n, " bytes=", videoBytes_.load());
            }
        });
    });

    const std::string offerSdp = buildSdpOfferFromJingle(session);
    Logger::info("NativeWebRTCAnswerer: setting remote Jitsi SDP-like offer");
    try {
        pc->setRemoteDescription(rtc::Description(offerSdp, "offer"));
        pc->setLocalDescription();
    } catch (const std::exception& e) {
        Logger::error("NativeWebRTCAnswerer: setRemote/setLocal failed: ", e.what());
        return false;
    }

    std::unique_lock<std::mutex> lock(impl_->mutex);
    if (!impl_->cv.wait_for(lock, std::chrono::seconds(10), [this]() { return impl_->localDescriptionReady; })) {
        Logger::error("NativeWebRTCAnswerer: timeout waiting for local answer");
        return false;
    }

    outAnswer.sdp = impl_->localSdp;
    outAnswer.iceUfrag = extractSdpAttribute(outAnswer.sdp, "ice-ufrag");
    outAnswer.icePwd = extractSdpAttribute(outAnswer.sdp, "ice-pwd");
    outAnswer.fingerprint = extractFingerprint(outAnswer.sdp);

    if (outAnswer.iceUfrag.empty() || outAnswer.icePwd.empty() || outAnswer.fingerprint.empty()) {
        Logger::error("NativeWebRTCAnswerer: local answer is missing ICE/fingerprint fields");
        return false;
    }

    Logger::info("NativeWebRTCAnswerer: answer is ready");
    return true;
#endif
}

void NativeWebRTCAnswerer::addRemoteCandidate(const LocalIceCandidate& candidate) {
#if JNN_WITH_NATIVE_WEBRTC
    std::shared_ptr<rtc::PeerConnection> pc;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        pc = impl_->pc;
    }
    if (!pc) return;

    try {
        pc->addRemoteCandidate(rtc::Candidate(candidate.candidateLine, candidate.mid.empty() ? "audio" : candidate.mid));
        Logger::info("NativeWebRTCAnswerer: remote ICE candidate added mid=", candidate.mid.empty() ? "audio" : candidate.mid,
                     " ", candidate.candidateLine);
    } catch (const std::exception& e) {
        Logger::warn("NativeWebRTCAnswerer: addRemoteCandidate failed: ", e.what());
    }
#else
    (void)candidate;
#endif
}
