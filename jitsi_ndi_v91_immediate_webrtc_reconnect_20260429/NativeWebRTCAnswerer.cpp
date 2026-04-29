#include "NativeWebRTCAnswerer.h"
#include "Logger.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <condition_variable>
#include <deque>
#include <cstdint>
#include <cstring>
#include <exception>
#include <iomanip>
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

bool parseBasicRtpHeader(
    const std::uint8_t* data,
    std::size_t size,
    std::uint16_t& sequence,
    std::uint32_t& timestamp,
    std::uint32_t& ssrc
) {
    sequence = 0;
    timestamp = 0;
    ssrc = 0;

    if (!data || size < 12) {
        return false;
    }

    const std::uint8_t version = static_cast<std::uint8_t>(data[0] >> 6);
    if (version != 2) {
        return false;
    }

    sequence = static_cast<std::uint16_t>((static_cast<std::uint16_t>(data[2]) << 8) | data[3]);
    timestamp = (static_cast<std::uint32_t>(data[4]) << 24)
        | (static_cast<std::uint32_t>(data[5]) << 16)
        | (static_cast<std::uint32_t>(data[6]) << 8)
        | static_cast<std::uint32_t>(data[7]);
    ssrc = (static_cast<std::uint32_t>(data[8]) << 24)
        | (static_cast<std::uint32_t>(data[9]) << 16)
        | (static_cast<std::uint32_t>(data[10]) << 8)
        | static_cast<std::uint32_t>(data[11]);

    return true;
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

std::string xmlUnescapeLocal(std::string value) {
    const std::pair<const char*, const char*> replacements[] = {
        {"&quot;", "\""},
        {"&apos;", "'"},
        {"&lt;", "<"},
        {"&gt;", ">"},
        {"&amp;", "&"}
    };

    for (const auto& repl : replacements) {
        std::size_t pos = 0;
        while ((pos = value.find(repl.first, pos)) != std::string::npos) {
            value.replace(pos, std::strlen(repl.first), repl.second);
            pos += std::strlen(repl.second);
        }
    }

    return value;
}

bool looksLikeSourceInfoNameForMedia(const std::string& name, const std::string& media) {
    if (name.empty() || startsWith(name, "jvb")) {
        return false;
    }

    std::string lower = name;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });

    if (lower == "muted" || lower == "videotype" || lower == "owner" || lower == "msid") {
        return false;
    }

    if (media == "audio") {
        return name.find("-a") != std::string::npos;
    }

    if (media == "video") {
        return name.find("-v") != std::string::npos
            || name.find("-desktop") != std::string::npos
            || name.find("-screen") != std::string::npos;
    }

    return false;
}

std::vector<std::string> extractSourceInfoSourceNamesByMedia(const std::string& xml, const std::string& media) {
    std::vector<std::string> sources;
    std::set<std::string> seen;

    const std::regex sourceInfoRe(R"(<SourceInfo(?:\s[^>]*)?>([\s\S]*?)</SourceInfo>)", std::regex::icase);
    for (auto blockIt = std::sregex_iterator(xml.begin(), xml.end(), sourceInfoRe);
         blockIt != std::sregex_iterator();
         ++blockIt) {
        if ((*blockIt).size() <= 1) {
            continue;
        }

        const std::string sourceInfo = xmlUnescapeLocal((*blockIt)[1].str());
        const std::regex keyRe(R"KEY("([^"]+)"\s*:)KEY");

        for (auto keyIt = std::sregex_iterator(sourceInfo.begin(), sourceInfo.end(), keyRe);
             keyIt != std::sregex_iterator();
             ++keyIt) {
            if ((*keyIt).size() <= 1) {
                continue;
            }

            const std::string name = (*keyIt)[1].str();
            if (!looksLikeSourceInfoNameForMedia(name, media)) {
                continue;
            }

            if (seen.insert(name).second) {
                sources.push_back(name);
            }
        }
    }

    return sources;
}

std::vector<std::string> extractSourceInfoSourceNamesByMuteState(
    const std::string& xml,
    const std::string& media,
    bool wantMuted
) {
    std::vector<std::string> sources;
    std::set<std::string> seen;

    const std::regex sourceInfoRe(R"(<SourceInfo(?:\s[^>]*)?>([\s\S]*?)</SourceInfo>)", std::regex::icase);
    for (auto blockIt = std::sregex_iterator(xml.begin(), xml.end(), sourceInfoRe);
         blockIt != std::sregex_iterator();
         ++blockIt) {
        if ((*blockIt).size() <= 1) {
            continue;
        }

        const std::string sourceInfo = xmlUnescapeLocal((*blockIt)[1].str());
        const std::regex entryRe(R"KEY("([^"]+)"\s*:\s*\{([^{}]*)\})KEY", std::regex::icase);

        for (auto entryIt = std::sregex_iterator(sourceInfo.begin(), sourceInfo.end(), entryRe);
             entryIt != std::sregex_iterator();
             ++entryIt) {
            if ((*entryIt).size() <= 2) {
                continue;
            }

            const std::string name = (*entryIt)[1].str();
            if (!looksLikeSourceInfoNameForMedia(name, media)) {
                continue;
            }

            std::string body = (*entryIt)[2].str();
            body.erase(std::remove_if(body.begin(), body.end(), [](unsigned char ch) {
                return std::isspace(ch) != 0;
            }), body.end());

            const bool mutedTrue = body.find("\"muted\":true") != std::string::npos;
            const bool mutedFalse = body.find("\"muted\":false") != std::string::npos;

            if (wantMuted && !mutedTrue) {
                continue;
            }
            if (!wantMuted && mutedTrue) {
                continue;
            }
            if (!wantMuted && !mutedFalse && body.find("\"muted\":") != std::string::npos) {
                continue;
            }

            if (seen.insert(name).second) {
                sources.push_back(name);
            }
        }
    }

    return sources;
}

std::vector<std::string> removeSourceNames(
    const std::vector<std::string>& sourceNames,
    const std::vector<std::string>& namesToRemove
) {
    if (namesToRemove.empty()) {
        return sourceNames;
    }

    std::vector<std::string> out;
    for (const auto& name : sourceNames) {
        if (std::find(namesToRemove.begin(), namesToRemove.end(), name) == namesToRemove.end()) {
            out.push_back(name);
        }
    }
    return out;
}

bool isLikelyDesktopVideoSource(const std::string& name) {
    std::string lower = name;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });

    return lower.find("-v1") != std::string::npos
        || lower.find("desktop") != std::string::npos
        || lower.find("screen") != std::string::npos;
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

std::vector<std::string> extractAudioSourceNamesFromSdp(const std::string& sdp) {
    std::vector<std::string> sources;
    std::set<std::string> seen;

    std::istringstream input(sdp);
    std::string line;

    bool inAudio = false;

    while (std::getline(input, line)) {
        line = trimTrailingCr(line);

        if (startsWith(line, "m=")) {
            inAudio = startsWith(line, "m=audio ");
            continue;
        }

        if (!inAudio) {
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

        // jvb-a0 is the bridge/mixed placeholder. Subscribing to it together with
        // real endpoint audio can create audible doubling/overlap in NDI/vMix.
        if (startsWith(name, "jvb")) {
            continue;
        }

        if (name.find("-a") == std::string::npos) {
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



std::string xmlAttrLocal(const std::string& tag, const std::string& name) {
    const std::regex re(name + R"(\s*=\s*(['"])(.*?)\1)", std::regex::icase);
    std::smatch m;
    if (std::regex_search(tag, m, re) && m.size() > 2) {
        return xmlUnescapeLocal(m[2].str());
    }
    return {};
}

std::string firstXmlTagLocal(const std::string& xml, const std::string& name) {
    const std::regex re("<" + name + R"((?:\s|>|/)[\s\S]*?>)", std::regex::icase);
    std::smatch m;
    if (std::regex_search(xml, m, re)) {
        return m[0].str();
    }
    return {};
}

std::vector<std::string> xmlContentBlocksLocal(const std::string& xml) {
    std::vector<std::string> out;
    const std::regex re(R"(<content(?:\s|>)[\s\S]*?</content>)", std::regex::icase);
    for (auto it = std::sregex_iterator(xml.begin(), xml.end(), re); it != std::sregex_iterator(); ++it) {
        out.push_back((*it)[0].str());
    }
    return out;
}

std::vector<std::string> xmlSourceBlocksLocal(const std::string& xml) {
    std::vector<std::string> out;
    const std::regex blockRe(R"(<source(?:\s|>)[\s\S]*?</source>)", std::regex::icase);
    for (auto it = std::sregex_iterator(xml.begin(), xml.end(), blockRe); it != std::sregex_iterator(); ++it) {
        out.push_back((*it)[0].str());
    }
    const std::regex selfRe(R"(<source(?:\s|>)[\s\S]*?/>)", std::regex::icase);
    for (auto it = std::sregex_iterator(xml.begin(), xml.end(), selfRe); it != std::sregex_iterator(); ++it) {
        out.push_back((*it)[0].str());
    }
    return out;
}

std::vector<std::string> extractJingleSourceNamesByMedia(const std::string& xml, const std::string& wantedMedia) {
    std::vector<std::string> values;
    std::set<std::string> seen;

    for (const auto& content : xmlContentBlocksLocal(xml)) {
        const std::string contentTag = firstXmlTagLocal(content, "content");
        const std::string descriptionTag = firstXmlTagLocal(content, "description");

        std::string media = xmlAttrLocal(contentTag, "name");
        if (media.empty()) {
            media = xmlAttrLocal(descriptionTag, "media");
        }

        if (media != wantedMedia) {
            continue;
        }

        for (const auto& sourceBlock : xmlSourceBlocksLocal(content)) {
            const std::string sourceTag = firstXmlTagLocal(sourceBlock, "source");
            const std::string name = xmlAttrLocal(sourceTag, "name");
            if (!name.empty() && seen.insert(name).second) {
                values.push_back(name);
            }
        }
    }

    return values;
}


struct RemoteSdpSourceUpdate {
    std::string media;
    std::uint32_t ssrc = 0;
    std::string name;
    std::string owner;
};

std::uint32_t parseU32Local(const std::string& value) {
    try {
        return static_cast<std::uint32_t>(std::stoul(value));
    } catch (...) {
        return 0;
    }
}

std::vector<RemoteSdpSourceUpdate> extractRemoteSdpSourcesFromJingleXml(const std::string& xml) {
    std::vector<RemoteSdpSourceUpdate> out;
    std::set<std::uint32_t> seen;

    for (const auto& content : xmlContentBlocksLocal(xml)) {
        const std::string contentTag = firstXmlTagLocal(content, "content");
        const std::string descriptionTag = firstXmlTagLocal(content, "description");

        std::string media = xmlAttrLocal(contentTag, "name");
        if (media.empty()) {
            media = xmlAttrLocal(descriptionTag, "media");
        }

        if (media != "audio" && media != "video") {
            continue;
        }

        for (const auto& sourceBlock : xmlSourceBlocksLocal(content)) {
            const std::string sourceTag = firstXmlTagLocal(sourceBlock, "source");
            RemoteSdpSourceUpdate src;
            src.media = media;
            src.ssrc = parseU32Local(xmlAttrLocal(sourceTag, "ssrc"));
            src.name = xmlAttrLocal(sourceTag, "name");
            src.owner = xmlAttrLocal(sourceTag, "owner");

            if (src.owner.empty()) {
                const std::string ssrcInfoTag = firstXmlTagLocal(sourceBlock, "ssrc-info");
                src.owner = xmlAttrLocal(ssrcInfoTag, "owner");
            }

            // Ignore <source ssrc='...'> entries inside <ssrc-group>; they have no
            // name/owner and are already represented by the real source entries.
            if (src.ssrc == 0 || (src.name.empty() && src.owner.empty())) {
                continue;
            }

            if (startsWith(src.name, "jvb") || startsWith(src.owner, "jvb")) {
                continue;
            }

            if (seen.insert(src.ssrc).second) {
                out.push_back(std::move(src));
            }
        }
    }

    return out;
}

bool sdpHasSsrc(const std::string& sdp, std::uint32_t ssrc) {
    const std::string needle = "a=ssrc:" + std::to_string(ssrc) + " ";
    return sdp.find(needle) != std::string::npos;
}

std::string makeRemoteSdpSsrcLines(const RemoteSdpSourceUpdate& src) {
    const std::string cname = src.name.empty() ? std::to_string(src.ssrc) : src.name;
    const std::string msid = src.name.empty() ? cname : src.name;
    const std::string trackId = msid + "-track";

    std::ostringstream out;
    out << "a=ssrc:" << src.ssrc << " cname:" << cname << "\r\n";
    out << "a=ssrc:" << src.ssrc << " msid:" << msid << " " << trackId << "\r\n";
    return out.str();
}

bool appendRemoteSdpLinesToMediaSection(std::string& sdp, const std::string& media, const std::string& lines) {
    if (lines.empty()) {
        return false;
    }

    const std::string midLine = "a=mid:" + media + "\r\n";
    const std::size_t midPos = sdp.find(midLine);
    if (midPos == std::string::npos) {
        return false;
    }

    std::size_t sectionEnd = sdp.find("\r\nm=", midPos + midLine.size());
    if (sectionEnd == std::string::npos) {
        sectionEnd = sdp.size();
    } else {
        sectionEnd += 2; // keep insertion before the next m= line, after CRLF
    }

    std::size_t insertPos = std::string::npos;
    const std::string endCandidates = "a=end-of-candidates\r\n";
    const std::size_t endCandidatesPos = sdp.find(endCandidates, midPos);
    if (endCandidatesPos != std::string::npos && endCandidatesPos < sectionEnd) {
        insertPos = endCandidatesPos;
    } else {
        insertPos = sectionEnd;
    }

    sdp.insert(insertPos, lines);
    return true;
}

bool appendRemoteSdpSourcesFromJingleXml(std::string& sdp, const std::string& xml, std::size_t& addedCount) {
    addedCount = 0;

    const auto sources = extractRemoteSdpSourcesFromJingleXml(xml);
    if (sources.empty()) {
        return false;
    }

    std::string audioLines;
    std::string videoLines;

    for (const auto& src : sources) {
        if (sdpHasSsrc(sdp, src.ssrc)) {
            continue;
        }

        RtpSourceRegistry::setSsrcOwner(src.ssrc, src.owner, src.name);

        if (src.media == "audio") {
            audioLines += makeRemoteSdpSsrcLines(src);
            ++addedCount;
        } else if (src.media == "video") {
            videoLines += makeRemoteSdpSsrcLines(src);
            ++addedCount;
        }
    }

    bool changed = false;
    if (!audioLines.empty()) {
        changed = appendRemoteSdpLinesToMediaSection(sdp, "audio", audioLines) || changed;
    }
    if (!videoLines.empty()) {
        changed = appendRemoteSdpLinesToMediaSection(sdp, "video", videoLines) || changed;
    }

    return changed;
}

std::vector<std::string> mergeUniqueStrings(std::vector<std::string> base, const std::vector<std::string>& added) {
    for (const auto& value : added) {
        if (value.empty()) {
            continue;
        }
        if (std::find(base.begin(), base.end(), value) == base.end()) {
            base.push_back(value);
        }
    }
    return base;
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

std::vector<std::string> normalizeAudioSourceNamesForSubscription(const std::vector<std::string>& sourceNames) {
    std::vector<std::string> out;

    for (const auto& name : sourceNames) {
        if (name.empty()) {
            continue;
        }

        // Do not subscribe to the bridge/mixed audio placeholder together with
        // endpoint audio, otherwise the same voice may be heard twice.
        if (startsWith(name, "jvb")) {
            continue;
        }

        if (name.find("-a") == std::string::npos) {
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

std::string makeReceiverAudioSubscriptionIncludeMessage(const std::vector<std::string>& audioSources) {
    const std::vector<std::string> realSources = normalizeAudioSourceNamesForSubscription(audioSources);

    if (realSources.empty()) {
        return "{\"colibriClass\":\"ReceiverAudioSubscription\",\"mode\":\"All\"}";
    }

    std::ostringstream out;
    out << "{";
    out << "\"colibriClass\":\"ReceiverAudioSubscription\",";
    out << "\"mode\":\"Include\",";
    out << "\"list\":" << jsonStringArray(realSources);
    out << "}";
    return out.str();
}

std::string makeReceiverVideoConstraintsMessage(
    const std::vector<std::string>& sourceNames,
    int maxHeight
) {
    /*
        v86 stability mode:
        - Screen-share/desktop sources remain separate NDI sources and stay at 1080p / 30fps.
        - Camera sources are requested at 720p / 30fps to reduce decode pressure while two
          screen-shares are active.
        - onStageSources remains empty to avoid over-prioritizing every stream at once.
    */
    const std::vector<std::string> realSources = normalizeVideoSourceNamesForConstraints(sourceNames);
    const int lastN = -1;
    const std::vector<std::string> emptyOnStageSources;

    std::ostringstream out;

    out << "{";
    out << "\"colibriClass\":\"ReceiverVideoConstraints\",";
    out << "\"lastN\":" << lastN << ",";
    out << "\"assumedBandwidthBps\":6700000,";
    out << "\"selectedSources\":" << jsonStringArray(realSources) << ",";
    out << "\"onStageSources\":" << jsonStringArray(emptyOnStageSources) << ",";
    out << "\"defaultConstraints\":{\"maxHeight\":" << maxHeight << ",\"maxFrameRate\":30.0},";
    out << "\"constraints\":{";

    for (std::size_t i = 0; i < realSources.size(); ++i) {
        if (i > 0) {
            out << ",";
        }

        const bool desktop = isLikelyDesktopVideoSource(realSources[i]);
        const int sourceMaxHeight = desktop ? maxHeight : 720;
        const double sourceMaxFrameRate = 30.0; // v86: keep screen-share and cameras at 30fps; only camera height is capped.

        out
            << "\""
            << escapeJsonString(realSources[i])
            << "\":{\"maxHeight\":"
            << sourceMaxHeight
            << ",\"maxFrameRate\":"
            << std::fixed << std::setprecision(1) << sourceMaxFrameRate
            << "}";
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

    const std::string constraintsMessage = makeReceiverVideoConstraintsMessage(realSources, 1080);

    /*
        v84: debounce identical receiver constraints. During join Jitsi/JVB can emit
        open-known-sources, ForwardedSources(empty), ServerHello and ForwardedSources(full)
        within a few hundred milliseconds. Re-sending the same 1080p selected-source
        subscription several times can momentarily disturb sender/JVB allocation and it
        also creates avoidable latency pressure. Keep the exact same 1080p policy, but
        do not spam identical messages.
    */
    static std::mutex debounceMutex;
    static std::string lastConstraintsMessage;
    static std::chrono::steady_clock::time_point lastConstraintsSentAt;
    static bool haveLastConstraints = false;

    const auto now = std::chrono::steady_clock::now();
    {
        std::lock_guard<std::mutex> debounceLock(debounceMutex);
        if (haveLastConstraints && constraintsMessage == lastConstraintsMessage) {
            const auto sinceMs = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastConstraintsSentAt).count();
            if (sinceMs < 5000) {
                Logger::info(
                    "NativeWebRTCAnswerer: v90 skipped duplicate ReceiverVideoConstraints, reason=",
                    reason,
                    " sinceMs=",
                    sinceMs
                );
                return;
            }
        }

        haveLastConstraints = true;
        lastConstraintsMessage = constraintsMessage;
        lastConstraintsSentAt = now;
    }

    sendLastNUnlimited(channel, reason);

    Logger::info(
        "NativeWebRTCAnswerer: requesting v90 selected-only constraints: total video receive cap 6.7Mbps, screen 1080p/30fps, camera 720p/30fps, realSources=",
        realSources.size(),
        " reason=",
        reason
    );

    sendBridgeMessage(
        channel,
        constraintsMessage,
        "ReceiverVideoConstraints/v90-cap6700kbps-screen1080p30-camera720p30-async-ndi/" + reason
    );
}
void sendReceiverAudioSubscriptionInclude(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::vector<std::string>& audioSources,
    const std::string& reason
) {
    const auto realSources = normalizeAudioSourceNamesForSubscription(audioSources);

    if (realSources.empty()) {
        Logger::warn(
            "NativeWebRTCAnswerer: audio source include-list is empty; falling back to ReceiverAudioSubscription All, reason=",
            reason
        );
    } else {
        Logger::info(
            "NativeWebRTCAnswerer: requesting endpoint audio only, sources=",
            realSources.size(),
            " reason=",
            reason
        );
    }

    sendBridgeMessage(
        channel,
        makeReceiverAudioSubscriptionIncludeMessage(realSources),
        realSources.empty()
            ? "ReceiverAudioSubscription/All-fallback/" + reason
            : "ReceiverAudioSubscription/Include-endpoint-audio/" + reason
    );
}

void scheduleSourceUpdatePokes(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::vector<std::string> videoSources,
    const std::vector<std::string> audioSources,
    const std::string reason
) {
    if (!channel) {
        return;
    }

    std::thread([channel, videoSources, audioSources, reason]() {
        const int delaysMs[] = { 600, 1800, 4500 };
        int index = 0;

        for (const int delayMs : delaysMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(delayMs));
            const std::string retryReason = reason + "-retry" + std::to_string(++index);

            if (!videoSources.empty()) {
                sendReceiverVideoConstraints(channel, videoSources, retryReason);
            }

            if (!audioSources.empty()) {
                sendReceiverAudioSubscriptionInclude(channel, audioSources, retryReason);
            }
        }
    }).detach();
}

void scheduleRepeatedAudioSubscriptionRefresh(
    const std::shared_ptr<rtc::DataChannel>& channel,
    const std::vector<std::string> audioSources
) {
    if (!channel) {
        return;
    }

    std::thread([channel, audioSources]() {
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
            sendReceiverAudioSubscriptionInclude(channel, audioSources, "refresh");
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
    struct QueuedMediaPacket {
        std::string mid;
        std::vector<std::uint8_t> bytes;
        std::chrono::steady_clock::time_point queuedAt;
        std::uint32_t ssrc = 0;
        std::uint32_t timestamp = 0;
        std::uint16_t sequence = 0;
    };

    std::mutex mediaQueueMutex;
    std::condition_variable mediaQueueCv;
    std::condition_variable mediaQueueIdleCv;
    std::deque<QueuedMediaPacket> mediaQueue;
    std::thread mediaWorker;
    bool mediaWorkerStop = false;
    bool mediaWorkerActive = false;
    std::uint64_t droppedQueuedVideoPackets = 0;
    std::uint64_t droppedQueuedAudioPackets = 0;
    std::uint64_t droppedStaleVideoPackets = 0;
    std::uint64_t droppedStaleAudioPackets = 0;
    std::uint64_t droppedSameSsrcVideoPackets = 0;

    // v91: detect broken WebRTC bridge/PeerConnection and ask the outer
    // signaling layer to reconnect immediately. Generation guards prevent
    // callbacks from old PeerConnections from firing during intentional reset.
    std::atomic<std::uint64_t> pcGeneration{0};
    std::atomic<bool> sessionFailureNotified{true};

    // v86: AV1-safe queue. v85 was too aggressive and could drop individual RTP
    // packets from a desktop AV1 stream; that corrupts OBU/frame parsing and leaves
    // the NDI screen source blank. Use a larger live window and let the AV1 assembler
    // recover on whole temporal units instead of tearing packets out of the stream.
    static constexpr std::size_t maxQueuedMediaPackets = 640;
    static constexpr std::size_t maxQueuedVideoPackets = 520;
    static constexpr std::size_t maxQueuedAudioPackets = 96;
    static constexpr std::size_t maxQueuedVideoPacketsPerSsrc = 180;
    static constexpr std::size_t targetQueuedVideoPacketsPerSsrc = 90;
    static constexpr int maxQueuedVideoAgeMs = 650;
    static constexpr int maxQueuedAudioAgeMs = 140;

    std::mutex callbackMutex;
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

    std::vector<std::string> knownVideoSources;
    std::vector<std::string> knownAudioSources;
    std::string remoteOfferSdp;
};

NativeWebRTCAnswerer::NativeWebRTCAnswerer()
    : impl_(std::make_unique<Impl>()) {
    impl_->mediaWorker = std::thread([this]() {
        for (;;) {
            Impl::QueuedMediaPacket packet;

            {
                std::unique_lock<std::mutex> lock(impl_->mediaQueueMutex);
                impl_->mediaQueueCv.wait(lock, [this]() {
                    return impl_->mediaWorkerStop || !impl_->mediaQueue.empty();
                });

                if (impl_->mediaWorkerStop && impl_->mediaQueue.empty()) {
                    break;
                }

                // Keep audio responsive: when video backlog exists, do not let audio
                // wait behind hundreds of video RTP packets. This is still a single
                // media worker, so the existing router/NDI threading model remains intact.
                auto audioIt = std::find_if(
                    impl_->mediaQueue.begin(),
                    impl_->mediaQueue.end(),
                    [](const Impl::QueuedMediaPacket& queued) {
                        return queued.mid == "audio";
                    }
                );

                if (audioIt != impl_->mediaQueue.end()) {
                    packet = std::move(*audioIt);
                    impl_->mediaQueue.erase(audioIt);
                } else {
                    packet = std::move(impl_->mediaQueue.front());
                    impl_->mediaQueue.pop_front();
                }

                impl_->mediaWorkerActive = true;
            }

            const auto now = std::chrono::steady_clock::now();
            const auto queuedMs = std::chrono::duration_cast<std::chrono::milliseconds>(now - packet.queuedAt).count();

            if (packet.mid == "video" && queuedMs > Impl::maxQueuedVideoAgeMs) {
                const auto dropped = ++impl_->droppedStaleVideoPackets;
                if (dropped == 1 || (dropped % 100) == 0) {
                    Logger::warn(
                        "NativeWebRTCAnswerer: v86 dropping stale queued video RTP after safe window, dropped=",
                        dropped,
                        " queuedMs=",
                        queuedMs,
                        " ssrc=",
                        packet.ssrc
                    );
                }
            } else if (packet.mid == "audio" && queuedMs > Impl::maxQueuedAudioAgeMs) {
                const auto dropped = ++impl_->droppedStaleAudioPackets;
                if (dropped == 1 || (dropped % 100) == 0) {
                    Logger::warn(
                        "NativeWebRTCAnswerer: v86 dropping stale queued audio RTP to avoid delayed audio, dropped=",
                        dropped,
                        " queuedMs=",
                        queuedMs,
                        " ssrc=",
                        packet.ssrc
                    );
                }
            } else {
                MediaPacketCallback cb;
                {
                    std::lock_guard<std::mutex> cbLock(impl_->callbackMutex);
                    cb = onMediaPacket_;
                }

                if (cb && !packet.bytes.empty()) {
                    cb(packet.mid, packet.bytes.data(), packet.bytes.size());
                }
            }

            {
                std::lock_guard<std::mutex> lock(impl_->mediaQueueMutex);
                impl_->mediaWorkerActive = false;
                if (impl_->mediaQueue.empty()) {
                    impl_->mediaQueueIdleCv.notify_all();
                }
            }
        }
    });

    Logger::info("NativeWebRTCAnswerer: v91 AV1 receive enabled; 6.7Mbps cap, screen 1080p/30fps, camera 720p/30fps, async NDI queue, immediate WebRTC reconnect signal");
}

NativeWebRTCAnswerer::~NativeWebRTCAnswerer() {
    resetSession();

    {
        std::lock_guard<std::mutex> lock(impl_->mediaQueueMutex);
        impl_->mediaWorkerStop = true;
        impl_->mediaQueueCv.notify_all();
    }

    if (impl_->mediaWorker.joinable()) {
        impl_->mediaWorker.join();
    }
}

void NativeWebRTCAnswerer::setIceServers(std::vector<IceServer> servers) {
    iceServers_ = std::move(servers);
}

void NativeWebRTCAnswerer::setLocalCandidateCallback(LocalCandidateCallback cb) {
    onLocalCandidate_ = std::move(cb);
}

void NativeWebRTCAnswerer::setMediaPacketCallback(MediaPacketCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->callbackMutex);
    onMediaPacket_ = std::move(cb);
}

void NativeWebRTCAnswerer::setSessionFailureCallback(SessionFailureCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->callbackMutex);
    onSessionFailure_ = std::move(cb);
}

void NativeWebRTCAnswerer::notifySessionFailureOnce(std::uint64_t generation, const std::string& reason) {
#if JNN_WITH_NATIVE_WEBRTC
    if (!impl_) {
        return;
    }

    if (impl_->pcGeneration.load() != generation) {
        return;
    }

    bool expected = false;
    if (!impl_->sessionFailureNotified.compare_exchange_strong(expected, true)) {
        return;
    }

    SessionFailureCallback cb;
    {
        std::lock_guard<std::mutex> lock(impl_->callbackMutex);
        cb = onSessionFailure_;
    }

    Logger::warn(
        "NativeWebRTCAnswerer: v91 requesting immediate signaling reconnect; reason=",
        reason
    );

    if (cb) {
        // Do not reconnect directly on a libdatachannel callback thread.
        // The signaling/main loop will consume this request and do a clean reset.
        cb(reason);
    }
#else
    (void)generation;
    (void)reason;
#endif
}

void NativeWebRTCAnswerer::updateReceiverSourcesFromJingleXml(const std::string& xml) {
#if JNN_WITH_NATIVE_WEBRTC
    const auto jingleVideoSources = extractJingleSourceNamesByMedia(xml, "video");
    const auto jingleAudioSources = extractJingleSourceNamesByMedia(xml, "audio");
    const auto unmutedPresenceVideoSources = extractSourceInfoSourceNamesByMuteState(xml, "video", false);
    const auto mutedPresenceVideoSources = extractSourceInfoSourceNamesByMuteState(xml, "video", true);
    const auto presenceAudioSources = extractSourceInfoSourceNamesByMedia(xml, "audio");

    const auto addedVideoSources = mergeUniqueStrings(jingleVideoSources, unmutedPresenceVideoSources);
    const auto addedAudioSources = mergeUniqueStrings(jingleAudioSources, presenceAudioSources);

    if (addedVideoSources.empty() && addedAudioSources.empty() && mutedPresenceVideoSources.empty()) {
        return;
    }

    std::shared_ptr<rtc::DataChannel> channel;
    std::vector<std::string> allVideoSources;
    std::vector<std::string> allAudioSources;
    bool videoSourcesChanged = false;
    bool audioSourcesChanged = false;

    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        const auto beforeVideoSources = impl_->knownVideoSources;
        const auto beforeAudioSources = impl_->knownAudioSources;

        impl_->knownVideoSources = mergeUniqueStrings(impl_->knownVideoSources, addedVideoSources);
        impl_->knownVideoSources = removeSourceNames(impl_->knownVideoSources, mutedPresenceVideoSources);
        impl_->knownAudioSources = mergeUniqueStrings(impl_->knownAudioSources, addedAudioSources);

        videoSourcesChanged = impl_->knownVideoSources != beforeVideoSources;
        audioSourcesChanged = impl_->knownAudioSources != beforeAudioSources;

        channel = impl_->bridgeChannel;
        allVideoSources = impl_->knownVideoSources;
        allAudioSources = impl_->knownAudioSources;
    }

    if (!channel) {
        Logger::warn(
            "NativeWebRTCAnswerer: v85 source update queued but bridge datachannel is not available; videoSources=",
            allVideoSources.size(),
            " audioSources=",
            allAudioSources.size()
        );
        return;
    }

    // v49: Jitsi source-add is not just a bridge constraint update. The native
    // PeerConnection also needs to learn the new SSRCs, similarly to how Jitsi
    // clients apply source-add by updating the remote description. Without this,
    // ForwardedSources can list the new source while libdatachannel never delivers
    // RTP for its SSRCs to the onTrack/onMessage callback.
    if (xml.find("<source") != std::string::npos) {
        std::shared_ptr<rtc::PeerConnection> pc;
        std::string updatedRemoteOffer;
        std::size_t addedSsrcs = 0;
        bool shouldApplyRemoteOffer = false;

        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            pc = impl_->pc;
            updatedRemoteOffer = impl_->remoteOfferSdp;

            if (pc && !updatedRemoteOffer.empty() && appendRemoteSdpSourcesFromJingleXml(updatedRemoteOffer, xml, addedSsrcs)) {
                impl_->remoteOfferSdp = updatedRemoteOffer;
                shouldApplyRemoteOffer = true;
            }
        }

        if (shouldApplyRemoteOffer && pc) {
            try {
                Logger::info(
                    "NativeWebRTCAnswerer: applying v49 remote SDP source-add update; addedSsrcs=",
                    addedSsrcs
                );
                pc->setRemoteDescription(rtc::Description(updatedRemoteOffer, "offer"));
                pc->setLocalDescription();
            } catch (const std::exception& e) {
                Logger::warn("NativeWebRTCAnswerer: v49 remote SDP source-add update failed: ", e.what());
            } catch (...) {
                Logger::warn("NativeWebRTCAnswerer: v49 remote SDP source-add update failed: unknown error");
            }
        }
    }

    Logger::info(
        "NativeWebRTCAnswerer: v85 source update; addedVideo=",
        addedVideoSources.size(),
        " mutedVideo=",
        mutedPresenceVideoSources.size(),
        " addedAudio=",
        addedAudioSources.size(),
        " totalVideo=",
        allVideoSources.size(),
        " totalAudio=",
        allAudioSources.size(),
        " videoChanged=",
        videoSourcesChanged ? "true" : "false",
        " audioChanged=",
        audioSourcesChanged ? "true" : "false"
    );

    if (videoSourcesChanged && !allVideoSources.empty()) {
        sendReceiverVideoConstraints(channel, allVideoSources, "source-update-known-sources");
    }

    if (audioSourcesChanged && !allAudioSources.empty()) {
        sendReceiverAudioSubscriptionInclude(channel, allAudioSources, "source-update-known-sources");
    }

    // v48: do not run delayed re-ask bursts here. v47 retries did not recover
    // missing media on rejoin, but they made source lifecycle harder to reason
    // about. Keep this as a single immediate update and let subsequent
    // ForwardedSources/SourceInfo events trigger normal updates.
#else
    (void)xml;
#endif
}

void NativeWebRTCAnswerer::resetSession() {
#if JNN_WITH_NATIVE_WEBRTC
    impl_->pcGeneration.fetch_add(1);
    impl_->sessionFailureNotified.store(true);

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
        impl_->knownVideoSources.clear();
        impl_->knownAudioSources.clear();
        impl_->remoteOfferSdp.clear();
    }

    {
        std::unique_lock<std::mutex> qlock(impl_->mediaQueueMutex);
        const auto queued = impl_->mediaQueue.size();
        impl_->mediaQueue.clear();
        if (queued != 0) {
            Logger::warn("NativeWebRTCAnswerer: v86 cleared stale queued media packets on session reset, queued=", queued);
        }
        impl_->mediaQueueIdleCv.wait(qlock, [this]() {
            return !impl_->mediaWorkerActive;
        });
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
    impl_->knownVideoSources.clear();
    impl_->knownAudioSources.clear();
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

    const std::uint64_t pcGeneration = impl_->pcGeneration.fetch_add(1) + 1;
    impl_->sessionFailureNotified.store(false);

    audioPackets_ = 0;
    videoPackets_ = 0;
    audioBytes_ = 0;
    videoBytes_ = 0;

    Logger::info("NativeWebRTCAnswerer: creating libdatachannel PeerConnection");
    Logger::info("NativeWebRTCAnswerer: v49 source-add remote SDP update mode enabled");
    Logger::warn("NativeWebRTCAnswerer: using remote onTrack raw RTP path with RTCP receiving session");

    const std::string rawOfferSdp = buildSdpOfferFromJingle(session);
    const std::string offerSdp = forceVp8OnlyVideoSdp(rawOfferSdp);

    if (offerSdp != rawOfferSdp) {
    }

    const std::vector<std::string> initialVideoSources = extractVideoSourceNamesFromSdp(rawOfferSdp);
    const std::vector<std::string> initialAudioSources = extractAudioSourceNamesFromSdp(rawOfferSdp);

    if (initialVideoSources.empty()) {
        Logger::warn("NativeWebRTCAnswerer: no initial video sources extracted from SDP offer");
    } else {
        Logger::info(
            "NativeWebRTCAnswerer: initial video sources extracted from SDP offer: ",
            joinStrings(initialVideoSources, ",")
        );
    }

    if (initialAudioSources.empty()) {
        Logger::warn("NativeWebRTCAnswerer: no endpoint audio sources extracted from SDP offer");
    } else {
        Logger::info(
            "NativeWebRTCAnswerer: endpoint audio sources extracted from SDP offer: ",
            joinStrings(initialAudioSources, ",")
        );
    }

    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->knownVideoSources = initialVideoSources;
        impl_->knownAudioSources = initialAudioSources;
        impl_->remoteOfferSdp = offerSdp;
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

    pc->onStateChange([this, pcGeneration](rtc::PeerConnection::State state) {
        const int numericState = static_cast<int>(state);
        Logger::info("NativeWebRTCAnswerer: PeerConnection state=", numericState);

        if (numericState == 4 || numericState == 5) {
            Logger::warn("NativeWebRTCAnswerer: v91: WebRTC PeerConnection failed/closed; requesting immediate Jitsi reconnect");
            notifySessionFailureOnce(
                pcGeneration,
                numericState == 4 ? "peerconnection-failed" : "peerconnection-closed"
            );
        }
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
            this,
            bridgeChannel,
            latestForwardedSources,
            latestForwardedSourcesMutex,
            initialVideoSources,
            initialAudioSources
        ]() {
            Logger::info("NativeWebRTCAnswerer: bridge datachannel opened");

            sendBridgeMessage(
                bridgeChannel,
                "{\"colibriClass\":\"ClientHello\"}",
                "ClientHello"
            );

            std::vector<std::string> openVideoSources;
            std::vector<std::string> openAudioSources;
            {
                std::lock_guard<std::mutex> lock(impl_->mutex);
                openVideoSources = impl_->knownVideoSources.empty()
                    ? initialVideoSources
                    : impl_->knownVideoSources;
                openAudioSources = impl_->knownAudioSources.empty()
                    ? initialAudioSources
                    : impl_->knownAudioSources;
            }

            sendReceiverAudioSubscriptionInclude(bridgeChannel, openAudioSources, "open-known-sources");

            sendReceiverVideoConstraints(
                bridgeChannel,
                openVideoSources,
                "open-known-sources"
            );

            // v41: do not run repeated refresh loops.
            // The one-shot open/server-hello/ForwardedSources constraints are enough for JVB,
            // while repeated sends after DataChannel close caused noisy warnings and could destabilize long sessions.
            Logger::info("NativeWebRTCAnswerer: v48 stable rejoin mode; selected-only video; endpoint-only audio; no NDI pre-create; no delayed retry bursts");
        });

        bridgeChannel->onClosed([this, pcGeneration]() {
            Logger::warn("NativeWebRTCAnswerer: bridge datachannel closed; v91 requesting immediate Jitsi reconnect");
            notifySessionFailureOnce(pcGeneration, "bridge-datachannel-closed");
        });

        bridgeChannel->onError([this, pcGeneration](std::string error) {
            Logger::warn("NativeWebRTCAnswerer: bridge datachannel error: ", error);
            notifySessionFailureOnce(pcGeneration, "bridge-datachannel-error: " + error);
        });

        bridgeChannel->onMessage([
            this,
            bridgeChannel,
            latestForwardedSources,
            latestForwardedSourcesMutex,
            initialVideoSources,
            initialAudioSources
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
                std::vector<std::string> serverVideoSources;
                std::vector<std::string> serverAudioSources;
                {
                    std::lock_guard<std::mutex> lock(impl_->mutex);
                    serverVideoSources = impl_->knownVideoSources.empty()
                        ? initialVideoSources
                        : impl_->knownVideoSources;
                    serverAudioSources = impl_->knownAudioSources.empty()
                        ? initialAudioSources
                        : impl_->knownAudioSources;
                }

                Logger::info(
                    "NativeWebRTCAnswerer: ServerHello received; sending known-source constraints videoSources=",
                    serverVideoSources.size(),
                    " audioSources=",
                    serverAudioSources.size()
                );

                sendReceiverVideoConstraints(
                    bridgeChannel,
                    serverVideoSources,
                    "server-hello-known-sources"
                );

                sendReceiverAudioSubscriptionInclude(bridgeChannel, serverAudioSources, "server-hello-known-sources");

                return;
            }

            if (text.find("\"colibriClass\":\"VideoSourcesMap\"") != std::string::npos) {
                const auto sources = extractVideoSourcesMapSources(text);

                if (!sources.empty()) {
                    {
                        std::lock_guard<std::mutex> lock(*latestForwardedSourcesMutex);
                        *latestForwardedSources = sources;
                    }

                    std::vector<std::string> allKnownVideoSources;
                    {
                        std::lock_guard<std::mutex> lock(impl_->mutex);
                        impl_->knownVideoSources = mergeUniqueStrings(impl_->knownVideoSources, sources);
                        allKnownVideoSources = impl_->knownVideoSources;
                    }

                    Logger::info(
                        "NativeWebRTCAnswerer: VideoSourcesMap parsed count=",
                        sources.size(),
                        "; sending known-source constraints total=",
                        allKnownVideoSources.size()
                    );

                    sendReceiverVideoConstraints(
                        bridgeChannel,
                        allKnownVideoSources,
                        "video-sources-map-known-sources"
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

                std::vector<std::string> allKnownVideoSources;
                {
                    std::lock_guard<std::mutex> lock(impl_->mutex);
                    if (!sources.empty()) {
                        impl_->knownVideoSources = mergeUniqueStrings(impl_->knownVideoSources, sources);
                    }
                    allKnownVideoSources = impl_->knownVideoSources.empty()
                        ? initialVideoSources
                        : impl_->knownVideoSources;
                }

                if (sources.empty()) {
                    Logger::info(
                        "NativeWebRTCAnswerer: ForwardedSources is empty; v85 keeps the last live subscription instead of resending during join, knownSources=",
                        allKnownVideoSources.size()
                    );

                    return;
                }

                const auto activeKnownVideoSources = mergeUniqueStrings(sources, allKnownVideoSources);

                Logger::info(
                    "NativeWebRTCAnswerer: ForwardedSources parsed count=",
                    sources.size(),
                    "; sending v85 active/known-source constraints total=",
                    activeKnownVideoSources.size()
                );

                sendReceiverVideoConstraints(
                    bridgeChannel,
                    activeKnownVideoSources,
                    "forwarded-known-sources"
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

            {
                std::unique_lock<std::mutex> qlock(impl_->mediaQueueMutex);

                const auto now = std::chrono::steady_clock::now();
                std::uint16_t rtpSequence = 0;
                std::uint32_t rtpTimestamp = 0;
                std::uint32_t rtpSsrc = 0;
                parseBasicRtpHeader(ptr, size, rtpSequence, rtpTimestamp, rtpSsrc);

                auto eraseAndCount = [&](std::deque<Impl::QueuedMediaPacket>::iterator it, bool stale) {
                    const bool isVideo = it->mid == "video";
                    const bool isAudio = it->mid == "audio";
                    impl_->mediaQueue.erase(it);
                    if (isVideo) {
                        if (stale) {
                            return ++impl_->droppedStaleVideoPackets;
                        }
                        return ++impl_->droppedQueuedVideoPackets;
                    }
                    if (isAudio) {
                        if (stale) {
                            return ++impl_->droppedStaleAudioPackets;
                        }
                        return ++impl_->droppedQueuedAudioPackets;
                    }
                    return ++impl_->droppedQueuedVideoPackets;
                };

                for (auto it = impl_->mediaQueue.begin(); it != impl_->mediaQueue.end();) {
                    const auto ageMs = std::chrono::duration_cast<std::chrono::milliseconds>(now - it->queuedAt).count();
                    const bool staleVideo = it->mid == "video" && ageMs > Impl::maxQueuedVideoAgeMs;
                    const bool staleAudio = it->mid == "audio" && ageMs > Impl::maxQueuedAudioAgeMs;
                    if (staleVideo || staleAudio) {
                        const auto dropped = eraseAndCount(it, true);
                        if (dropped == 1 || (dropped % 100) == 0) {
                            Logger::warn(
                                "NativeWebRTCAnswerer: v86 pruned stale queued RTP before enqueue, dropped=",
                                dropped,
                                " media=",
                                staleVideo ? "video" : "audio",
                                " ageMs=",
                                ageMs
                            );
                        }
                        it = impl_->mediaQueue.begin();
                        continue;
                    }
                    ++it;
                }

                auto countQueued = [&](const char* queuedMid, std::uint32_t onlySsrc) {
                    std::size_t count = 0;
                    for (const auto& queued : impl_->mediaQueue) {
                        if (queued.mid != queuedMid) {
                            continue;
                        }
                        if (onlySsrc != 0 && queued.ssrc != onlySsrc) {
                            continue;
                        }
                        ++count;
                    }
                    return count;
                };

                auto dropOldest = [&](const char* queuedMid, std::uint32_t onlySsrc, bool sameSsrcDrop) {
                    for (auto it = impl_->mediaQueue.begin(); it != impl_->mediaQueue.end(); ++it) {
                        if (it->mid != queuedMid) {
                            continue;
                        }
                        if (onlySsrc != 0 && it->ssrc != onlySsrc) {
                            continue;
                        }
                        impl_->mediaQueue.erase(it);
                        if (std::string(queuedMid) == "video") {
                            if (sameSsrcDrop) {
                                return ++impl_->droppedSameSsrcVideoPackets;
                            }
                            return ++impl_->droppedQueuedVideoPackets;
                        }
                        return ++impl_->droppedQueuedAudioPackets;
                    }
                    return std::uint64_t{0};
                };

                if (mid == "video") {
                    while (rtpSsrc != 0 && countQueued("video", rtpSsrc) >= Impl::maxQueuedVideoPacketsPerSsrc) {
                        const auto dropped = dropOldest("video", rtpSsrc, true);
                        if (dropped == 1 || (dropped % 100) == 0) {
                            Logger::warn(
                                "NativeWebRTCAnswerer: v86 dropping old video RTP only after expanded AV1-safe SSRC window, dropped=",
                                dropped,
                                " ssrc=",
                                rtpSsrc
                            );
                        }
                        if (countQueued("video", rtpSsrc) <= Impl::targetQueuedVideoPacketsPerSsrc) {
                            break;
                        }
                    }

                    while (countQueued("video", 0) >= Impl::maxQueuedVideoPackets
                        || impl_->mediaQueue.size() >= Impl::maxQueuedMediaPackets) {
                        const auto dropped = dropOldest("video", 0, false);
                        if (dropped == 0) {
                            break;
                        }
                        if (dropped == 1 || (dropped % 100) == 0) {
                            Logger::warn(
                                "NativeWebRTCAnswerer: v86 dropping old queued video RTP after expanded AV1-safe window, dropped=",
                                dropped,
                                " queued=",
                                impl_->mediaQueue.size()
                            );
                        }
                    }
                } else if (mid == "audio") {
                    while (countQueued("audio", 0) >= Impl::maxQueuedAudioPackets) {
                        const auto dropped = dropOldest("audio", 0, false);
                        if (dropped == 0) {
                            break;
                        }
                        if (dropped == 1 || (dropped % 100) == 0) {
                            Logger::warn(
                                "NativeWebRTCAnswerer: v86 dropping old queued audio RTP to avoid delayed audio, dropped=",
                                dropped,
                                " queued=",
                                impl_->mediaQueue.size()
                            );
                        }
                    }

                    while (impl_->mediaQueue.size() >= Impl::maxQueuedMediaPackets) {
                        const auto dropped = dropOldest("video", 0, false);
                        if (dropped == 0) {
                            const auto audioDropped = dropOldest("audio", 0, false);
                            if (audioDropped == 0) {
                                break;
                            }
                        }
                    }
                }

                if (impl_->mediaQueue.size() >= Impl::maxQueuedMediaPackets) {
                    const auto dropped = (mid == "audio")
                        ? ++impl_->droppedQueuedAudioPackets
                        : ++impl_->droppedQueuedVideoPackets;
                    if (dropped == 1 || (dropped % 100) == 0) {
                        Logger::warn(
                            "NativeWebRTCAnswerer: v86 media queue still full; dropping incoming RTP, media=",
                            mid,
                            " dropped=",
                            dropped,
                            " queued=",
                            impl_->mediaQueue.size()
                        );
                    }
                    return;
                }

                Impl::QueuedMediaPacket packet;
                packet.mid = mid;
                packet.queuedAt = now;
                packet.ssrc = rtpSsrc;
                packet.timestamp = rtpTimestamp;
                packet.sequence = rtpSequence;
                packet.bytes.assign(ptr, ptr + size);
                impl_->mediaQueue.push_back(std::move(packet));
            }

            impl_->mediaQueueCv.notify_one();
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


