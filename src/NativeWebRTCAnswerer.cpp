#include "NativeWebRTCAnswerer.h"
#include "Logger.h"

#include <rtc/rtc.hpp>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <utility>
#include <condition_variable>
#include <regex>
#include <sstream>
#include <thread>

struct NativeWebRTCAnswerer::ParsedCandidate {
    std::string foundation;
    int component = 1;
    std::string protocol = "udp";
    std::uint32_t priority = 0;
    std::string ip;
    int port = 0;
    std::string type = "host";
};

NativeWebRTCAnswerer::NativeWebRTCAnswerer() = default;
NativeWebRTCAnswerer::~NativeWebRTCAnswerer() {
    closeCurrentPeerConnection();
}

void NativeWebRTCAnswerer::setIceServers(std::vector<std::string> servers) {
    iceServers_ = std::move(servers);
}

void NativeWebRTCAnswerer::setResponderJid(std::string jid) {
    activeResponder_ = std::move(jid);
}

void NativeWebRTCAnswerer::closeCurrentPeerConnection() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (pc_) {
        try { pc_->close(); } catch (...) {}
        pc_.reset();
    }
    sessionAcceptSent_ = false;
    queuedLocalCandidates_.clear();
}

NativeWebRTCAnswerResult NativeWebRTCAnswerer::acceptOffer(
    const JingleSessionInitiate& session,
    const std::string& offerSdp,
    LocalCandidateCallback localCandidateCallback
) {
    NativeWebRTCAnswerResult result;

    try {
        closeCurrentPeerConnection();

        Logger::info("NativeWebRTCAnswerer: creating libdatachannel PeerConnection");

        activeSid_ = session.sid;
        // activeResponder_ is set by JitsiSignaling from the bound XMPP JID.
        activeInitiator_ = session.initiator.empty() ? "focus@auth.meet.jit.si/focus" : session.initiator;
        activeFocusJid_ = session.from;
        localCandidateCallback_ = std::move(localCandidateCallback);
        transportInfoCounter_ = 1;

        rtc::Configuration cfg;
        for (const auto& server : iceServers_) {
            if (!server.empty()) {
                Logger::info("NativeWebRTCAnswerer: ICE server: ", server);
                cfg.iceServers.emplace_back(server);
            }
        }

        pc_ = std::make_shared<rtc::PeerConnection>(cfg);

        std::mutex localMutex;
        std::condition_variable cv;
        bool localReady = false;
        std::string localSdp;

        pc_->onStateChange([](rtc::PeerConnection::State state) {
            Logger::info("NativeWebRTCAnswerer: PeerConnection state=", static_cast<int>(state));
        });

        pc_->onGatheringStateChange([](rtc::PeerConnection::GatheringState state) {
            Logger::info("NativeWebRTCAnswerer: gathering state=", static_cast<int>(state));
        });

        pc_->onLocalCandidate([this](rtc::Candidate candidate) {
            const std::string line = std::string(candidate);
            const std::string mid = "audio";
            Logger::info("NativeWebRTCAnswerer: local ICE candidate=a=", line);
            queueOrSendLocalCandidate(line, mid);
        });

        pc_->onLocalDescription([&](rtc::Description description) {
            const std::string type = description.typeString();
            Logger::info("NativeWebRTCAnswerer: local SDP description generated, type=", type);
            if (type == "answer") {
                {
                    std::lock_guard<std::mutex> lock(localMutex);
                    localSdp = std::string(description);
                    localReady = true;
                }
                cv.notify_all();
            }
        });

        pc_->onTrack([](std::shared_ptr<rtc::Track> track) {
            Logger::info("NativeWebRTCAnswerer: remote track received");
            track->onOpen([]() {
                Logger::info("NativeWebRTCAnswerer: track opened");
            });
            track->onClosed([]() {
                Logger::info("NativeWebRTCAnswerer: track closed");
            });
            // Important for the current experimental stage:
            // do not bind onMessage yet. Raw RTP payload handling/depayload/decode
            // must be added deliberately, otherwise we risk crashes right after track opened.
        });

        Logger::info("NativeWebRTCAnswerer: setting remote Jitsi SDP-like offer");
        pc_->setRemoteDescription(rtc::Description(offerSdp, rtc::Description::Type::Offer));
        pc_->setLocalDescription();

        {
            std::unique_lock<std::mutex> lock(localMutex);
            cv.wait_for(lock, std::chrono::seconds(3), [&] { return localReady; });
        }

        if (localSdp.empty()) {
            result.error = "timeout waiting for local SDP answer";
            return result;
        }

        localUfrag_ = extractSdpLineValue(localSdp, "a=ice-ufrag:");
        localPwd_ = extractSdpLineValue(localSdp, "a=ice-pwd:");

        result.localSdp = localSdp;
        result.sessionAcceptXml = buildSessionAcceptXml(session, localSdp);
        result.ok = !result.sessionAcceptXml.empty();
        if (!result.ok) result.error = "could not build Jingle session-accept";

        Logger::info("NativeWebRTCAnswerer: answer is ready");

        sessionAcceptSent_ = true;
        flushQueuedLocalCandidates();
        return result;
    } catch (const std::exception& e) {
        result.error = e.what();
        Logger::warn("NativeWebRTCAnswerer: acceptOffer exception: ", e.what());
        return result;
    } catch (...) {
        result.error = "unknown exception";
        Logger::warn("NativeWebRTCAnswerer: acceptOffer unknown exception");
        return result;
    }
}

void NativeWebRTCAnswerer::queueOrSendLocalCandidate(const std::string& candidateLine, const std::string& mid) {
    ParsedCandidate parsed;
    if (!parseCandidateLine(candidateLine, parsed)) {
        Logger::warn("NativeWebRTCAnswerer: could not parse local ICE candidate: ", candidateLine);
        return;
    }

    // meet.jit.si/Jicofo often rejects relay candidates sent back as Jingle transport-info.
    // Keep them inside libdatachannel, but do not send them via XMPP.
    if (parsed.type == "relay") {
        Logger::info("NativeWebRTCAnswerer: skipping local relay candidate for Jingle transport-info: a=", candidateLine);
        return;
    }

    if (!sessionAcceptSent_) {
        std::lock_guard<std::mutex> lock(mutex_);
        queuedLocalCandidates_.push_back({candidateLine, mid});
        Logger::info("NativeWebRTCAnswerer: local ICE candidate queued until session-accept is sent");
        return;
    }

    const std::string xml = buildTransportInfoXml(parsed, mid.empty() ? "audio" : mid);
    if (!xml.empty() && localCandidateCallback_) {
        Logger::info("NativeWebRTCAnswerer: sending local ICE candidate as Jingle transport-info");
        localCandidateCallback_(xml);
    }
}

void NativeWebRTCAnswerer::flushQueuedLocalCandidates() {
    std::vector<std::pair<std::string, std::string>> pending;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        pending.swap(queuedLocalCandidates_);
    }

    for (const auto& item : pending) {
        Logger::info("NativeWebRTCAnswerer: flushing queued local ICE candidate as Jingle transport-info");
        queueOrSendLocalCandidate(item.first, item.second);
    }
}

std::string NativeWebRTCAnswerer::buildSessionAcceptXml(const JingleSessionInitiate& session, const std::string& localSdp) const {
    const std::string ufrag = extractSdpLineValue(localSdp, "a=ice-ufrag:");
    const std::string pwd = extractSdpLineValue(localSdp, "a=ice-pwd:");
    const std::string fingerprintLine = extractSdpLineValue(localSdp, "a=fingerprint:sha-256 ");

    if (session.sid.empty() || session.from.empty() || ufrag.empty() || pwd.empty() || fingerprintLine.empty()) {
        Logger::warn("NativeWebRTCAnswerer: cannot build session-accept: sid/from/ice/fingerprint missing");
        return {};
    }

    std::ostringstream iq;
    iq << "<iq xmlns='jabber:client' type='set' to='" << xmlEscape(session.from) << "' id='jitsi_ndi_session_accept_" << transportInfoCounter_++ << "'>";
    iq << "<jingle xmlns='urn:xmpp:jingle:1' action='session-accept'"
       << " initiator='" << xmlEscape(activeInitiator_) << "'"
       << (activeResponder_.empty() ? std::string() : std::string(" responder='") + xmlEscape(activeResponder_) + "'")
       << " sid='" << xmlEscape(session.sid) << "'>";

    iq << "<group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='BUNDLE'>";
    for (const auto& c : session.contents) {
        if (c.name == "audio" || c.name == "video") {
            iq << "<content name='" << xmlEscape(c.name) << "'/>";
        }
    }
    iq << "</group>";

    for (const auto& c : session.contents) {
        if (c.name != "audio" && c.name != "video") continue;

        iq << "<content creator='initiator' name='" << xmlEscape(c.name) << "' senders='both'>";
        iq << "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='" << xmlEscape(c.media) << "'>";

        if (c.media == "audio") {
            iq << "<payload-type id='111' name='opus' clockrate='48000' channels='2'>"
               << "<parameter name='minptime' value='10'/>"
               << "<parameter name='useinbandfec' value='1'/>"
               << "</payload-type>"
               << "<payload-type id='126' name='telephone-event' clockrate='8000'/>"
               << "<rtp-hdrext xmlns='urn:xmpp:jingle:apps:rtp:rtp-hdrext:0' id='1' uri='urn:ietf:params:rtp-hdrext:ssrc-audio-level'/>";
        } else {
            iq << "<payload-type id='100' name='VP8' clockrate='90000'>"
               << "<rtcp-fb xmlns='urn:xmpp:jingle:apps:rtp:rtcp-fb:0' type='ccm' subtype='fir'/>"
               << "<rtcp-fb xmlns='urn:xmpp:jingle:apps:rtp:rtcp-fb:0' type='nack'/>"
               << "<rtcp-fb xmlns='urn:xmpp:jingle:apps:rtp:rtcp-fb:0' type='nack' subtype='pli'/>"
               << "</payload-type>"
               << "<rtp-hdrext xmlns='urn:xmpp:jingle:apps:rtp:rtp-hdrext:0' id='3' uri='http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time'/>";
        }

        iq << "<extmap-allow-mixed xmlns='urn:xmpp:jingle:apps:rtp:rtp-hdrext:0'/>"
           << "<rtcp-mux/>"
           << "</description>";

        iq << "<transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='" << xmlEscape(ufrag)
           << "' pwd='" << xmlEscape(pwd) << "'>"
           << "<rtcp-mux/>"
           << "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' required='true' setup='active'>"
           << xmlEscape(fingerprintLine)
           << "</fingerprint>"
           << "</transport>";

        iq << "</content>";
    }

    iq << "</jingle></iq>";
    return iq.str();
}

std::string NativeWebRTCAnswerer::buildTransportInfoXml(const ParsedCandidate& c, const std::string& mid) const {
    if (activeSid_.empty() || activeFocusJid_.empty() || c.ip.empty() || c.port <= 0) return {};

    std::ostringstream iq;
    const int idNumber = transportInfoCounter_++;
    iq << "<iq xmlns='jabber:client' type='set' to='" << xmlEscape(activeFocusJid_) << "' id='jitsi_ndi_transport_info_" << idNumber << "'>";
    iq << "<jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='" << xmlEscape(activeSid_) << "'>";
    iq << "<content creator='initiator' name='" << xmlEscape(mid.empty() ? "audio" : mid) << "'>";
    iq << "<transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='" << xmlEscape(localUfrag_) << "' pwd='" << xmlEscape(localPwd_) << "'>";
    iq << "<rtcp-mux/>";
    iq << "<candidate component='" << c.component
       << "' foundation='" << xmlEscape(c.foundation.empty() ? std::to_string(idNumber) : c.foundation)
       << "' generation='0' id='local_" << idNumber << "_" << c.port
       << "' ip='" << xmlEscape(c.ip)
       << "' network='0' port='" << c.port
       << "' priority='" << c.priority
       << "' protocol='" << xmlEscape(c.protocol.empty() ? "udp" : c.protocol)
       << "' type='" << xmlEscape(c.type.empty() ? "host" : c.type)
       << "'/>";
    iq << "</transport></content></jingle></iq>";
    return iq.str();
}

bool NativeWebRTCAnswerer::addRemoteCandidatesFromTransportInfo(const std::string& xml) {
    if (!pc_) return false;

    const std::string iqTag = firstTag(xml, "iq");
    if (iqTag.find("type='error'") != std::string::npos || iqTag.find("type=\"error\"") != std::string::npos) {
        Logger::info("NativeWebRTCAnswerer: ignoring error transport-info stanza");
        return false;
    }

    const std::string contentTag = firstTag(xml, "content");
    const std::string mid = attr(contentTag, "name").empty() ? "audio" : attr(contentTag, "name");

    std::regex candRe(R"(<candidate(?:\s|/|>)[^>]*>)");
    bool added = false;
    auto begin = std::sregex_iterator(xml.begin(), xml.end(), candRe);
    auto end = std::sregex_iterator();

    for (auto it = begin; it != end; ++it) {
        const std::string tag = it->str();
        ParsedCandidate c;
        c.foundation = attr(tag, "foundation");
        c.component = std::max(1, std::atoi(attr(tag, "component").c_str()));
        c.protocol = attr(tag, "protocol").empty() ? "udp" : attr(tag, "protocol");
        c.priority = static_cast<std::uint32_t>(std::strtoul(attr(tag, "priority").c_str(), nullptr, 10));
        c.ip = attr(tag, "ip");
        c.port = std::atoi(attr(tag, "port").c_str());
        c.type = attr(tag, "type").empty() ? "host" : attr(tag, "type");

        if (c.ip.empty() || c.port <= 0) continue;

        std::ostringstream line;
        line << "candidate:" << (c.foundation.empty() ? "1" : c.foundation)
             << " " << c.component
             << " " << c.protocol
             << " " << c.priority
             << " " << c.ip
             << " " << c.port
             << " typ " << c.type;

        try {
            pc_->addRemoteCandidate(rtc::Candidate(line.str(), mid));
            Logger::info("NativeWebRTCAnswerer: remote ICE candidate added mid=", mid, " ", line.str());
            added = true;
        } catch (const std::exception& e) {
            Logger::warn("NativeWebRTCAnswerer: addRemoteCandidate failed: ", e.what());
        }
    }

    return added;
}

std::string NativeWebRTCAnswerer::xmlEscape(const std::string& value) {
    std::string out;
    for (char c : value) {
        switch (c) {
            case '&': out += "&amp;"; break;
            case '<': out += "&lt;"; break;
            case '>': out += "&gt;"; break;
            case '"': out += "&quot;"; break;
            case '\'': out += "&apos;"; break;
            default: out.push_back(c); break;
        }
    }
    return out;
}

std::string NativeWebRTCAnswerer::extractSdpLineValue(const std::string& sdp, const std::string& prefix) {
    const auto pos = sdp.find(prefix);
    if (pos == std::string::npos) return {};
    auto start = pos + prefix.size();
    auto end = sdp.find_first_of("\r\n", start);
    if (end == std::string::npos) end = sdp.size();
    return sdp.substr(start, end - start);
}

bool NativeWebRTCAnswerer::parseCandidateLine(const std::string& candidateLine, ParsedCandidate& out) {
    std::string line = candidateLine;
    if (line.rfind("a=", 0) == 0) line = line.substr(2);
    if (line.rfind("candidate:", 0) != 0) return false;

    std::istringstream iss(line.substr(10));
    iss >> out.foundation >> out.component >> out.protocol >> out.priority >> out.ip >> out.port;

    std::string token;
    while (iss >> token) {
        if (token == "typ") {
            iss >> out.type;
            break;
        }
    }

    return !out.ip.empty() && out.port > 0;
}

std::string NativeWebRTCAnswerer::attr(const std::string& tag, const std::string& name) {
    const std::regex re1(name + "='([^']*)'");
    const std::regex re2(name + "=\"([^\"]*)\"");
    std::smatch m;
    if (std::regex_search(tag, m, re1) && m.size() > 1) return m[1].str();
    if (std::regex_search(tag, m, re2) && m.size() > 1) return m[1].str();
    return {};
}

std::string NativeWebRTCAnswerer::firstTag(const std::string& xml, const std::string& tagName) {
    const std::regex re("<" + tagName + R"((?:\s|/|>)[^>]*>)");
    std::smatch m;
    if (std::regex_search(xml, m, re)) return m.str();
    return {};
}
