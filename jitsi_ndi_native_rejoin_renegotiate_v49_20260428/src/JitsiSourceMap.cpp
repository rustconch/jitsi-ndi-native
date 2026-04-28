#include "JitsiSourceMap.h"

#include <algorithm>
#include <cctype>
#include <regex>
#include <set>
#include <sstream>

namespace {
std::string xmlUnescape(std::string s) {
    auto repl = [&](const std::string& a, const std::string& b) {
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

std::string attr(const std::string& tag, const std::string& name) {
    const std::regex re(name + R"(\s*=\s*(['"])(.*?)\1)", std::regex::icase);
    std::smatch m;
    if (std::regex_search(tag, m, re) && m.size() > 2) return xmlUnescape(m[2].str());
    return {};
}

std::vector<std::string> contentBlocks(const std::string& xml) {
    std::vector<std::string> out;
    const std::regex re(R"(<content(?:\s|>)[\s\S]*?</content>)", std::regex::icase);
    for (auto it = std::sregex_iterator(xml.begin(), xml.end(), re); it != std::sregex_iterator(); ++it) {
        out.push_back((*it)[0].str());
    }
    return out;
}

std::vector<std::string> sourceBlocks(const std::string& xml) {
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

std::string firstTag(const std::string& xml, const std::string& name) {
    const std::regex re("<" + name + R"((?:\s|>|/)[\s\S]*?>)", std::regex::icase);
    std::smatch m;
    if (std::regex_search(xml, m, re)) return m[0].str();
    return {};
}

std::string resourceFromJid(const std::string& jid) {
    const auto slash = jid.rfind('/');
    if (slash != std::string::npos && slash + 1 < jid.size()) return jid.substr(slash + 1);
    return jid;
}

std::uint32_t parseU32(const std::string& s) {
    try {
        return static_cast<std::uint32_t>(std::stoul(s));
    } catch (...) {
        return 0;
    }
}

bool startsWith(const std::string& s, const std::string& prefix) {
    return s.rfind(prefix, 0) == 0;
}

std::string endpointFromSourceName(const std::string& rawName) {
    std::string name = resourceFromJid(rawName);
    if (name.empty()) {
        return {};
    }

    // Jitsi source names are often endpointId-a0 / endpointId-v0 / endpointId-desktop0.
    // When the owner extension is missing, using the whole source name splits audio and
    // video into different NDI senders. Strip the media suffix and keep the endpoint id.
    static const std::regex suffixRe(
        R"(^(.+?)(?:[-_](?:audio|video|camera|desktop|screen|a|v|d)\d*)$)",
        std::regex::icase
    );

    std::smatch m;
    if (std::regex_match(name, m, suffixRe) && m.size() > 1 && !m[1].str().empty()) {
        return m[1].str();
    }

    return name;
}

bool isFallbackSsrcEndpoint(const std::string& endpointId) {
    return startsWith(endpointId, "ssrc-");
}

bool looksLikeJitsiSourceName(const std::string& value) {
    if (value.empty()) {
        return false;
    }

    std::string lower = value;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });

    if (lower == "muted" || lower == "videotype" || lower == "owner" || lower == "msid") {
        return false;
    }

    static const std::regex sourceNameRe(
        R"(^[^\"{}:]+[-_](?:a|v|d|audio|video|camera|desktop|screen)\d+$)",
        std::regex::icase
    );

    return std::regex_match(value, sourceNameRe);
}
std::string tagText(const std::string& xml, const std::string& name) {
    const std::regex re("<" + name + R"((?:\s[^>]*)?>([\s\S]*?)</)" + name + R"(>)", std::regex::icase);
    std::smatch m;
    if (std::regex_search(xml, m, re) && m.size() > 1) {
        return xmlUnescape(m[1].str());
    }
    return {};
}

std::string trimCopy(std::string s) {
    auto notSpace = [](unsigned char c) { return !std::isspace(c); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), notSpace));
    s.erase(std::find_if(s.rbegin(), s.rend(), notSpace).base(), s.end());
    return s;
}

std::vector<std::string> sourceNamesFromSourceInfo(const std::string& xml) {
    std::vector<std::string> out;
    const std::string sourceInfo = xmlUnescape(tagText(xml, "SourceInfo"));
    if (sourceInfo.empty()) {
        return out;
    }

    const std::regex keyRe(R"KEY("([^"]+)"\s*:)KEY");
    for (auto it = std::sregex_iterator(sourceInfo.begin(), sourceInfo.end(), keyRe);
         it != std::sregex_iterator();
         ++it) {
        if ((*it).size() > 1) {
            const std::string key = (*it)[1].str();
            // SourceInfo is JSON-like: top-level keys are source names, while nested
            // keys such as "muted" and "videoType" are metadata. Do not treat nested
            // metadata keys as endpoints, otherwise rejoin/name-change cleanup can
            // recycle bogus endpoints like "muted" and break NDI routing.
            if (looksLikeJitsiSourceName(key)) {
                out.push_back(key);
            }
        }
    }

    return out;
}

std::set<std::uint32_t> parseRetransmissionSsrcsFromXml(const std::string& xml) {
    std::set<std::uint32_t> out;

    const std::regex groupRe(
        R"(<ssrc-group(?:\s|>)[^>]*semantics\s*=\s*(['"])FID\1[\s\S]*?</ssrc-group>)",
        std::regex::icase
    );

    const std::regex sourceRe(R"(<source(?:\s|>)[^>]*ssrc\s*=\s*(['"])(\d+)\1[^>]*(?:/>|>))", std::regex::icase);

    for (auto groupIt = std::sregex_iterator(xml.begin(), xml.end(), groupRe);
         groupIt != std::sregex_iterator();
         ++groupIt) {
        const std::string group = (*groupIt)[0].str();
        std::vector<std::uint32_t> groupSsrcs;

        for (auto sourceIt = std::sregex_iterator(group.begin(), group.end(), sourceRe);
             sourceIt != std::sregex_iterator();
             ++sourceIt) {
            if ((*sourceIt).size() > 2) {
                const auto value = parseU32((*sourceIt)[2].str());
                if (value != 0) {
                    groupSsrcs.push_back(value);
                }
            }
        }

        // In a Jitsi FID group, the first SSRC is the primary media stream and
        // following SSRCs are retransmission/RTX. Do not feed RTX packets into
        // the AV1/VP8 media assembler as if they were primary video packets.
        for (std::size_t i = 1; i < groupSsrcs.size(); ++i) {
            out.insert(groupSsrcs[i]);
        }
    }

    return out;
}
} // namespace

std::vector<JitsiSourceInfo> JitsiSourceMap::parseSources(const std::string& xml) {
    std::vector<JitsiSourceInfo> result;
    for (const auto& content : contentBlocks(xml)) {
        const auto ctag = firstTag(content, "content");
        std::string media = attr(ctag, "name");
        if (media.empty()) media = attr(firstTag(content, "description"), "media");

        for (const auto& srcBlock : sourceBlocks(content)) {
            const auto stag = firstTag(srcBlock, "source");
            JitsiSourceInfo info;
            info.ssrc = parseU32(attr(stag, "ssrc"));
            info.media = media;
            info.videoType = attr(stag, "videoType");
            info.sourceName = attr(stag, "name");

            // In Jitsi owner is often nested inside <ssrc-info owner='...'>, not on <source> itself.
            info.ownerJid = attr(stag, "owner");
            if (info.ownerJid.empty()) {
                const auto ssrcInfoTag = firstTag(srcBlock, "ssrc-info");
                info.ownerJid = attr(ssrcInfoTag, "owner");
            }

            // Ignore <source ssrc='...'/> entries from <ssrc-group>. They duplicate real source
            // lines and otherwise can overwrite owner/name metadata with an ssrc-* fallback.
            if (info.sourceName.empty() && info.ownerJid.empty() && info.videoType.empty()) {
                continue;
            }

            info.endpointId = resourceFromJid(info.ownerJid);
            if (info.endpointId.empty()) {
                info.endpointId = endpointFromSourceName(info.sourceName);
            }
            if (info.endpointId.empty()) {
                std::ostringstream oss;
                oss << "ssrc-" << info.ssrc;
                info.endpointId = oss.str();
            }

            info.displayName = sanitizeForNdiName(info.endpointId);
            if (info.ssrc != 0) result.push_back(std::move(info));
        }
    }

    // Safety fallback for the common single-speaker case: if Jitsi provided a usable
    // endpoint id for video but not for audio, bind the orphan audio SSRC to that same
    // endpoint instead of creating a separate audio-only NDI source.
    std::set<std::string> stableVideoEndpoints;
    for (const auto& source : result) {
        if (source.media == "video" && !source.endpointId.empty() && !isFallbackSsrcEndpoint(source.endpointId)) {
            stableVideoEndpoints.insert(source.endpointId);
        }
    }

    if (stableVideoEndpoints.size() == 1) {
        const std::string endpoint = *stableVideoEndpoints.begin();
        for (auto& source : result) {
            if (source.media == "audio" && isFallbackSsrcEndpoint(source.endpointId)) {
                source.endpointId = endpoint;
                source.displayName = sanitizeForNdiName(endpoint);
            }
        }
    }

    return result;
}

void JitsiSourceMap::updateDisplayNamesFromXml(const std::string& xml) {
    if (xml.find("<presence") == std::string::npos && xml.find("<message") == std::string::npos) {
        return;
    }

    std::string displayName = trimCopy(tagText(xml, "nick"));
    if (displayName.empty()) {
        displayName = trimCopy(tagText(xml, "display-name"));
    }

    if (displayName.empty()) {
        return;
    }

    displayName = sanitizeForNdiName(displayName);
    if (displayName.empty() || displayName == "unknown") {
        return;
    }

    const std::string presenceTag = firstTag(xml, "presence");
    std::string endpoint = resourceFromJid(attr(presenceTag, "from"));

    std::vector<std::string> endpointsToUpdate;

    if (!endpoint.empty() && !isFallbackSsrcEndpoint(endpoint)) {
        endpointsToUpdate.push_back(endpoint);
    }

    for (const auto& sourceName : sourceNamesFromSourceInfo(xml)) {
        const std::string sourceEndpoint = endpointFromSourceName(sourceName);
        if (!sourceEndpoint.empty() && !isFallbackSsrcEndpoint(sourceEndpoint) &&
            std::find(endpointsToUpdate.begin(), endpointsToUpdate.end(), sourceEndpoint) == endpointsToUpdate.end()) {
            endpointsToUpdate.push_back(sourceEndpoint);
        }
    }

    std::lock_guard<std::mutex> lock(mutex_);

    for (const auto& ep : endpointsToUpdate) {
        displayNameByEndpoint_[ep] = displayName;
    }

    for (auto& kv : bySsrc_) {
        auto& source = kv.second;
        if (std::find(endpointsToUpdate.begin(), endpointsToUpdate.end(), source.endpointId) != endpointsToUpdate.end()) {
            source.displayName = displayName;
        }
    }
}
void JitsiSourceMap::updateFromJingleXml(const std::string& xml) {
    updateDisplayNamesFromXml(xml);

    const auto sources = parseSources(xml);
    const auto rtxSsrcs = parseRetransmissionSsrcsFromXml(xml);

    if (sources.empty() && rtxSsrcs.empty()) return;

    std::lock_guard<std::mutex> lock(mutex_);

    for (const auto ssrc : rtxSsrcs) {
        rtxSsrcs_.insert(ssrc);
        bySsrc_.erase(ssrc);
    }

    for (auto s : sources) {
        if (rtxSsrcs_.find(s.ssrc) != rtxSsrcs_.end()) {
            continue;
        }

        const auto it = displayNameByEndpoint_.find(s.endpointId);
        if (it != displayNameByEndpoint_.end() && !it->second.empty()) {
            s.displayName = it->second;
        }
        bySsrc_[s.ssrc] = std::move(s);
    }
}
void JitsiSourceMap::removeFromJingleXml(const std::string& xml) {
    const auto sources = parseSources(xml);
    const auto rtxSsrcs = parseRetransmissionSsrcsFromXml(xml);
    if (sources.empty() && rtxSsrcs.empty()) return;
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& s : sources) bySsrc_.erase(s.ssrc);
    for (const auto ssrc : rtxSsrcs) rtxSsrcs_.erase(ssrc);
}

void JitsiSourceMap::removeEndpoint(const std::string& endpointId) {
    if (endpointId.empty() || isFallbackSsrcEndpoint(endpointId)) {
        return;
    }

    std::lock_guard<std::mutex> lock(mutex_);

    for (auto it = bySsrc_.begin(); it != bySsrc_.end();) {
        const auto& s = it->second;
        if (s.endpointId == endpointId || startsWith(s.sourceName, endpointId + "-") || startsWith(s.sourceName, endpointId + "_")) {
            it = bySsrc_.erase(it);
        } else {
            ++it;
        }
    }

    displayNameByEndpoint_.erase(endpointId);
}

std::optional<JitsiSourceInfo> JitsiSourceMap::lookup(std::uint32_t ssrc) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto it = bySsrc_.find(ssrc);
    if (it == bySsrc_.end()) return std::nullopt;
    return it->second;
}

bool JitsiSourceMap::isRtxSsrc(std::uint32_t ssrc) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return rtxSsrcs_.find(ssrc) != rtxSsrcs_.end();
}

std::vector<JitsiSourceInfo> JitsiSourceMap::allSources() const {
    std::vector<JitsiSourceInfo> out;
    std::lock_guard<std::mutex> lock(mutex_);
    out.reserve(bySsrc_.size());
    for (const auto& kv : bySsrc_) out.push_back(kv.second);
    return out;
}

namespace {
const char* transliterateCyrillicCodepoint(unsigned int cp) {
    switch (cp) {
    case 0x0410: return "A"; case 0x0430: return "a";
    case 0x0411: return "B"; case 0x0431: return "b";
    case 0x0412: return "V"; case 0x0432: return "v";
    case 0x0413: return "G"; case 0x0433: return "g";
    case 0x0414: return "D"; case 0x0434: return "d";
    case 0x0415: return "E"; case 0x0435: return "e";
    case 0x0401: return "Yo"; case 0x0451: return "yo";
    case 0x0416: return "Zh"; case 0x0436: return "zh";
    case 0x0417: return "Z"; case 0x0437: return "z";
    case 0x0418: return "I"; case 0x0438: return "i";
    case 0x0419: return "Y"; case 0x0439: return "y";
    case 0x041A: return "K"; case 0x043A: return "k";
    case 0x041B: return "L"; case 0x043B: return "l";
    case 0x041C: return "M"; case 0x043C: return "m";
    case 0x041D: return "N"; case 0x043D: return "n";
    case 0x041E: return "O"; case 0x043E: return "o";
    case 0x041F: return "P"; case 0x043F: return "p";
    case 0x0420: return "R"; case 0x0440: return "r";
    case 0x0421: return "S"; case 0x0441: return "s";
    case 0x0422: return "T"; case 0x0442: return "t";
    case 0x0423: return "U"; case 0x0443: return "u";
    case 0x0424: return "F"; case 0x0444: return "f";
    case 0x0425: return "Kh"; case 0x0445: return "kh";
    case 0x0426: return "Ts"; case 0x0446: return "ts";
    case 0x0427: return "Ch"; case 0x0447: return "ch";
    case 0x0428: return "Sh"; case 0x0448: return "sh";
    case 0x0429: return "Sch"; case 0x0449: return "sch";
    case 0x042A: return ""; case 0x044A: return "";
    case 0x042B: return "Y"; case 0x044B: return "y";
    case 0x042C: return ""; case 0x044C: return "";
    case 0x042D: return "E"; case 0x044D: return "e";
    case 0x042E: return "Yu"; case 0x044E: return "yu";
    case 0x042F: return "Ya"; case 0x044F: return "ya";
    default: return nullptr;
    }
}

bool nextUtf8Codepoint(const std::string& value, std::size_t& pos, unsigned int& cp) {
    if (pos >= value.size()) {
        return false;
    }

    const unsigned char c0 = static_cast<unsigned char>(value[pos]);
    if (c0 < 0x80) {
        cp = c0;
        ++pos;
        return true;
    }

    if ((c0 & 0xE0) == 0xC0 && pos + 1 < value.size()) {
        const unsigned char c1 = static_cast<unsigned char>(value[pos + 1]);
        if ((c1 & 0xC0) == 0x80) {
            cp = ((c0 & 0x1F) << 6) | (c1 & 0x3F);
            pos += 2;
            return true;
        }
    }

    if ((c0 & 0xF0) == 0xE0 && pos + 2 < value.size()) {
        const unsigned char c1 = static_cast<unsigned char>(value[pos + 1]);
        const unsigned char c2 = static_cast<unsigned char>(value[pos + 2]);
        if ((c1 & 0xC0) == 0x80 && (c2 & 0xC0) == 0x80) {
            cp = ((c0 & 0x0F) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F);
            pos += 3;
            return true;
        }
    }

    if ((c0 & 0xF8) == 0xF0 && pos + 3 < value.size()) {
        const unsigned char c1 = static_cast<unsigned char>(value[pos + 1]);
        const unsigned char c2 = static_cast<unsigned char>(value[pos + 2]);
        const unsigned char c3 = static_cast<unsigned char>(value[pos + 3]);
        if ((c1 & 0xC0) == 0x80 && (c2 & 0xC0) == 0x80 && (c3 & 0xC0) == 0x80) {
            cp = ((c0 & 0x07) << 18) | ((c1 & 0x3F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F);
            pos += 4;
            return true;
        }
    }

    cp = 0xFFFD;
    ++pos;
    return true;
}
} // namespace

std::string JitsiSourceMap::sanitizeForNdiName(std::string value) {
    std::string out;
    out.reserve(value.size());

    std::size_t pos = 0;
    while (pos < value.size()) {
        unsigned int cp = 0;
        if (!nextUtf8Codepoint(value, pos, cp)) {
            break;
        }

        if (cp < 0x80) {
            const char c = static_cast<char>(cp);
            const auto u = static_cast<unsigned char>(c);
            if (std::isalnum(u) || c == '-' || c == '_' || c == ' ') {
                out.push_back(c);
            } else {
                out.push_back('_');
            }
            continue;
        }

        if (const char* translit = transliterateCyrillicCodepoint(cp)) {
            out += translit;
        } else {
            out.push_back('_');
        }
    }

    std::string compact;
    compact.reserve(out.size());
    char last = 0;
    for (char c : out) {
        if ((c == '_' || c == ' ') && (last == '_' || last == ' ')) {
            continue;
        }
        compact.push_back(c);
        last = c;
    }

    while (!compact.empty() && (compact.front() == '_' || compact.front() == ' ')) compact.erase(compact.begin());
    while (!compact.empty() && (compact.back() == '_' || compact.back() == ' ')) compact.pop_back();
    return compact.empty() ? "unknown" : compact;
}


