#include "JingleSession.h"
#include "Logger.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <exception>
#include <regex>
#include <sstream>
#include <string>
#include <unordered_set>
#include <vector>

const JingleContent* JingleSession::contentByName(const std::string& name) const {
    for (const auto& c : contents) {
        if (c.name == name) {
            return &c;
        }
    }

    return nullptr;
}

std::string xmlEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size());

    for (char c : s) {
        switch (c) {
            case '&':
                out += "&amp;";
                break;
            case '<':
                out += "&lt;";
                break;
            case '>':
                out += "&gt;";
                break;
            case '\'':
                out += "&apos;";
                break;
            case '"':
                out += "&quot;";
                break;
            default:
                out += c;
                break;
        }
    }

    return out;
}

std::string xmlUnescape(std::string s) {
    const auto repl = [&](const std::string& a, const std::string& b) {
        std::size_t pos = 0;

        while ((pos = s.find(a, pos)) != std::string::npos) {
            s.replace(pos, a.size(), b);
            pos += b.size();
        }
    };

    repl("&quot;", "\"");
    repl("&apos;", "'");
    repl("&lt;", "<");
    repl("&gt;", ">");
    repl("&amp;", "&");

    return s;
}

std::string attrValue(const std::string& tag, const std::string& attr) {
    if (tag.empty() || attr.empty()) {
        return {};
    }

    const std::regex re(attr + R"(\s*=\s*(['"])(.*?)\1)", std::regex::icase);
    std::smatch m;

    if (std::regex_search(tag, m, re) && m.size() > 2) {
        return xmlUnescape(m[2].str());
    }

    return {};
}

namespace {

std::string tagStartPattern(const std::string& tagName) {
    // (?=[\s>/]) prevents matching <source-info> when searching for <source>.
    return R"(<\s*)" + tagName + R"((?=[\s>/])[^>]*>)";
}

std::string toLower(std::string s) {
    std::transform(
        s.begin(),
        s.end(),
        s.begin(),
        [](unsigned char c) {
            return static_cast<char>(std::tolower(c));
        }
    );

    return s;
}

bool tryParseInt(const std::string& s, int& out) {
    if (s.empty()) {
        return false;
    }

    try {
        out = std::stoi(s);
        return true;
    } catch (...) {
        return false;
    }
}

bool tryParseUint32(const std::string& s, std::uint32_t& out) {
    if (s.empty()) {
        return false;
    }

    try {
        const auto value = std::stoull(s);

        if (value > 0xffffffffull) {
            return false;
        }

        out = static_cast<std::uint32_t>(value);
        return true;
    } catch (...) {
        return false;
    }
}

std::string elementText(const std::string& xml, const std::string& tagName) {
    const std::regex re(
        R"(<\s*)" + tagName + R"((?=[\s>/])[^>]*>([\s\S]*?)</\s*)" + tagName + R"(\s*>)",
        std::regex::icase
    );

    std::smatch m;

    if (std::regex_search(xml, m, re) && m.size() > 1) {
        return xmlUnescape(m[1].str());
    }

    return {};
}

std::vector<std::string> findElementBlocks(const std::string& xml, const std::string& tagName) {
    std::vector<std::string> blocks;

    const std::regex closedRe(
        R"(<\s*)" + tagName + R"((?=[\s>/])[^>]*>[\s\S]*?</\s*)" + tagName + R"(\s*>)",
        std::regex::icase
    );

    for (auto it = std::sregex_iterator(xml.begin(), xml.end(), closedRe);
         it != std::sregex_iterator();
         ++it) {
        blocks.push_back((*it)[0].str());
    }

    if (!blocks.empty()) {
        return blocks;
    }

    const std::regex selfClosingRe(
        R"(<\s*)" + tagName + R"((?=[\s>/])[^>]*/\s*>)",
        std::regex::icase
    );

    for (auto it = std::sregex_iterator(xml.begin(), xml.end(), selfClosingRe);
         it != std::sregex_iterator();
         ++it) {
        blocks.push_back((*it)[0].str());
    }

    return blocks;
}

std::vector<std::string> findSourceBlocks(const std::string& xml) {
    std::vector<std::string> blocks;

    const std::regex sourceRe(
        R"(<\s*source(?=[\s>/])[^>]*/\s*>|<\s*source(?=[\s>/])[^>]*>[\s\S]*?</\s*source\s*>)",
        std::regex::icase
    );

    for (auto it = std::sregex_iterator(xml.begin(), xml.end(), sourceRe);
         it != std::sregex_iterator();
         ++it) {
        blocks.push_back((*it)[0].str());
    }

    return blocks;
}

JingleCandidate parseCandidateTag(const std::string& tag) {
    JingleCandidate c;

    c.foundation = attrValue(tag, "foundation");
    c.component = attrValue(tag, "component");
    c.protocol = toLower(attrValue(tag, "protocol"));
    c.priority = attrValue(tag, "priority");
    c.ip = attrValue(tag, "ip");
    c.port = attrValue(tag, "port");
    c.type = attrValue(tag, "type");
    c.id = attrValue(tag, "id");

    if (c.component.empty()) {
        c.component = "1";
    }

    if (c.protocol.empty()) {
        c.protocol = "udp";
    }

    if (c.type.empty()) {
        c.type = "host";
    }

    return c;
}

void appendCandidateSdp(std::ostringstream& sdp, const JingleCandidate& c) {
    if (c.ip.empty() || c.port.empty()) {
        return;
    }

    sdp
        << "a=candidate:"
        << (c.foundation.empty() ? "1" : c.foundation)
        << " "
        << (c.component.empty() ? "1" : c.component)
        << " "
        << (c.protocol.empty() ? "udp" : c.protocol)
        << " "
        << (c.priority.empty() ? "1" : c.priority)
        << " "
        << c.ip
        << " "
        << c.port
        << " typ "
        << (c.type.empty() ? "host" : c.type)
        << "\r\n";
}

void appendRtpmap(std::ostringstream& sdp, const JingleCodec& codec) {
    if (codec.payloadType < 0 || codec.name.empty() || codec.clockRate <= 0) {
        return;
    }

    sdp
        << "a=rtpmap:"
        << codec.payloadType
        << " "
        << codec.name
        << "/"
        << codec.clockRate;

    if (codec.channels > 0) {
        sdp << "/" << codec.channels;
    }

    sdp << "\r\n";
}

bool isSupportedAudioCodec(const JingleCodec& codec) {
    return toLower(codec.name) == "opus";
}

bool isSupportedVideoCodec(const JingleCodec& codec) {
    // The current native RTP/decode pipeline is VP8-oriented.
    // Keep AV1/VP9/H264 out of negotiation for now.
    return toLower(codec.name) == "vp8";
}

std::vector<int> supportedPayloadTypesForContent(const JingleContent& c) {
    std::vector<int> pts;

    for (const auto& codec : c.codecs) {
        if (codec.payloadType < 0 || codec.name.empty()) {
            continue;
        }

        if (c.name == "audio" || c.media == "audio") {
            if (!isSupportedAudioCodec(codec)) {
                continue;
            }
        } else if (c.name == "video" || c.media == "video") {
            if (!isSupportedVideoCodec(codec)) {
                continue;
            }
        } else {
            continue;
        }

        pts.push_back(codec.payloadType);
    }

    return pts;
}

void appendSsrcLines(std::ostringstream& sdp, const JingleContent& c) {
    std::unordered_set<std::uint32_t> seen;

    for (const auto& src : c.sources) {
        if (src.ssrc == 0 || src.name.empty()) {
            continue;
        }

        if (!seen.insert(src.ssrc).second) {
            continue;
        }

        const std::string cname = src.name;
        const std::string msid = src.name;
        const std::string trackId = src.name + "-track";

        sdp << "a=ssrc:" << src.ssrc << " cname:" << cname << "\r\n";
        sdp << "a=ssrc:" << src.ssrc << " msid:" << msid << " " << trackId << "\r\n";
    }
}

void appendCommonIceDtlsSdp(std::ostringstream& sdp, const JingleContent& c) {
    if (!c.iceUfrag.empty()) {
        sdp << "a=ice-ufrag:" << c.iceUfrag << "\r\n";
    }

    if (!c.icePwd.empty()) {
        sdp << "a=ice-pwd:" << c.icePwd << "\r\n";
    }

    if (!c.fingerprint.empty()) {
        sdp
            << "a=fingerprint:"
            << (c.fingerprintHash.empty() ? "sha-256" : c.fingerprintHash)
            << " "
            << c.fingerprint
            << "\r\n";
    }

    sdp << "a=setup:actpass\r\n";
    sdp << "a=ice-options:trickle\r\n";
}

void appendCandidatesAndEnd(std::ostringstream& sdp, const JingleContent& c) {
    for (const auto& cand : c.candidates) {
        appendCandidateSdp(sdp, cand);
    }

    sdp << "a=end-of-candidates\r\n";
}

void appendMediaSectionSdp(std::ostringstream& sdp, const JingleContent& c) {
    const auto pts = supportedPayloadTypesForContent(c);

    if (pts.empty()) {
        Logger::warn("JingleSession: no supported payload types for content name=", c.name);
        return;
    }

    sdp << "m=" << c.name << " 9 UDP/TLS/RTP/SAVPF";

    for (int pt : pts) {
        sdp << " " << pt;
    }

    sdp << "\r\n";

    sdp << "c=IN IP4 0.0.0.0\r\n";
    sdp << "a=mid:" << c.name << "\r\n";

    // This synthetic SDP is fed to libdatachannel as the REMOTE offer.
    // Remote Jitsi/JVB should send media to us; our client receives only.
    sdp << "a=sendonly\r\n";

    sdp << "a=rtcp-mux\r\n";
    sdp << "a=rtcp-rsize\r\n";

    appendCommonIceDtlsSdp(sdp, c);

    if (c.name == "audio" || c.media == "audio") {
        sdp << "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n";
    } else if (c.name == "video" || c.media == "video") {
        sdp << "a=extmap:3 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time\r\n";
    }

    for (const auto& codec : c.codecs) {
        if (std::find(pts.begin(), pts.end(), codec.payloadType) == pts.end()) {
            continue;
        }

        appendRtpmap(sdp, codec);

        const std::string codecName = toLower(codec.name);

        if ((c.name == "audio" || c.media == "audio") && codecName == "opus") {
            sdp << "a=fmtp:" << codec.payloadType << " minptime=10;useinbandfec=1\r\n";
        }

        if (c.name == "video" || c.media == "video") {
            sdp << "a=rtcp-fb:" << codec.payloadType << " nack\r\n";
            sdp << "a=rtcp-fb:" << codec.payloadType << " nack pli\r\n";
            sdp << "a=rtcp-fb:" << codec.payloadType << " ccm fir\r\n";
        }
    }

    appendSsrcLines(sdp, c);
    appendCandidatesAndEnd(sdp, c);
}

void appendCodecAcceptXml(std::ostringstream& xml, const JingleContent& c) {
    bool wroteCodec = false;

    for (const auto& codec : c.codecs) {
        const std::string codecNameLower = toLower(codec.name);

        if ((c.name == "audio" || c.media == "audio") && codecNameLower != "opus") {
            continue;
        }

        if ((c.name == "video" || c.media == "video") && codecNameLower != "vp8") {
            continue;
        }

        xml
            << "<payload-type id='"
            << codec.payloadType
            << "' name='"
            << xmlEscape(codec.name)
            << "' clockrate='"
            << codec.clockRate
            << "'";

        if (codec.channels > 0) {
            xml << " channels='" << codec.channels << "'";
        }

        xml << ">";

        if (c.name == "audio" || c.media == "audio") {
            xml << "<parameter name='minptime' value='10'/>";
            xml << "<parameter name='useinbandfec' value='1'/>";
        }

        if (c.name == "video" || c.media == "video") {
            xml << "<rtcp-fb xmlns='urn:xmpp:jingle:apps:rtp:rtcp-fb:0' type='ccm' subtype='fir'/>";
            xml << "<rtcp-fb xmlns='urn:xmpp:jingle:apps:rtp:rtcp-fb:0' type='nack'/>";
            xml << "<rtcp-fb xmlns='urn:xmpp:jingle:apps:rtp:rtcp-fb:0' type='nack' subtype='pli'/>";
        }

        xml << "</payload-type>";

        wroteCodec = true;
        break;
    }

    if (!wroteCodec) {
        Logger::warn("JingleSession: no supported codec written in session-accept for content=", c.name);
    }
}

void appendMediaAcceptContentXml(
    std::ostringstream& xml,
    const JingleContent& c,
    const std::string& localIceUfrag,
    const std::string& localIcePwd,
    const std::string& localFingerprint
) {
    xml
        << "<content creator='initiator' name='"
        << xmlEscape(c.name)
        << "' senders='initiator'>";

    xml
        << "<description xmlns='urn:xmpp:jingle:apps:rtp:1' media='"
        << xmlEscape(c.media.empty() ? c.name : c.media)
        << "'>";

    appendCodecAcceptXml(xml, c);

    if (c.name == "audio" || c.media == "audio") {
        xml << "<rtp-hdrext xmlns='urn:xmpp:jingle:apps:rtp:rtp-hdrext:0' id='1' uri='urn:ietf:params:rtp-hdrext:ssrc-audio-level'/>";
    } else if (c.name == "video" || c.media == "video") {
        xml << "<rtp-hdrext xmlns='urn:xmpp:jingle:apps:rtp:rtp-hdrext:0' id='3' uri='http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time'/>";
    }

    xml << "<extmap-allow-mixed xmlns='urn:xmpp:jingle:apps:rtp:rtp-hdrext:0'/>";
    xml << "<rtcp-mux/>";
    xml << "</description>";

    xml
        << "<transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='"
        << xmlEscape(localIceUfrag)
        << "' pwd='"
        << xmlEscape(localIcePwd)
        << "'>";

    xml << "<rtcp-mux/>";

    xml
        << "<fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' required='true' setup='active'>"
        << xmlEscape(localFingerprint)
        << "</fingerprint>";

    xml << "</transport>";
    xml << "</content>";
}

} // namespace

std::string findFirstTag(const std::string& xml, const std::string& tagName) {
    const std::regex re(tagStartPattern(tagName), std::regex::icase);
    std::smatch m;

    if (std::regex_search(xml, m, re)) {
        return m[0].str();
    }

    return {};
}

std::vector<std::string> findTags(const std::string& xml, const std::string& tagName) {
    std::vector<std::string> tags;

    const std::regex re(tagStartPattern(tagName), std::regex::icase);

    for (auto it = std::sregex_iterator(xml.begin(), xml.end(), re);
         it != std::sregex_iterator();
         ++it) {
        tags.push_back((*it)[0].str());
    }

    return tags;
}

bool parseJingleSessionInitiate(const std::string& xml, JingleSession& out) {
    if (xml.find("session-initiate") == std::string::npos) {
        return false;
    }

    const std::string iqTag = findFirstTag(xml, "iq");
    const std::string jingleTag = findFirstTag(xml, "jingle");

    if (jingleTag.empty()) {
        return false;
    }

    out = JingleSession{};

    out.iqId = attrValue(iqTag, "id");
    out.from = attrValue(iqTag, "from");
    out.sid = attrValue(jingleTag, "sid");
    out.initiator = attrValue(jingleTag, "initiator");

    const std::string bridgeTag = findFirstTag(xml, "bridge-session");

    out.bridgeSessionId = attrValue(bridgeTag, "id");
    out.region = attrValue(bridgeTag, "region");

    for (const auto& block : findElementBlocks(xml, "content")) {
        JingleContent content;

        const std::string contentTag = findFirstTag(block, "content");

        content.name = attrValue(contentTag, "name");
        content.senders = attrValue(contentTag, "senders");

        if (content.senders.empty()) {
            content.senders = "both";
        }

        const std::string descTag = findFirstTag(block, "description");

        content.media = attrValue(descTag, "media");

        if (content.media.empty()) {
            content.media = content.name;
        }

        const std::string transportTag = findFirstTag(block, "transport");

        content.iceUfrag = attrValue(transportTag, "ufrag");
        content.icePwd = attrValue(transportTag, "pwd");

        const std::string fingerprintTag = findFirstTag(block, "fingerprint");

        content.fingerprintHash = attrValue(fingerprintTag, "hash");
        content.setup = attrValue(fingerprintTag, "setup");
        content.fingerprint = elementText(block, "fingerprint");

        if (content.fingerprintHash.empty()) {
            content.fingerprintHash = "sha-256";
        }

        if (content.setup.empty()) {
            content.setup = "actpass";
        }

        for (const auto& pt : findTags(block, "payload-type")) {
            JingleCodec codec;

            const std::string id = attrValue(pt, "id");
            const std::string clock = attrValue(pt, "clockrate");
            const std::string channels = attrValue(pt, "channels");

            tryParseInt(id, codec.payloadType);
            tryParseInt(clock, codec.clockRate);
            tryParseInt(channels, codec.channels);

            codec.name = attrValue(pt, "name");

            content.codecs.push_back(codec);
        }

        for (const auto& candTag : findTags(block, "candidate")) {
            content.candidates.push_back(parseCandidateTag(candTag));
        }

        for (const auto& sourceBlock : findSourceBlocks(block)) {
            const std::string sourceTag = findFirstTag(sourceBlock, "source");
            const std::string ssrcText = attrValue(sourceTag, "ssrc");

            JingleSource src;

            if (!tryParseUint32(ssrcText, src.ssrc)) {
                continue;
            }

            src.name = attrValue(sourceTag, "name");
            src.videoType = attrValue(sourceTag, "videoType");
            src.owner = attrValue(sourceTag, "owner");

            if (src.owner.empty()) {
                const std::string ssrcInfoTag = findFirstTag(sourceBlock, "ssrc-info");
                src.owner = attrValue(ssrcInfoTag, "owner");
            }

            content.sources.push_back(src);
        }

        if (!content.name.empty()) {
            out.contents.push_back(content);
        }
    }

    return !out.sid.empty() && !out.contents.empty();
}

bool parseTransportInfoCandidate(const std::string& xml, LocalIceCandidate& out) {
    if (xml.find("transport-info") == std::string::npos) {
        return false;
    }

    const std::string contentTag = findFirstTag(xml, "content");
    const std::string candTag = findFirstTag(xml, "candidate");

    if (candTag.empty()) {
        return false;
    }

    out = LocalIceCandidate{};

    out.mid = attrValue(contentTag, "name");
    out.foundation = attrValue(candTag, "foundation");
    out.component = attrValue(candTag, "component");
    out.protocol = toLower(attrValue(candTag, "protocol"));
    out.priority = attrValue(candTag, "priority");
    out.ip = attrValue(candTag, "ip");
    out.port = attrValue(candTag, "port");
    out.type = attrValue(candTag, "type");

    if (out.component.empty()) {
        out.component = "1";
    }

    if (out.protocol.empty()) {
        out.protocol = "udp";
    }

    if (out.type.empty()) {
        out.type = "host";
    }

    std::ostringstream line;

    line
        << "candidate:"
        << (out.foundation.empty() ? "1" : out.foundation)
        << " "
        << out.component
        << " "
        << out.protocol
        << " "
        << (out.priority.empty() ? "1" : out.priority)
        << " "
        << out.ip
        << " "
        << out.port
        << " typ "
        << out.type;

    out.candidateLine = line.str();

    return !out.ip.empty() && !out.port.empty();
}

bool parseLocalCandidateLine(const std::string& candidate, LocalIceCandidate& out) {
    std::string c = candidate;

    if (c.rfind("a=", 0) == 0) {
        c = c.substr(2);
    }

    if (c.rfind("candidate:", 0) != 0) {
        return false;
    }

    std::istringstream ss(c.substr(10));

    out = LocalIceCandidate{};
    out.candidateLine = c;

    ss
        >> out.foundation
        >> out.component
        >> out.protocol
        >> out.priority
        >> out.ip
        >> out.port;

    std::string word;

    while (ss >> word) {
        if (word == "typ") {
            ss >> out.type;
        }
    }

    out.protocol = toLower(out.protocol);

    if (out.component.empty()) {
        out.component = "1";
    }

    if (out.protocol.empty()) {
        out.protocol = "udp";
    }

    if (out.type.empty()) {
        out.type = "host";
    }

    return !out.ip.empty() && !out.port.empty();
}

std::string buildSdpOfferFromJingle(const JingleSession& session) {
    std::ostringstream sdp;

    const JingleContent* audio = session.audio();
    const JingleContent* video = session.video();

    const bool hasAudio = audio && !supportedPayloadTypesForContent(*audio).empty();
    const bool hasVideo = video && !supportedPayloadTypesForContent(*video).empty();

    sdp << "v=0\r\n";
    sdp << "o=- 0 0 IN IP4 127.0.0.1\r\n";
    sdp << "s=-\r\n";
    sdp << "t=0 0\r\n";

    sdp << "a=group:BUNDLE";

    if (hasAudio) {
        sdp << " audio";
    }

    if (hasVideo) {
        sdp << " video";
    }

    sdp << "\r\n";
    sdp << "a=msid-semantic: WMS *\r\n";

    if (hasAudio) {
        appendMediaSectionSdp(sdp, *audio);
    }

    if (hasVideo) {
        appendMediaSectionSdp(sdp, *video);
    }

    const std::string result = sdp.str();

    Logger::info("JingleSession: synthetic SDP offer passed to libdatachannel:\n", result);

    return result;
}

std::string buildJingleSessionAccept(
    const JingleSession& session,
    const std::string& responderJid,
    const std::string& id,
    const std::string& localIceUfrag,
    const std::string& localIcePwd,
    const std::string& localFingerprint
) {
    std::ostringstream xml;

    xml
        << "<iq xmlns='jabber:client' type='set' to='"
        << xmlEscape(session.from)
        << "' id='"
        << xmlEscape(id)
        << "'>";

    xml
        << "<jingle xmlns='urn:xmpp:jingle:1' action='session-accept' initiator='"
        << xmlEscape(session.initiator)
        << "' responder='"
        << xmlEscape(responderJid)
        << "' sid='"
        << xmlEscape(session.sid)
        << "'>";

    xml << "<group xmlns='urn:xmpp:jingle:apps:grouping:0' semantics='BUNDLE'>";

    if (session.audio()) {
        xml << "<content name='audio'/>";
    }

    if (session.video()) {
        xml << "<content name='video'/>";
    }

    xml << "</group>";

    if (const auto* audio = session.audio()) {
        appendMediaAcceptContentXml(
            xml,
            *audio,
            localIceUfrag,
            localIcePwd,
            localFingerprint
        );
    }

    if (const auto* video = session.video()) {
        appendMediaAcceptContentXml(
            xml,
            *video,
            localIceUfrag,
            localIcePwd,
            localFingerprint
        );
    }

    xml << "</jingle>";
    xml << "</iq>";

    const std::string result = xml.str();

    Logger::info("JingleSession: session-accept XML:\n", result);

    return result;
}

std::string buildJingleTransportInfo(
    const std::string& to,
    const std::string& id,
    const std::string& sid,
    const std::string& localIceUfrag,
    const std::string& localIcePwd,
    const LocalIceCandidate& cand
) {
    std::ostringstream xml;

    const std::string mid = cand.mid.empty() ? "audio" : cand.mid;

    xml
        << "<iq xmlns='jabber:client' type='set' to='"
        << xmlEscape(to)
        << "' id='"
        << xmlEscape(id)
        << "'>";

    xml
        << "<jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='"
        << xmlEscape(sid)
        << "'>";

    xml
        << "<content creator='initiator' name='"
        << xmlEscape(mid)
        << "'>";

    xml
        << "<transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='"
        << xmlEscape(localIceUfrag)
        << "' pwd='"
        << xmlEscape(localIcePwd)
        << "'>";

    if (mid == "audio" || mid == "video") {
        xml << "<rtcp-mux/>";
    }

    xml
        << "<candidate component='"
        << xmlEscape(cand.component.empty() ? "1" : cand.component)
        << "' foundation='"
        << xmlEscape(cand.foundation.empty() ? "1" : cand.foundation)
        << "' generation='0' id='local_"
        << xmlEscape(cand.component.empty() ? "1" : cand.component)
        << "_"
        << xmlEscape(cand.port)
        << "' ip='"
        << xmlEscape(cand.ip)
        << "' network='0' port='"
        << xmlEscape(cand.port)
        << "' priority='"
        << xmlEscape(cand.priority.empty() ? "1" : cand.priority)
        << "' protocol='"
        << xmlEscape(cand.protocol.empty() ? "udp" : cand.protocol)
        << "' type='"
        << xmlEscape(cand.type.empty() ? "host" : cand.type)
        << "'/>";

    xml << "</transport>";
    xml << "</content>";
    xml << "</jingle>";
    xml << "</iq>";

    return xml.str();
}