#include "JitsiSourceMap.h"

#include <algorithm>
#include <cctype>
#include <regex>
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

            // In Jitsi owner is often nested inside <ssrc-info owner='...'>, not on <source> itself.
            info.ownerJid = attr(stag, "owner");
            if (info.ownerJid.empty()) {
                const auto ssrcInfoTag = firstTag(srcBlock, "ssrc-info");
                info.ownerJid = attr(ssrcInfoTag, "owner");
            }

            info.endpointId = resourceFromJid(info.ownerJid);
            if (info.endpointId.empty()) {
                std::ostringstream oss;
                oss << "ssrc-" << info.ssrc;
                info.endpointId = oss.str();
            }
            info.displayName = sanitizeForNdiName(info.endpointId);
            if (info.ssrc != 0) result.push_back(std::move(info));
        }
    }
    return result;
}

void JitsiSourceMap::updateFromJingleXml(const std::string& xml) {
    const auto sources = parseSources(xml);
    if (sources.empty()) return;
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& s : sources) bySsrc_[s.ssrc] = s;
}

void JitsiSourceMap::removeFromJingleXml(const std::string& xml) {
    const auto sources = parseSources(xml);
    if (sources.empty()) return;
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& s : sources) bySsrc_.erase(s.ssrc);
}

std::optional<JitsiSourceInfo> JitsiSourceMap::lookup(std::uint32_t ssrc) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto it = bySsrc_.find(ssrc);
    if (it == bySsrc_.end()) return std::nullopt;
    return it->second;
}

std::vector<JitsiSourceInfo> JitsiSourceMap::allSources() const {
    std::vector<JitsiSourceInfo> out;
    std::lock_guard<std::mutex> lock(mutex_);
    out.reserve(bySsrc_.size());
    for (const auto& kv : bySsrc_) out.push_back(kv.second);
    return out;
}

std::string JitsiSourceMap::sanitizeForNdiName(std::string value) {
    for (char& c : value) {
        const auto u = static_cast<unsigned char>(c);
        if (!(std::isalnum(u) || c == '-' || c == '_' || c == ' ')) c = '_';
    }
    while (!value.empty() && value.front() == '_') value.erase(value.begin());
    while (!value.empty() && value.back() == '_') value.pop_back();
    return value.empty() ? "unknown" : value;
}
