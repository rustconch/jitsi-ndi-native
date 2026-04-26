#include "NativeWebRTCAnswerer.h"
#include "Logger.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <regex>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#if JNN_WITH_NATIVE_WEBRTC
#include <rtc/rtc.hpp>
#endif

namespace {

std::string extractSdpAttribute(const std::string& sdp, const std::string& name) {
    const std::regex re("(^|\\r?\\n)a=" + name + R"(:([^\r\n]+))", std::regex::icase);
    std::smatch m;

    if (std::regex_search(sdp, m, re) && m.size() > 2) {
        return m[2].str();
    }

    return {};
}

std::string extractFingerprint(const std::string& sdp) {
    const std::regex re(R"((^|\r?\n)a=fingerprint:sha-256\s+([^\r\n]+))", std::regex::icase);
    std::smatch m;

    if (std::regex_search(sdp, m, re) && m.size() > 2) {
        return m[2].str();
    }

    return {};
}

#if JNN_WITH_NATIVE_WEBRTC

void sendBridgeMessage(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::string& text,
    const std::string& label
) {
    if (!channel) {
        return;
    }

    try {
        channel->send(text);
        Logger::info("NativeWebRTCAnswerer: sent bridge message: ", label);
    } catch (const std::exception& e) {
        Logger::warn("NativeWebRTCAnswerer: failed to send bridge message ", label, ": ", e.what());
    } catch (...) {
        Logger::warn("NativeWebRTCAnswerer: failed to send bridge message ", label, ": unknown error");
    }
}

#endif

} // namespace

struct NativeWebRTCAnswerer::Impl {
#if JNN_WITH_NATIVE_WEBRTC
    std::shared_ptr<rtc::PeerConnection> pc;
    std::shared_ptr<rtc::DataChannel> bridgeChannel;
#endif

    std::mutex mutex;
    std::condition_variable cv;

    bool localDescriptionReady = false;
    std::string localSdp;
};

NativeWebRTCAnswerer::NativeWebRTCAnswerer()
    : impl_(std::make_unique<Impl>()) {}

NativeWebRTCAnswerer::~NativeWebRTCAnswerer() {
    resetSession();
}

void NativeWebRTCAnswerer::setIceServers(std::vector<IceServer> servers) {
    iceServers_ = std::move(servers);
}

void NativeWebRTCAnswerer::setLocalCandidateCallback(LocalCandidateCallback cb) {
    onLocalCandidate_ = std::move(cb);
}

void NativeWebRTCAnswerer::setMediaPacketCallback(MediaPacketCallback cb) {
    onMediaPacket_ = std::move(cb);
}

void NativeWebRTCAnswerer::resetSession() {
#if JNN_WITH_NATIVE_WEBRTC
    std::shared_ptr<rtc::PeerConnection> oldPc;
    std::shared_ptr<rtc::DataChannel> oldBridgeChannel;

    {
        std::lock_guard<std::mutex> lock(impl_->mutex);

        oldBridgeChannel = std::move(impl_->bridgeChannel);
        oldPc = std::move(impl_->pc);

        impl_->bridgeChannel.reset();
        impl_->pc.reset();

        impl_->localDescriptionReady = false;
        impl_->localSdp.clear();
    }

    if (oldBridgeChannel) {
        try {
            oldBridgeChannel->close();
        } catch (...) {
        }
    }

    if (oldPc) {
        Logger::info("NativeWebRTCAnswerer: resetting previous PeerConnection");

        try {
            oldPc->close();
        } catch (...) {
        }
    }
#else
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->localDescriptionReady = false;
    impl_->localSdp.clear();
#endif
}

bool NativeWebRTCAnswerer::createAnswer(const JingleSession& session, Answer& outAnswer) {
#if !JNN_WITH_NATIVE_WEBRTC
    (void)session;
    (void)outAnswer;

    Logger::warn("NativeWebRTCAnswerer: built without libdatachannel; no native answer created");
    return false;
#else
    resetSession();

    audioPackets_ = 0;
    videoPackets_ = 0;
    audioBytes_ = 0;
    videoBytes_ = 0;

    Logger::info("NativeWebRTCAnswerer: creating libdatachannel PeerConnection");

    rtc::Configuration config;

    for (const auto& server : iceServers_) {
        if (server.uri.empty()) {
            continue;
        }

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

    /*
        Jitsi Videobridge normally expects a bridge channel where the client sends:
          - ClientHello
          - ReceiverAudioSubscription
          - ReceiverVideoConstraints

        Without these messages, JVB may establish ICE/DTLS but still not forward RTP.
        If this datachannel does not open, the log will make that clear and the next step
        is adding/negotiating the Jitsi bridge channel explicitly via SDP/Jingle.
    */
    std::shared_ptr<rtc::DataChannel> bridgeChannel;

    try {
        bridgeChannel = pc->createDataChannel("datachannel");

        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            impl_->bridgeChannel = bridgeChannel;
        }

        bridgeChannel->onOpen([bridgeChannel]() {
            Logger::info("NativeWebRTCAnswerer: bridge datachannel opened");

            sendBridgeMessage(
                bridgeChannel,
                R"({"colibriClass":"ClientHello"})",
                "ClientHello"
            );

            sendBridgeMessage(
                bridgeChannel,
                R"({"colibriClass":"ReceiverAudioSubscription","mode":"All"})",
                "ReceiverAudioSubscription"
            );

            sendBridgeMessage(
                bridgeChannel,
                R"({"colibriClass":"ReceiverVideoConstraints","lastN":-1,"defaultConstraints":{"maxHeight":720},"constraints":{},"selectedSources":[],"onStageSources":[]})",
                "ReceiverVideoConstraints"
            );
        });

        bridgeChannel->onClosed([]() {
            Logger::warn("NativeWebRTCAnswerer: bridge datachannel closed");
        });

        bridgeChannel->onError([](std::string error) {
            Logger::warn("NativeWebRTCAnswerer: bridge datachannel error: ", error);
        });

        bridgeChannel->onMessage([](rtc::message_variant message) {
            if (std::holds_alternative<std::string>(message)) {
                Logger::info(
                    "NativeWebRTCAnswerer: bridge datachannel text: ",
                    std::get<std::string>(message)
                );
                return;
            }

            if (std::holds_alternative<rtc::binary>(message)) {
                const auto& data = std::get<rtc::binary>(message);

                std::string text;
                text.resize(data.size());

                if (!data.empty()) {
                    std::memcpy(text.data(), data.data(), data.size());
                }

                Logger::info("NativeWebRTCAnswerer: bridge datachannel binary/text: ", text);
            }
        });

        Logger::info("NativeWebRTCAnswerer: bridge datachannel created");
    } catch (const std::exception& e) {
        Logger::warn("NativeWebRTCAnswerer: could not create bridge datachannel: ", e.what());
    } catch (...) {
        Logger::warn("NativeWebRTCAnswerer: could not create bridge datachannel: unknown error");
    }

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

        LocalIceCandidate parsed;

        if (!parseLocalCandidateLine(text, parsed)) {
            Logger::warn("NativeWebRTCAnswerer: could not parse local candidate: ", text);
            return;
        }

        parsed.mid = candidate.mid();

        /*
            meet.jit.si / Jicofo often rejects relay candidates when we send them
            as Jingle transport-info. We still allow libdatachannel to use configured
            ICE servers internally, but we do not export relay candidates through XMPP.
        */
        if (parsed.type == "relay") {
            Logger::info(
                "NativeWebRTCAnswerer: skipping local relay candidate for Jingle transport-info: ",
                text
            );
            return;
        }

        if (onLocalCandidate_) {
            onLocalCandidate_(parsed);
        }
    });

    pc->onTrack([this](std::shared_ptr<rtc::Track> track) {
        std::string mid;

        try {
            mid = track->mid();
        } catch (...) {
            mid = "unknown";
        }

        Logger::info("NativeWebRTCAnswerer: remote track received, mid=", mid);

        track->onOpen([mid]() {
            Logger::info("NativeWebRTCAnswerer: track opened, mid=", mid);
        });

        track->onClosed([mid]() {
            Logger::info("NativeWebRTCAnswerer: track closed, mid=", mid);
        });

        track->onMessage([this, mid](rtc::message_variant message) {
            if (!std::holds_alternative<rtc::binary>(message)) {
                return;
            }

            const auto& data = std::get<rtc::binary>(message);
            const auto size = static_cast<std::size_t>(data.size());

            if (size == 0) {
                return;
            }

            const auto* ptr = reinterpret_cast<const std::uint8_t*>(data.data());

            if (mid == "audio") {
                const auto n = ++audioPackets_;
                audioBytes_ += size;

                if ((n % 500) == 0) {
                    Logger::info(
                        "NativeWebRTCAnswerer: RTP audio packets=",
                        n,
                        " bytes=",
                        audioBytes_.load()
                    );
                }
            } else {
                const auto n = ++videoPackets_;
                videoBytes_ += size;

                if ((n % 300) == 0) {
                    Logger::info(
                        "NativeWebRTCAnswerer: RTP video packets=",
                        n,
                        " bytes=",
                        videoBytes_.load()
                    );
                }
            }

            if (onMediaPacket_) {
                onMediaPacket_(mid, ptr, size);
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
    } catch (...) {
        Logger::error("NativeWebRTCAnswerer: setRemote/setLocal failed: unknown error");
        return false;
    }

    std::unique_lock<std::mutex> lock(impl_->mutex);

    if (!impl_->cv.wait_for(lock, std::chrono::seconds(10), [this]() {
            return impl_->localDescriptionReady;
        })) {
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

    if (!pc) {
        return;
    }

    try {
        pc->addRemoteCandidate(
            rtc::Candidate(
                candidate.candidateLine,
                candidate.mid.empty() ? "audio" : candidate.mid
            )
        );

        Logger::info(
            "NativeWebRTCAnswerer: remote ICE candidate added mid=",
            candidate.mid.empty() ? "audio" : candidate.mid
        );
    } catch (const std::exception& e) {
        Logger::warn("NativeWebRTCAnswerer: addRemoteCandidate failed: ", e.what());
    } catch (...) {
        Logger::warn("NativeWebRTCAnswerer: addRemoteCandidate failed: unknown error");
    }
#else
    (void)candidate;
#endif
}