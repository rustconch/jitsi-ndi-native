#pragma once

#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

struct JitsiSourceInfo {
    std::uint32_t ssrc = 0;
    std::string media;       // "audio" or "video"
    std::string ownerJid;    // room@muc/nickname-or-endpoint
    std::string endpointId;  // stable-ish id from owner resource when possible
    std::string displayName; // fallback = endpointId / ssrc
    std::string videoType;
};

class JitsiSourceMap {
public:
    void updateFromJingleXml(const std::string& xml);
    void removeFromJingleXml(const std::string& xml);

    std::optional<JitsiSourceInfo> lookup(std::uint32_t ssrc) const;
    std::vector<JitsiSourceInfo> allSources() const;

    static std::vector<JitsiSourceInfo> parseSources(const std::string& xml);
    static std::string sanitizeForNdiName(std::string value);

private:
    mutable std::mutex mutex_;
    std::unordered_map<std::uint32_t, JitsiSourceInfo> bySsrc_;
};
