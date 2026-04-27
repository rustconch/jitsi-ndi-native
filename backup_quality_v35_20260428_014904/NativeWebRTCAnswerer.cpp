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
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

#if JNN_WITH_NATIVE_WEBRTC
#include <rtc/rtc.hpp>
#include "RtpSourceRegistry.h"






#endif

namespace {

bool startsWith(const std::string& value, const std::string& prefix) {
    return value.size() >= prefix.size()
        && value.compare(0, prefix.size(), prefix) == 0;
}

bool containsText(const std::string& value, const std::string& needle) {
    return value.find(needle) != std::string::npos;
}

std::string trimTrailingCr(std::string value) {
    if (!value.empty() && value.back() == '\r') {
        value.pop_back();
    }

    return value;
}

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

std::string joinStrings(const std::vector<std::string>& values, const std::string& separator) {
    std::ostringstream out;

    for (std::size_t i = 0; i < values.size(); ++i) {
        if (i > 0) {
            out << separator;
        }

        out << values[i];
    }

    return out.str();
}

bool isFocusBridgeSession(const JingleSession& session) {
    /*
        Jitsi may also send direct participant/P2P Jingle offers, for example:

            from='room@conference.meet.jit.si/a861d8f6'
            bridgeSessionId empty
            content names '0' and '1'

        Those sessions are NOT the JVB bridge session. If we answer them here,
        resetSession() kills the real focus/JVB PeerConnection and the participant
        may leave with unrecoverable_error.

        The JVB/focus session has bridge-session id and comes from /focus,
        with initiator focus@auth....
    */
    if (session.bridgeSessionId.empty()) {
        return false;
    }

    if (containsText(session.from, "/focus")) {
        return true;
    }

    if (containsText(session.initiator, "focus@")) {
        return true;
    }

    return false;
}

std::string extractPayloadTypeFromAttributeLine(
    const std::string& line,
    const std::string& prefix
) {
    if (!startsWith(line, prefix)) {
        return {};
    }

    std::size_t pos = prefix.size();
    std::string pt;

    while (pos < line.size()) {
        const char ch = line[pos];

        if (ch < '0' || ch > '9') {
            break;
        }

        pt.push_back(ch);
        ++pos;
    }

    return pt;
}

std::vector<std::string> extractVideoPayloadTypesByCodec(
    const std::string& sdp,
    const std::string& codecName
) {
    std::vector<std::string> payloadTypes;
    std::set<std::string> seen;

    std::istringstream input(sdp);
    std::string line;

    bool inVideo = false;

    while (std::getline(input, line)) {
        line = trimTrailingCr(line);

        if (startsWith(line, "m=")) {
            inVideo = startsWith(line, "m=video ");
            continue;
        }

        if (!inVideo) {
            continue;
        }

        if (!startsWith(line, "a=rtpmap:")) {
            continue;
        }

        const std::string pt = extractPayloadTypeFromAttributeLine(line, "a=rtpmap:");
        if (pt.empty()) {
            continue;
        }

        const std::string codecMarker = " " + codecName + "/";
        if (line.find(codecMarker) == std::string::npos) {
            continue;
        }

        if (seen.insert(pt).second) {
            payloadTypes.push_back(pt);
        }
    }

    return payloadTypes;
}

bool isCodecSpecificSdpAttributeForPayload(
    const std::string& line,
    const std::string& prefix,
    const std::set<std::string>& payloadTypes
) {
    const std::string pt = extractPayloadTypeFromAttributeLine(line, prefix);

    if (pt.empty()) {
        return false;
    }

    return payloadTypes.find(pt) != payloadTypes.end();
}

bool isCodecSpecificSdpAttribute(const std::string& line) {
    return startsWith(line, "a=rtpmap:")
        || startsWith(line, "a=fmtp:")
        || startsWith(line, "a=rtcp-fb:");
}

bool shouldKeepCodecSpecificVideoLine(
    const std::string& line,
    const std::set<std::string>& allowedPayloadTypes
) {
    if (startsWith(line, "a=rtpmap:")) {
        return isCodecSpecificSdpAttributeForPayload(line, "a=rtpmap:", allowedPayloadTypes);
    }

    if (startsWith(line, "a=fmtp:")) {
        return isCodecSpecificSdpAttributeForPayload(line, "a=fmtp:", allowedPayloadTypes);
    }

    if (startsWith(line, "a=rtcp-fb:")) {
        const std::string pt = extractPayloadTypeFromAttributeLine(line, "a=rtcp-fb:");

        /*
            Keep generic rtcp-fb lines such as a=rtcp-fb:* ...
            if they ever appear. Jitsi usually sends codec-specific lines.
        */
        if (pt.empty()) {
            return true;
        }

        return allowedPayloadTypes.find(pt) != allowedPayloadTypes.end();
    }

    return true;
}

std::string joinPayloadTypes(const std::vector<std::string>& payloadTypes) {
    std::ostringstream out;

    for (const auto& pt : payloadTypes) {
        if (pt.empty()) {
            continue;
        }

        if (out.tellp() > 0) {
            out << " ";
        }

        out << pt;
    }

    return out.str();
}

std::string forceVp8OnlyVideoSdp(const std::string& sdp) {
    // PATCH_V9_AV1_RESTORE_AUDIO_UNBLOCK:
    // Do not strip AV1. JVB/SFU forwards sender codec and current rooms send PT=41/AV1.
    return sdp;
}

/*
    buildSdpOfferFromJingle() writes source names into synthetic SDP:

        a=ssrc:3528528624 cname:866501ec-v0
        a=ssrc:1811570445 cname:e33a93f4-v0
        a=ssrc:702947349 cname:jvb-v0

    We extract real endpoint video source names from the video media section
    and ask JVB to forward those source names via ReceiverVideoConstraints.
*/
std::vector<std::string> extractVideoSourceNamesFromSdp(const std::string& sdp) {
    std::vector<std::string> sources;
    std::set<std::string> seen;

    std::istringstream input(sdp);
    std::string line;

    bool inVideo = false;

    while (std::getline(input, line)) {
        line = trimTrailingCr(line);

        if (startsWith(line, "m=")) {
            inVideo = startsWith(line, "m=video ");
            continue;
        }

        if (!inVideo) {
            continue;
        }

        if (!startsWith(line, "a=ssrc:")) {
            continue;
        }

        const std::string marker = " cname:";
        const auto markerPos = line.find(marker);

        if (markerPos == std::string::npos) {
            continue;
        }

        std::string name = line.substr(markerPos + marker.size());

        if (name.empty()) {
            continue;
        }

        if (startsWith(name, "jvb")) {
            continue;
        }

        if (name.find("-v") == std::string::npos) {
            continue;
        }

        if (seen.insert(name).second) {
            sources.push_back(name);
        }
    }

    return sources;
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

    for (char ch : value) {
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


std::vector<std::string> extractVideoSourcesMapSources(const std::string& text) {
    std::vector<std::string> values;
    std::set<std::string> seen;

    // JVB VideoSourcesMap messages contain entries like:
    // {"source":"endpoint-v0","owner":"endpoint",...}
    // We only run this parser after checking colibriClass == VideoSourcesMap,
    // so matching the plain "source" key is intentional and narrow enough here.
    const std::regex sourceRe("\\\"source\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"");

    for (auto it = std::sregex_iterator(text.begin(), text.end(), sourceRe);
         it != std::sregex_iterator();
         ++it) {
        const std::string value = (*it)[1].str();

        if (!value.empty() && seen.insert(value).second) {
            values.push_back(value);
        }
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

std::vector<std::string> normalizeVideoSourceNamesForConstraints(const std::vector<std::string>& sourceNames) {
    std::vector<std::string> out;

    for (const auto& name : sourceNames) {
        if (name.empty()) {
            continue;
        }

        // Do not spend the high-quality budget on the JVB mixed placeholder.
        // We want real per-participant sources like 2eba7589-v0.
        if (startsWith(name, "jvb")) {
            continue;
        }

        bool alreadyPresent = false;
        for (const auto& existing : out) {
            if (existing == name) {
                alreadyPresent = true;
                break;
            }
        }

        if (!alreadyPresent) {
            out.push_back(name);
        }
    }

    return out;
}

std::string makeReceiverVideoConstraintsMessage(
    const std::vector<std::string>& sourceNames,
    int maxHeight
) {
    /*
        Equal speaker priority mode:
        - Every real source is selected, which moves all requested speakers to the top of JVB allocation.
        - onStageSources is intentionally empty. Jitsi Meet also uses selectedSources for multiple pinned videos,
          because on-stage is best for one primary tile, while selectedSources is safer for many equal-priority tiles.
        - lastN=-1 asks the bridge not to cap the number of forwarded video sources on the receiver side.
        - defaultConstraints stays high so newly added real sources are not immediately capped low.
    */
    const std::vector<std::string> realSources = normalizeVideoSourceNamesForConstraints(sourceNames);
    const int lastN = -1;
    const std::vector<std::string> emptyOnStageSources;

    std::ostringstream out;

    out << "{";
    out << "\"colibriClass\":\"ReceiverVideoConstraints\",";
    out << "\"lastN\":" << lastN << ",";
    out << "\"assumedBandwidthBps\":250000000,";
    out << "\"selectedSources\":" << jsonStringArray(realSources) << ",";
    out << "\"onStageSources\":" << jsonStringArray(emptyOnStageSources) << ",";
    out << "\"defaultConstraints\":{\"maxHeight\":" << maxHeight << ",\"maxFrameRate\":30.0},";
    out << "\"constraints\":{";

    for (std::size_t i = 0; i < realSources.size(); ++i) {
        if (i > 0) {
            out << ",";
        }

        out
            << "\""
            << escapeJsonString(realSources[i])
            << "\":{\"maxHeight\":"
            << maxHeight
            << ",\"maxFrameRate\":30.0}";
    }

    out << "}";
    out << "}";

    return out.str();
}
void sendLastNUnlimited(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::string& reason
) {
    sendBridgeMessage(
        channel,
        "{\"colibriClass\":\"LastNChangedEvent\",\"lastN\":-1}",
        "LastN/unlimited/" + reason
    );
}

void sendReceiverVideoConstraints(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::vector<std::string>& sourceNames,
    const std::string& reason
) {
    const std::vector<std::string> realSources = normalizeVideoSourceNamesForConstraints(sourceNames);

    if (realSources.empty()) {
        Logger::warn(
            "NativeWebRTCAnswerer: equal 1080p constraints skipped because real video sources list is empty, reason=",
            reason
        );
        return;
    }

    sendLastNUnlimited(channel, reason);

    Logger::info(
        "NativeWebRTCAnswerer: requesting equal-priority 1080p/30fps constraints, realSources=",
        realSources.size(),
        " reason=",
        reason
    );

    sendBridgeMessage(
        channel,
        makeReceiverVideoConstraintsMessage(realSources, 1080),
        "ReceiverVideoConstraints/equal-priority-1080p/" + reason
    );
}
void sendReceiverAudioSubscriptionAll(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::string& reason
) {
    sendBridgeMessage(
        channel,
        "{\"colibriClass\":\"ReceiverAudioSubscription\",\"mode\":\"All\"}",
        "ReceiverAudioSubscription/" + reason
    );
}

void scheduleRepeatedAudioSubscriptionRefresh(
    const std::shared_ptr<rtc::DataChannel>& channel
) {
    if (!channel) {
        return;
    }

    std::thread([channel]() {
        const int delaysMs[] = {
            1000,
            3000,
            7000,
            15000,
            30000,
            60000
        };

        for (const int delayMs : delaysMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(delayMs));
            sendReceiverAudioSubscriptionAll(channel, "refresh");
        }
    }).detach();
}

void scheduleRepeatedVideoConstraintRefresh(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::shared_ptr<std::mutex>& sourcesMutex,
    const std::shared_ptr<std::vector<std::string>>& latestSources,
    const std::vector<std::string> fallbackSources
) {
    if (!channel || !sourcesMutex || !latestSources) {
        return;
    }

    std::thread([channel, sourcesMutex, latestSources, fallbackSources]() {
        const int delaysMs[] = {
            3000,
            10000,
            30000,
            60000
        };

        for (const int delayMs : delaysMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(delayMs));

            std::vector<std::string> copy;

            {
                std::lock_guard<std::mutex> lock(*sourcesMutex);
                copy = *latestSources;
            }

            if (copy.empty()) {
                copy = fallbackSources;
            }

            sendReceiverVideoConstraints(
                channel,
                copy,
                "refresh"
            );
        }
    }).detach();
}

#endif

} // namespace

struct NativeWebRTCAnswerer::Impl {
#if JNN_WITH_NATIVE_WEBRTC
    std::shared_ptr<rtc::PeerConnection> pc;
    std::shared_ptr<rtc::DataChannel> bridgeChannel;

    /*
        Important:
        Keep incoming remote tracks alive. If we only attach callbacks inside
        pc->onTrack() and do not store the shared_ptr, the track may be destroyed
        after the callback scope ends, and no RTP callback will ever fire.
    */
    std::shared_ptr<rtc::Track> remoteAudioTrack;
    std::shared_ptr<rtc::Track> remoteVideoTrack;

    /*
        Keep RTCP receiving sessions alive too. They are attached to tracks,
        but storing them makes lifetime explicit and easier to debug.
    */
    std::shared_ptr<rtc::RtcpReceivingSession> remoteAudioRtcpSession;
    std::shared_ptr<rtc::RtcpReceivingSession> remoteVideoRtcpSession;
#endif

    std::mutex mutex;
    std::condition_variable cv;

    bool localDescriptionReady = false;
    std::string localSdp;
};

NativeWebRTCAnswerer::NativeWebRTCAnswerer()
    : impl_(std::make_unique<Impl>()) {
}

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
        impl_->remoteAudioTrack.reset();
        impl_->remoteVideoTrack.reset();
        impl_->remoteAudioRtcpSession.reset();
        impl_->remoteVideoRtcpSession.reset();
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
    if (!isFocusBridgeSession(session)) {
        Logger::warn(
            "NativeWebRTCAnswerer: ignoring non-focus/non-JVB Jingle session. from=",
            session.from,
            " initiator=",
            session.initiator,
            " bridgeSessionId=",
            session.bridgeSessionId,
            " sid=",
            session.sid
        );

        return false;
    }

    resetSession();

    audioPackets_ = 0;
    videoPackets_ = 0;
    audioBytes_ = 0;
    videoBytes_ = 0;

    Logger::info("NativeWebRTCAnswerer: creating libdatachannel PeerConnection");
    Logger::warn("NativeWebRTCAnswerer: using remote onTrack raw RTP path with RTCP receiving session");

    const std::string rawOfferSdp = buildSdpOfferFromJingle(session);
    const std::string offerSdp = forceVp8OnlyVideoSdp(rawOfferSdp);

    if (offerSdp != rawOfferSdp) {
    }

    const std::vector<std::string> initialVideoSources = extractVideoSourceNamesFromSdp(rawOfferSdp);

    if (initialVideoSources.empty()) {
        Logger::warn("NativeWebRTCAnswerer: no initial video sources extracted from SDP offer");
    } else {
        Logger::info(
            "NativeWebRTCAnswerer: initial video sources extracted from SDP offer: ",
            joinStrings(initialVideoSources, ",")
        );
    }

    rtc::Configuration config;
    config.forceMediaTransport = true;

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

    const auto latestForwardedSources = std::make_shared<std::vector<std::string>>();
    const auto latestForwardedSourcesMutex = std::make_shared<std::mutex>();

    pc->onStateChange([](rtc::PeerConnection::State state) {
        Logger::info("NativeWebRTCAnswerer: PeerConnection state=", static_cast<int>(state));
    });

    pc->onGatheringStateChange([](rtc::PeerConnection::GatheringState state) {
        Logger::info("NativeWebRTCAnswerer: gathering state=", static_cast<int>(state));
    });

    std::shared_ptr<rtc::DataChannel> bridgeChannel;

    try {
        bridgeChannel = pc->createDataChannel("datachannel");

        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            impl_->bridgeChannel = bridgeChannel;
        }

        bridgeChannel->onOpen([
            bridgeChannel,
            latestForwardedSources,
            latestForwardedSourcesMutex,
            initialVideoSources
        ]() {
            Logger::info("NativeWebRTCAnswerer: bridge datachannel opened");

            sendBridgeMessage(
                bridgeChannel,
                "{\"colibriClass\":\"ClientHello\"}",
                "ClientHello"
            );

            sendReceiverAudioSubscriptionAll(bridgeChannel, "open");

            sendReceiverVideoConstraints(
                bridgeChannel,
                initialVideoSources,
                "open-sdp-sources"
            );

            scheduleRepeatedVideoConstraintRefresh(
                bridgeChannel,
                latestForwardedSourcesMutex,
                latestForwardedSources,
                initialVideoSources
            );

            scheduleRepeatedAudioSubscriptionRefresh(bridgeChannel);
        });

        bridgeChannel->onClosed([]() {
            Logger::warn("NativeWebRTCAnswerer: bridge datachannel closed");
        });

        bridgeChannel->onError([](std::string error) {
            Logger::warn("NativeWebRTCAnswerer: bridge datachannel error: ", error);
        });

        bridgeChannel->onMessage([
            bridgeChannel,
            latestForwardedSources,
            latestForwardedSourcesMutex,
            initialVideoSources
        ](rtc::message_variant message) {
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
                Logger::info("NativeWebRTCAnswerer: ServerHello received; sending SDP-source constraints");

                sendReceiverVideoConstraints(
                    bridgeChannel,
                    initialVideoSources,
                    "server-hello-sdp-sources"
                );

                sendReceiverAudioSubscriptionAll(bridgeChannel, "server-hello");

                return;
            }

            if (text.find("\"colibriClass\":\"VideoSourcesMap\"") != std::string::npos) {
                const auto sources = extractVideoSourcesMapSources(text);

                if (!sources.empty()) {
                    {
                        std::lock_guard<std::mutex> lock(*latestForwardedSourcesMutex);
                        *latestForwardedSources = sources;
                    }

                    Logger::info(
                        "NativeWebRTCAnswerer: VideoSourcesMap parsed count=",
                        sources.size(),
                        "; sending all-source equal-priority constraints"
                    );

                    sendReceiverVideoConstraints(
                        bridgeChannel,
                        sources,
                        "video-sources-map"
                    );
                }

                return;
            }

            if (text.find("\"colibriClass\":\"ForwardedSources\"") != std::string::npos) {
                const auto sources = extractJsonStringArray(text, "forwardedSources");

                {
                    std::lock_guard<std::mutex> lock(*latestForwardedSourcesMutex);
                    *latestForwardedSources = sources;
                }

                if (sources.empty()) {
                    Logger::info(
                        "NativeWebRTCAnswerer: ForwardedSources is empty; falling back to SDP-source constraints"
                    );

                    sendReceiverVideoConstraints(
                        bridgeChannel,
                        initialVideoSources,
                        "forwarded-empty-fallback-sdp-sources"
                    );

                    return;
                }

                Logger::info(
                    "NativeWebRTCAnswerer: ForwardedSources parsed count=",
                    sources.size(),
                    "; sending explicit source constraints"
                );

                sendReceiverVideoConstraints(
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
        std::string sdp = std::string(desc);
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
        if (!track) {
            Logger::warn("NativeWebRTCAnswerer: remote onTrack fired with null track");
            return;
        }

        std::string mid;

        try {
            mid = track->mid();
        } catch (...) {
            mid = "unknown";
        }

        Logger::info("NativeWebRTCAnswerer: remote track received and retained, mid=", mid);

        std::shared_ptr<rtc::RtcpReceivingSession> rtcpSession;

        try {
            rtcpSession = std::make_shared<rtc::RtcpReceivingSession>();
            track->setMediaHandler(rtcpSession);

            Logger::info(
                "NativeWebRTCAnswerer: RTCP receiving session attached to remote track mid=",
                mid
            );
        } catch (const std::exception& e) {
            Logger::warn(
                "NativeWebRTCAnswerer: failed to attach RTCP receiving session mid=",
                mid,
                ": ",
                e.what()
            );
        } catch (...) {
            Logger::warn(
                "NativeWebRTCAnswerer: failed to attach RTCP receiving session mid=",
                mid,
                ": unknown error"
            );
        }

        {
            std::lock_guard<std::mutex> lock(impl_->mutex);

            if (mid == "audio") {
                impl_->remoteAudioTrack = track;
                impl_->remoteAudioRtcpSession = rtcpSession;
                Logger::info("NativeWebRTCAnswerer: stored remote audio track");
            } else if (mid == "video") {
                impl_->remoteVideoTrack = track;
                impl_->remoteVideoRtcpSession = rtcpSession;
                Logger::info("NativeWebRTCAnswerer: stored remote video track");
            } else {
                Logger::warn("NativeWebRTCAnswerer: remote track has unknown mid=", mid);
            }
        }

        track->onOpen([mid]() {
            Logger::info("NativeWebRTCAnswerer: remote track opened, mid=", mid);
        });

        track->onClosed([mid]() {
            Logger::warn("NativeWebRTCAnswerer: remote track closed, mid=", mid);
        });

        /*
            Keep this as raw RTP for now.

            Do not attach VP8/H264/AV1 depacketizers here yet, because the next
            milestone is proving that RTP arrives at this callback. Decoding and
            NDI frame output should be layered after this counter starts moving.
        */
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

                if ((n % 200) == 0 || n == 1) {
                    Logger::info(
                        "NativeWebRTCAnswerer: RAW RTP audio packets=",
                        n,
                        " bytes=",
                        audioBytes_.load()
                    );
                }
            } else if (mid == "video") {
                const auto n = ++videoPackets_;
                videoBytes_ += size;

                if ((n % 100) == 0 || n == 1) {
                    Logger::info(
                        "NativeWebRTCAnswerer: RAW RTP video packets=",
                        n,
                        " bytes=",
                        videoBytes_.load()
                    );
                }
            } else {
                Logger::info(
                    "NativeWebRTCAnswerer: RAW RTP/data on unknown track mid=",
                    mid,
                    " bytes=",
                    size
                );
            }

            if (onMediaPacket_) {
                onMediaPacket_(mid, ptr, size);
            }
        });
    });

    Logger::info("NativeWebRTCAnswerer: setting remote Jitsi SDP-like offer");

    try {
        RtpSourceRegistry::registerFromSdp(offerSdp); // AV_STABILITY_REGISTER_SDP_SSRC
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

    outAnswer.sdp = forceVp8OnlyVideoSdp(impl_->localSdp);

    if (outAnswer.sdp != impl_->localSdp) {
    }

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


