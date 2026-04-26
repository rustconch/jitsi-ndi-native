#include "JingleSession.h"
#include "Logger.h"

#include <algorithm>
#include <cctype>
#include <regex>
#include <sstream>

namespace {
std::string attr(const std::string& tag, const std::string& name) {
    const std::regex re1(name + "='([^']*)'");
    const std::regex re2(name + "=\"([^\"]*)\"");
    std::smatch m;
    if (std::regex_search(tag, m, re1) && m.size() > 1) return m[1].str();
    if (std::regex_search(tag, m, re2) && m.size() > 1) return m[1].str();
    return {};
}

std::string firstTag(const std::string& xml, const std::string& tagName) {
    const std::regex re("<" + tagName + R"((?:\s|/|>)[^>]*>)");
    std::smatch m;
    if (std::regex_search(xml, m, re)) return m.str();
    return {};
}

std::vector<std::string> allTags(const std::string& xml, const std::string& tagName) {
    std::vector<std::string> tags;
    const std::regex re("<" + tagName + R"((?:\s|/|>)[^>]*>)");
    auto begin = std::sregex_iterator(xml.begin(), xml.end(), re);
    auto end = std::sregex_iterator();
    for (auto it = begin; it != end; ++it) tags.push_back(it->str());
    return tags;
}

std::string blockForTag(const std::string& xml, const std::string& tagName, const std::string& tagStart) {
    const auto start = xml.find(tagStart);
    if (start == std::string::npos) return {};
    const auto openEnd = xml.find('>', start);
    if (openEnd == std::string::npos) return {};

    if (tagStart.size() >= 2 && tagStart[tagStart.size() - 2] == '/') {
        return xml.substr(start, openEnd - start + 1);
    }

    const std::string close = "</" + tagName + ">";
    const auto end = xml.find(close, openEnd + 1);
    if (end == std::string::npos) return xml.substr(start, openEnd - start + 1);
    return xml.substr(start, end + close.size() - start);
}

int toInt(const std::string& s, int def = 0) {
    try { return s.empty() ? def : std::stoi(s); } catch (...) { return def; }
}

std::uint32_t toU32(const std::string& s, std::uint32_t def = 0) {
    try { return s.empty() ? def : static_cast<std::uint32_t>(std::stoul(s)); } catch (...) { return def; }
}

std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

std::string mediaDirection(const JingleContent&) {
    return "sendrecv";
}

void appendCandidateSdp(std::ostringstream& sdp, const JingleCandidate& c) {
    if (c.ip.empty() || c.port <= 0) return;
    sdp << "a=candidate:" << (c.foundation.empty() ? "1" : c.foundation)
        << " " << (c.component > 0 ? c.component : 1)
        << " " << lower(c.protocol.empty() ? "udp" : c.protocol)
        << " " << c.priority
        << " " << c.ip
        << " " << c.port
        << " typ " << (c.type.empty() ? "host" : c.type);
    if (!c.relAddr.empty() && c.relPort > 0) {
        sdp << " raddr " << c.relAddr << " rport " << c.relPort;
    }
    sdp << "\r\n";
}
}

const JingleContent* JingleSessionInitiate::findContent(const std::string& name) const {
    for (const auto& c : contents) {
        if (c.name == name || c.media == name) return &c;
    }
    return nullptr;
}

std::string JingleSessionInitiate::toSdpOffer() const {
    const JingleContent* audio = findContent("audio");
    const JingleContent* video = findContent("video");

    std::ostringstream sdp;
    sdp << "v=0\r\n";
    sdp << "o=- 0 0 IN IP4 127.0.0.1\r\n";
    sdp << "s=-\r\n";
    sdp << "t=0 0\r\n";
    sdp << "a=group:BUNDLE";
    if (audio) sdp << " audio";
    if (video) sdp << " video";
    sdp << "\r\n";
    sdp << "a=msid-semantic: WMS *\r\n";

    auto appendContent = [&](const JingleContent& c) {
        std::vector<int> pts;
        for (const auto& p : c.payloads) {
            if (p.id >= 0) pts.push_back(p.id);
        }
        if (pts.empty()) {
            if (c.media == "audio") pts.push_back(111);
            if (c.media == "video") pts.push_back(100);
        }

        sdp << "m=" << c.media << " 9 UDP/TLS/RTP/SAVPF";
        for (int pt : pts) sdp << " " << pt;
        sdp << "\r\n";
        sdp << "c=IN IP4 0.0.0.0\r\n";
        sdp << "a=mid:" << c.name << "\r\n";
        sdp << "a=" << mediaDirection(c) << "\r\n";
        sdp << "a=rtcp-mux\r\n";
        if (!c.iceUfrag.empty()) sdp << "a=ice-ufrag:" << c.iceUfrag << "\r\n";
        if (!c.icePwd.empty()) sdp << "a=ice-pwd:" << c.icePwd << "\r\n";
        if (!c.fingerprint.empty()) {
            sdp << "a=fingerprint:" << (c.fingerprintHash.empty() ? "sha-256" : c.fingerprintHash)
                << " " << c.fingerprint << "\r\n";
            sdp << "a=setup:" << (c.dtlsSetup.empty() ? "actpass" : c.dtlsSetup) << "\r\n";
        }

        for (const auto& p : c.payloads) {
            if (p.id < 0 || p.name.empty()) continue;
            sdp << "a=rtpmap:" << p.id << " " << p.name << "/" << (p.clockrate > 0 ? p.clockrate : 90000);
            if (p.channels > 0) sdp << "/" << p.channels;
            sdp << "\r\n";
        }

        for (const auto& cand : c.candidates) appendCandidateSdp(sdp, cand);
        sdp << "a=end-of-candidates\r\n";
    };

    if (audio) appendContent(*audio);
    if (video) appendContent(*video);

    return sdp.str();
}

std::string JingleSessionInitiate::summary() const {
    std::ostringstream out;
    out << "Jingle sid=" << sid << " iq=" << iqId << " from=" << from
        << " bridge=" << bridgeSessionId << " region=" << region
        << " contents=" << contents.size() << "\n";

    for (const auto& c : contents) {
        out << "  " << c.media << ": codecs=";
        for (std::size_t i = 0; i < c.payloads.size(); ++i) {
            if (i) out << ",";
            out << c.payloads[i].name << "/" << c.payloads[i].id;
        }
        out << " ice=" << c.iceUfrag << ":*** candidates=" << c.candidates.size()
            << " sources=" << c.sources.size() << "\n";
        for (const auto& src : c.sources) {
            out << "    ssrc=" << src.ssrc << " owner=" << src.owner << " name=" << src.name << "\n";
        }
    }

    return out.str();
}

bool JingleSessionParser::isSessionInitiate(const std::string& xml) {
    return xml.find("session-initiate") != std::string::npos && xml.find("<jingle") != std::string::npos;
}

JingleSessionInitiate JingleSessionParser::parseSessionInitiate(const std::string& xml) {
    JingleSessionInitiate s;

    const std::string iq = firstTag(xml, "iq");
    const std::string jingle = firstTag(xml, "jingle");
    if (iq.empty() || jingle.empty()) {
        Logger::warn("Jingle parse failed: missing iq or jingle tag");
        return s;
    }

    s.iqId = attr(iq, "id");
    s.from = attr(iq, "from");
    s.sid = attr(jingle, "sid");
    s.initiator = attr(jingle, "initiator");

    const std::string bridge = firstTag(xml, "bridge-session");
    s.bridgeSessionId = attr(bridge, "id");
    s.region = attr(bridge, "region");

    for (const auto& contentTag : allTags(xml, "content")) {
        const std::string name = attr(contentTag, "name");
        if (name.empty()) continue;

        const std::string contentXml = blockForTag(xml, "content", contentTag);
        if (contentXml.empty()) continue;

        JingleContent c;
        c.name = name;

        const std::string desc = firstTag(contentXml, "description");
        c.media = attr(desc, "media");
        if (c.media.empty()) c.media = name;

        const std::string transport = firstTag(contentXml, "transport");
        c.iceUfrag = attr(transport, "ufrag");
        c.icePwd = attr(transport, "pwd");

        const std::string fp = firstTag(contentXml, "fingerprint");
        c.fingerprintHash = attr(fp, "hash");
        c.dtlsSetup = attr(fp, "setup");
        const auto fpTextStart = contentXml.find(fp);
        if (!fp.empty() && fpTextStart != std::string::npos) {
            const auto start = contentXml.find('>', fpTextStart);
            const auto end = contentXml.find("</fingerprint>", start == std::string::npos ? fpTextStart : start);
            if (start != std::string::npos && end != std::string::npos && end > start) {
                c.fingerprint = contentXml.substr(start + 1, end - start - 1);
            }
        }

        for (const auto& ptTag : allTags(contentXml, "payload-type")) {
            JinglePayloadType pt;
            pt.id = toInt(attr(ptTag, "id"), -1);
            pt.name = attr(ptTag, "name");
            pt.clockrate = toInt(attr(ptTag, "clockrate"), c.media == "audio" ? 48000 : 90000);
            pt.channels = toInt(attr(ptTag, "channels"), 0);
            if (pt.id >= 0 && !pt.name.empty()) c.payloads.push_back(pt);
        }

        for (const auto& candTag : allTags(contentXml, "candidate")) {
            JingleCandidate cand;
            cand.foundation = attr(candTag, "foundation");
            cand.component = toInt(attr(candTag, "component"), 1);
            cand.protocol = attr(candTag, "protocol");
            cand.priority = toU32(attr(candTag, "priority"), 0);
            cand.ip = attr(candTag, "ip");
            cand.port = toInt(attr(candTag, "port"), 0);
            cand.type = attr(candTag, "type");
            cand.relAddr = attr(candTag, "rel-addr");
            cand.relPort = toInt(attr(candTag, "rel-port"), 0);
            if (!cand.ip.empty() && cand.port > 0) c.candidates.push_back(cand);
        }

        for (const auto& srcTag : allTags(contentXml, "source")) {
            JingleSource src;
            src.ssrc = toU32(attr(srcTag, "ssrc"), 0);
            src.name = attr(srcTag, "name");
            src.videoType = attr(srcTag, "videoType");

            const std::string sourceXml = blockForTag(contentXml, "source", srcTag);
            const std::string ownerTag = firstTag(sourceXml, "ssrc-info");
            src.owner = attr(ownerTag, "owner");

            if (src.ssrc != 0) c.sources.push_back(src);
        }

        s.contents.push_back(std::move(c));
    }

    s.valid = !s.sid.empty() && !s.iqId.empty() && !s.contents.empty();
    if (!s.valid) {
        Logger::warn("Jingle parse produced invalid session: sid=", s.sid, " iq=", s.iqId, " contents=", s.contents.size());
    }

    return s;
}
