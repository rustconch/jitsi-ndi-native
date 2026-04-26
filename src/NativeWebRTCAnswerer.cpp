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
#include <sstream>
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

std::string escapeJsonString(const std::string& value) {
    std::ostringstream out;

    for (const char ch : value) {
        switch (ch) {
        case '\\':
            out << "\\\\";
            break;
        case '"':
            out << "\\\"";
            break;
        case '\b':
            out << "\\b";
            break;
        case '\f':
            out << "\\f";
            break;
        case '\n':
            out << "\\n";
            break;
        case '\r':
            out << "\\r";
            break;
        case '\t':
            out << "\\t";
            break;
        default:
            out << ch;
            break;
        }
    }

    return out.str();
}

std::vector<std::string> extractJsonStringArray(
    const std::string& text,
    const std::string& key
) {
    std::vector<std::string> values;

    const std::regex arrayRe(
        "\\\"" + key + "\\\"\\s*:\\s*\\[([^\\]]*)\\]",
        std::regex::icase
    );

    std::smatch arrayMatch;

    if (!std::regex_search(text, arrayMatch, arrayRe) || arrayMatch.size() < 2) {
        return values;
    }

    const std::string body = arrayMatch[1].str();

    const std::regex stringRe("\\\"([^\\\"]+)\\\"");

    for (auto it = std::sregex_iterator(body.begin(), body.end(), stringRe);
         it != std::sregex_iterator();
         ++it) {
        values.push_back((*it)[1].str());
    }

    return values;
}

std::string jsonStringArray(const std::vector<std::string>& values) {
    std::ostringstream out;
    out << "[";

    for (std::size_t i = 0; i < values.size(); ++i) {
        if (i > 0) {
            out << ",";
        }

        out << "\"" << escapeJsonString(values[i]) << "\"";
    }

    out << "]";
    return out.str();
}

std::string makeReceiverVideoConstraintsMessage(
    const std::vector<std::string>& sources,
    int maxHeight
) {
    std::ostringstream out;

    out
        << "{"
        << "\"colibriClass\":\"ReceiverVideoConstraints\","
        << "\"lastN\":20,"
        << "\"selectedSources\":" << jsonStringArray(sources) << ","
        << "\"onStageSources\":" << jsonStringArray(sources) << ","
        << "\"defaultConstraints\":{\"maxHeight\":0,\"maxFrameRate\":30},"
        << "\"constraints\":{";

    for (std::size_t i = 0; i < sources.size(); ++i) {
        if (i > 0) {
            out << ",";
        }

        out
            << "\""
            << escapeJsonString(sources[i])
            << "\":{\"maxHeight\":"
            << maxHeight
            << ",\"maxFrameRate\":30}";
    }

    out << "}}";

    return out.str();
}

void sendReceiverVideoConstraintsForSources(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::vector<std::string>& sources,
    const std::string& reason
) {
    if (!channel || sources.empty()) {
        return;
    }

    const std::string msg = makeReceiverVideoConstraintsMessage(sources, 720);

    sendBridgeMessage(
        channel,
        msg,
        "ReceiverVideoConstraints/" + reason
    );
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
        Jitsi Videobridge needs the bridge datachannel. ICE/DTLS may connect without it,
        but RTP will not be forwarded until the client sends ClientHello/subscriptions/
        video constraints over the channel.
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
                "{\"colibriClass\":\"ClientHello\"}",
                "ClientHello"
            );

            sendBridgeMessage(
                bridgeChannel,
                "{\"colibriClass\":\"ReceiverAudioSubscription\",\"mode\":\"All\"}",
                "ReceiverAudioSubscription"
            );

            /*
                Initial broad request. In real browsers, Jitsi later refines constraints
                after forwarded sources / selected sources are known. We do the same in
                onMessage() after ForwardedSources arrives.
            */
            sendBridgeMessage(
                bridgeChannel,
                "{\"colibriClass\":\"ReceiverVideoConstraints\","
                "\"lastN\":20,"
                "\"defaultConstraints\":{\"maxHeight\":720,\"maxFrameRate\":30},"
                "\"constraints\":{},"
                "\"selectedSources\":[],"
                "\"onStageSources\":[]}",
                "ReceiverVideoConstraints/initial"
            );
        });

        bridgeChannel->onClosed([]() {
            Logger::warn("NativeWebRTCAnswerer: bridge datachannel closed");
        });

        bridgeChannel->onError([](std::string error) {
            Logger::warn("NativeWebRTCAnswerer: bridge datachannel error: ", error);
        });

        bridgeChannel->onMessage([bridgeChannel](rtc::message_variant message) {
            std::string text;

            if (std::holds_alternative<std::string>(message)) {
                text = std::get<std::string>(message);

                Logger::info(
                    "NativeWebRTCAnswerer: bridge datachannel text: ",
                    text
                );
            } else if (std::holds_alternative<rtc::binary>(message)) {
                const auto& data = std::get<rtc::binary>(message);

                text.resize(data.size());

                if (!data.empty()) {
                    std::memcpy(text.data(), data.data(), data.size());
                }

                Logger::info("NativeWebRTCAnswerer: bridge datachannel binary/text: ", text);
            } else {
                return;
            }

            if (text.find("\"colibriClass\":\"ServerHello\"") != std::string::npos) {
                Logger::info("NativeWebRTCAnswerer: ServerHello received; waiting for ForwardedSources");
                return;
            }

            if (text.find("\"colibriClass\":\"ForwardedSources\"") != std::string::npos) {
                const auto sources = extractJsonStringArray(text, "forwardedSources");

                if (sources.empty()) {
                    Logger::info("NativeWebRTCAnswerer: ForwardedSources is empty");
                    return;
                }

                Logger::info(
                    "NativeWebRTCAnswerer: ForwardedSources parsed count=",
                    sources.size(),
                    "; sending explicit source constraints"
                );

                sendReceiverVideoConstraintsForSources(
                    bridgeChannel,
                    sources,
                    "forwarded-sources"
                );
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

        /*
            This helps libdatachannel maintain receiving-side RTCP state and send
            receiver reports / feedback. It should not decode RTP, but it makes the
            receiving track closer to a real WebRTC endpoint.
        */
        try {
            track->setMediaHandler(std::make_shared<rtc::RtcpReceivingSession>());
            Logger::info("NativeWebRTCAnswerer: RTCP receiving session attached, mid=", mid);
        } catch (const std::exception& e) {
            Logger::warn(
                "NativeWebRTCAnswerer: could not attach RTCP receiving session, mid=",
                mid,
                ": ",
                e.what()
            );
        } catch (...) {
            Logger::warn(
                "NativeWebRTCAnswerer: could not attach RTCP receiving session, mid=",
                mid,
                ": unknown error"
            );
        }

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

                if ((n % 500) == 0 || n == 1) {
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

                if ((n % 300) == 0 || n == 1) {
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