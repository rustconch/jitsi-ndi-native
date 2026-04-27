#pragma once
// AV_STABILITY_RTP_SOURCE_REGISTRY

#include <cstdint>
#include <mutex>
#include <regex>
#include <string>
#include <unordered_map>

namespace RtpSourceRegistry {

struct SourceInfo { std::string owner; std::string name; };

inline std::mutex& mutexRef() { static std::mutex m; return m; }
inline std::unordered_map<uint32_t, SourceInfo>& mapRef() { static std::unordered_map<uint32_t, SourceInfo> m; return m; }

inline std::string ownerFromSourceName(const std::string& name) {
    const auto dash = name.find('-');
    if (dash != std::string::npos && dash > 0) return name.substr(0, dash);
    return {};
}

inline void setSsrcOwner(uint32_t ssrc, const std::string& owner, const std::string& name = std::string()) {
    if (ssrc == 0) return;
    std::string resolved = owner;
    if (resolved.empty() || resolved == "jvb") {
        const std::string fromName = ownerFromSourceName(name);
        if (!fromName.empty() && fromName != "jvb") resolved = fromName;
    }
    if (resolved.empty() || resolved == "jvb") return;
    std::lock_guard<std::mutex> lock(mutexRef());
    mapRef()[ssrc] = SourceInfo{resolved, name};
}

inline std::string ownerForSsrc(uint32_t ssrc, const std::string& fallback) {
    std::lock_guard<std::mutex> lock(mutexRef());
    const auto it = mapRef().find(ssrc);
    if (it == mapRef().end() || it->second.owner.empty()) return fallback;
    return it->second.owner;
}

inline void registerFromSdp(const std::string& sdp) {
    static const std::regex msidRe(R"(a=ssrc:([0-9]+)\s+msid:([A-Za-z0-9]+)-(?:audio|video)-[^\r\n\s]*)", std::regex::icase);
    auto begin = std::sregex_iterator(sdp.begin(), sdp.end(), msidRe);
    auto end = std::sregex_iterator();
    for (auto it = begin; it != end; ++it) {
        const uint32_t ssrc = static_cast<uint32_t>(std::stoull((*it)[1].str()));
        const std::string owner = (*it)[2].str();
        setSsrcOwner(ssrc, owner, owner);
    }
}

} // namespace RtpSourceRegistry
