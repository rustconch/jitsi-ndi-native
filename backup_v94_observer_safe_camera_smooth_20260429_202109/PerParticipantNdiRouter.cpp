#include "PerParticipantNdiRouter.h"

#include "Logger.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <regex>
#include <set>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>
#include "RtpSourceRegistry.h"

namespace {

std::uint8_t readRtpPayloadType(const std::uint8_t* data, std::size_t size) {
    if (!data || size < 2) {
        return 0;
    }

    return static_cast<std::uint8_t>(data[1] & 0x7F);
}

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
    if (std::regex_search(tag, m, re) && m.size() > 2) {
        return xmlUnescape(m[2].str());
    }
    return {};
}

std::string firstTag(const std::string& xml, const std::string& name) {
    const std::regex re("<" + name + R"((?:\s|>|/)[\s\S]*?>)", std::regex::icase);
    std::smatch m;
    if (std::regex_search(xml, m, re)) {
        return m[0].str();
    }
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

std::vector<std::string> payloadTags(const std::string& xml) {
    std::vector<std::string> out;
    const std::regex re(R"(<payload-type(?:\s|>)[\s\S]*?(?:/>|</payload-type>))", std::regex::icase);
    for (auto it = std::sregex_iterator(xml.begin(), xml.end(), re); it != std::sregex_iterator(); ++it) {
        out.push_back((*it)[0].str());
    }
    return out;
}

std::string toLower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return s;
}

bool parsePayloadTypeId(const std::string& id, std::uint8_t& out) {
    try {
        const int value = std::stoi(id);
        if (value < 0 || value > 127) {
            return false;
        }
        out = static_cast<std::uint8_t>(value);
        return true;
    } catch (...) {
        return false;
    }
}

bool startsWith(const std::string& s, const std::string& prefix) {
    return s.rfind(prefix, 0) == 0;
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


std::string resourceFromJid(const std::string& jid) {
    const auto slash = jid.rfind('/');
    if (slash != std::string::npos && slash + 1 < jid.size()) {
        return jid.substr(slash + 1);
    }
    return jid;
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

std::string endpointFromSourceName(const std::string& rawName) {
    std::string name = resourceFromJid(rawName);
    if (name.empty()) {
        return {};
    }

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

void appendUnique(std::vector<std::string>& values, const std::string& value) {
    if (value.empty() || isFallbackSsrcEndpoint(value)) {
        return;
    }

    if (std::find(values.begin(), values.end(), value) == values.end()) {
        values.push_back(value);
    }
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

std::vector<std::string> endpointsFromPresenceLikeXml(const std::string& xml) {
    std::vector<std::string> endpoints;

    const std::string presenceTag = firstTag(xml, "presence");
    const std::string fromEndpoint = resourceFromJid(attr(presenceTag, "from"));
    if (!fromEndpoint.empty() && fromEndpoint != "focus") {
        appendUnique(endpoints, fromEndpoint);
    }

    for (const auto& sourceName : sourceNamesFromSourceInfo(xml)) {
        appendUnique(endpoints, endpointFromSourceName(sourceName));
    }

    return endpoints;
}

std::string displayNameFromPresenceLikeXml(const std::string& xml) {
    std::string displayName = trimCopy(tagText(xml, "nick"));
    if (displayName.empty()) {
        displayName = trimCopy(tagText(xml, "display-name"));
    }

    if (displayName.empty()) {
        return {};
    }

    return JitsiSourceMap::sanitizeForNdiName(displayName);
}

struct ParsedPayloadTypes {
    std::set<std::uint8_t> opus;
    std::set<std::uint8_t> av1;
    std::set<std::uint8_t> vp8;
};

ParsedPayloadTypes parsePayloadTypesFromXml(const std::string& xml) {
    ParsedPayloadTypes parsed;

    for (const auto& content : contentBlocks(xml)) {
        const std::string contentTag = firstTag(content, "content");
        const std::string descriptionTag = firstTag(content, "description");
        std::string media = toLower(attr(descriptionTag, "media"));
        if (media.empty()) {
            media = toLower(attr(contentTag, "name"));
        }

        for (const auto& ptTag : payloadTags(content)) {
            std::uint8_t pt = 0;
            if (!parsePayloadTypeId(attr(ptTag, "id"), pt)) {
                continue;
            }

            const std::string codec = toLower(attr(ptTag, "name"));
            if ((media == "audio" || media.empty()) && codec == "opus") {
                parsed.opus.insert(pt);
            } else if ((media == "video" || media.empty()) && codec == "av1") {
                parsed.av1.insert(pt);
            } else if ((media == "video" || media.empty()) && codec == "vp8") {
                parsed.vp8.insert(pt);
            }
        }
    }

    return parsed;
}

std::string payloadSetToString(const std::set<std::uint8_t>& values) {
    std::string out;
    for (const auto value : values) {
        if (!out.empty()) {
            out += ",";
        }
        out += std::to_string(static_cast<int>(value));
    }
    return out.empty() ? "<none>" : out;
}

std::unordered_map<std::string, std::uint64_t> g_droppedUnsupportedVideoPackets;

} // namespace

PerParticipantNdiRouter::PerParticipantNdiRouter(std::string ndiBaseName)
    : ndiBaseName_(std::move(ndiBaseName)) {
    if (ndiBaseName_.empty()) {
        ndiBaseName_ = "JitsiNDI";
    }
}

PerParticipantNdiRouter::~PerParticipantNdiRouter() {
    std::vector<ParticipantPipeline*> toStop;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        toStop.reserve(pipelines_.size());
        for (auto& kv : pipelines_) {
            if (kv.second) {
                toStop.push_back(kv.second.get());
            }
        }
    }

    for (auto* pipeline : toStop) {
        if (pipeline) {
            stopVideoWorker(*pipeline);
        }
    }
}

void PerParticipantNdiRouter::removePipelineLocked(const std::string& key, const std::string& reason) {
    if (key.empty()) {
        return;
    }

    auto it = pipelines_.find(key);
    if (it == pipelines_.end()) {
        return;
    }

    const std::string sourceName = it->second && it->second->ndi
        ? it->second->ndi->sourceName()
        : std::string("<unknown>");

    Logger::info(
        "PerParticipantNdiRouter: removing stale NDI pipeline source=",
        sourceName,
        " endpoint=",
        key,
        " reason=",
        reason
    );

    if (it->second) {
        stopVideoWorker(*it->second);
    }

    pipelines_.erase(it);
}

void PerParticipantNdiRouter::removeEndpointPipelinesLocked(const std::string& endpointId, const std::string& reason) {
    if (endpointId.empty() || isFallbackSsrcEndpoint(endpointId)) {
        return;
    }

    for (auto it = pipelines_.begin(); it != pipelines_.end();) {
        const std::string& key = it->first;
        const bool belongsToEndpoint =
            key == endpointId ||
            startsWith(key, endpointId + "-") ||
            startsWith(key, endpointId + "_");

        if (!belongsToEndpoint) {
            ++it;
            continue;
        }

        const std::string sourceName = it->second && it->second->ndi
            ? it->second->ndi->sourceName()
            : std::string("<unknown>");

        Logger::info(
            "PerParticipantNdiRouter: removing endpoint NDI pipeline source=",
            sourceName,
            " endpoint=",
            key,
            " owner=",
            endpointId,
            " reason=",
            reason
        );

        if (it->second) {
            stopVideoWorker(*it->second);
        }

        it = pipelines_.erase(it);
    }
}

void PerParticipantNdiRouter::updateDisplayNameLifecycleFromXml(const std::string& xml) {
    const std::string displayName = displayNameFromPresenceLikeXml(xml);
    if (displayName.empty() || displayName == "unknown") {
        return;
    }

    const auto endpoints = endpointsFromPresenceLikeXml(xml);
    if (endpoints.empty()) {
        return;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& endpoint : endpoints) {
        auto it = displayNameByEndpoint_.find(endpoint);
        if (it != displayNameByEndpoint_.end() && it->second != displayName) {
            Logger::info(
                "PerParticipantNdiRouter: display name changed for endpoint=",
                endpoint,
                " old=",
                it->second,
                " new=",
                displayName,
                "; recycling NDI pipelines for this endpoint"
            );
            removeEndpointPipelinesLocked(endpoint, "display-name-changed");
        } else if (it == displayNameByEndpoint_.end()) {
            // v48: if RTP created a pipeline before the participant nick was known,
            // recycle it once when the nick arrives so NDI does not keep endpoint/ssrc-like names.
            removeEndpointPipelinesLocked(endpoint, "display-name-first-known");
        }

        displayNameByEndpoint_[endpoint] = displayName;
    }
}

void PerParticipantNdiRouter::handleParticipantUnavailableXml(const std::string& xml) {
    const auto endpoints = endpointsFromPresenceLikeXml(xml);
    if (endpoints.empty()) {
        return;
    }

    for (const auto& endpoint : endpoints) {
        sourceMap_.removeEndpoint(endpoint);
    }

    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& endpoint : endpoints) {
        displayNameByEndpoint_.erase(endpoint);
        removeEndpointPipelinesLocked(endpoint, "presence-unavailable");
    }
}

void PerParticipantNdiRouter::updateSourcesFromJingleXml(const std::string& xml) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        updatePayloadTypesFromJingleXmlLocked(xml);
    }

    updateDisplayNameLifecycleFromXml(xml);
    sourceMap_.updateDisplayNamesFromXml(xml);

    if (xml.find("<source") == std::string::npos) {
        return;
    }

    const auto parsedSources = JitsiSourceMap::parseSources(xml);
    sourceMap_.updateFromJingleXml(xml);

    // v48: do not pre-create NDI senders on source-add. A sender is created
    // only after the first real RTP packet for that exact source arrives.
    // Pre-creating from metadata caused duplicate/stale NDI sources such as
    // jvb video, camera/video placeholders, and renamed sources without media.
    (void)parsedSources;
}

void PerParticipantNdiRouter::removeSourcesFromJingleXml(const std::string& xml) {
    if (xml.find("<source") == std::string::npos) {
        return;
    }

    const auto removedSources = JitsiSourceMap::parseSources(xml);

    sourceMap_.removeFromJingleXml(xml);

    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& source : removedSources) {
        // Audio source-remove may simply mean mute/unmute and should not kill the camera NDI sender.
        // Video source-remove means camera/screen stopped or participant rejoined with new SSRCs;
        // recycle the old decoder/NDI sender so re-add can create a clean source.
        if (source.media != "video") {
            continue;
        }

        removePipelineLocked(pipelineKeyForLocked(source), "source-remove");
    }
}

void PerParticipantNdiRouter::updatePayloadTypesFromJingleXmlLocked(const std::string& xml) {
    const auto parsed = parsePayloadTypesFromXml(xml);
    bool changed = false;

    if (!parsed.opus.empty() && parsed.opus != opusPayloadTypes_) {
        opusPayloadTypes_ = parsed.opus;
        changed = true;
    }

    if (!parsed.av1.empty() && parsed.av1 != av1PayloadTypes_) {
        av1PayloadTypes_ = parsed.av1;
        changed = true;
    }

    if (!parsed.vp8.empty() && parsed.vp8 != vp8PayloadTypes_) {
        vp8PayloadTypes_ = parsed.vp8;
        changed = true;
    }

    if (changed) {
        Logger::info(
            "PerParticipantNdiRouter: payload types opus=",
            payloadSetToString(opusPayloadTypes_),
            " av1=",
            payloadSetToString(av1PayloadTypes_),
            " vp8=",
            payloadSetToString(vp8PayloadTypes_)
        );
    }
}

bool PerParticipantNdiRouter::isAcceptedOpusPayloadTypeLocked(std::uint8_t payloadType) const {
    return opusPayloadTypes_.empty() || opusPayloadTypes_.find(payloadType) != opusPayloadTypes_.end();
}

bool PerParticipantNdiRouter::isAcceptedAv1PayloadTypeLocked(std::uint8_t payloadType) const {
    return av1PayloadTypes_.find(payloadType) != av1PayloadTypes_.end();
}

bool PerParticipantNdiRouter::isAcceptedVp8PayloadTypeLocked(std::uint8_t payloadType) const {
    return vp8PayloadTypes_.find(payloadType) != vp8PayloadTypes_.end();
}

std::string PerParticipantNdiRouter::sourceNameFor(const JitsiSourceInfo& source) const {
    std::string label;

    const std::string endpoint = source.endpointId.empty()
        ? (source.displayName.empty() ? source.sourceName : source.displayName)
        : source.endpointId;

    const std::string videoType = toLower(source.videoType);

    std::string humanName;

    const auto nameIt = displayNameByEndpoint_.find(endpoint);
    if (nameIt != displayNameByEndpoint_.end() && !nameIt->second.empty()) {
        humanName = nameIt->second;
    }

    if (humanName.empty()) {
        humanName = source.displayName;
    }

    if (humanName.empty() || humanName == endpoint || isFallbackSsrcEndpoint(humanName)) {
        humanName = endpoint;
    }
    if (humanName.empty()) {
        humanName = !source.sourceName.empty() ? source.sourceName : "unknown";
    }

    if (source.media == "video") {
        // v28: NDI display name uses the participant nick/name, while the internal
        // pipeline key still remains the stable Jitsi source name, e.g. endpoint-v0/v1.
        label = humanName;

        if (videoType == "desktop" || videoType == "screen" || videoType == "screenshare") {
            label += " screen";
        } else if (videoType == "camera") {
            label += " camera";
        } else if (!videoType.empty()) {
            label += " " + videoType;
        } else {
            label += " video";
        }
    } else if (source.media == "audio") {
        // Audio is attached to the camera pipeline; if it creates the pipeline first,
        // it must get the same human-readable NDI source name as the later camera video.
        label = humanName + " camera";
    } else {
        label = humanName;
    }

    const std::string safe = JitsiSourceMap::sanitizeForNdiName(label);
    return ndiBaseName_ + " - " + safe;
}
std::string PerParticipantNdiRouter::pipelineKeyForLocked(const JitsiSourceInfo& source) const {
    std::string endpoint = source.endpointId.empty()
        ? (source.displayName.empty() ? source.sourceName : source.displayName)
        : source.endpointId;

    if (endpoint.empty()) {
        endpoint = source.displayName;
    }

    // v27: route each Jitsi video source into its own independent pipeline.
    // This prevents camera RTP and desktop-share RTP from sharing one AV1/VP8 assembler/decoder.
    if (source.media == "video") {
        if (!source.sourceName.empty()) {
            return source.sourceName;
        }

        const std::string videoType = toLower(source.videoType);
        if (!endpoint.empty() && !videoType.empty()) {
            return endpoint + "-" + videoType;
        }

        if (!endpoint.empty()) {
            return endpoint + "-video";
        }
    }

    // Audio belongs to the participant camera NDI source, not to the desktop-share source.
    // Normal Jitsi camera source name is endpoint-v0, so this matches the video pipeline key.
    if (source.media == "audio" && !endpoint.empty() && !isFallbackSsrcEndpoint(endpoint)) {
        return endpoint + "-v0";
    }

    // If audio has only an orphan SSRC key, attach it to the one already-created
    // non-fallback sender instead of making "JitsiNDI - ssrc-..." audio-only sources.
    if ((source.media == "audio" || endpoint.empty() || isFallbackSsrcEndpoint(endpoint)) && isFallbackSsrcEndpoint(endpoint)) {
        std::string stableKey;
        for (const auto& kv : pipelines_) {
            if (!isFallbackSsrcEndpoint(kv.first)) {
                if (!stableKey.empty()) {
                    return endpoint;
                }
                stableKey = kv.first;
            }
        }
        if (!stableKey.empty()) {
            return stableKey;
        }
    }

    return endpoint.empty() ? "unknown" : endpoint;
}
PerParticipantNdiRouter::ParticipantPipeline& PerParticipantNdiRouter::pipelineForLocked(
    const JitsiSourceInfo& source
) {
    const std::string key = pipelineKeyForLocked(source);

    auto it = pipelines_.find(key);

    if (it != pipelines_.end()) {
        return *it->second;
    }

    auto pipeline = std::make_unique<ParticipantPipeline>();

    pipeline->endpointId = key;
    pipeline->displayName = source.displayName;
    pipeline->ndi = std::make_unique<NDISender>(sourceNameFor(source));

    pipeline->ndi->start();

    Logger::info(
        "PerParticipantNdiRouter: created NDI participant source: ",
        pipeline->ndi->sourceName(),
        " endpoint=",
        key
    );

    startVideoWorkerLocked(*pipeline);

    auto* ptr = pipeline.get();
    pipelines_[key] = std::move(pipeline);

    return *ptr;
}


void PerParticipantNdiRouter::startVideoWorkerLocked(ParticipantPipeline& pipeline) {
    if (pipeline.videoWorkerStarted) {
        return;
    }

    pipeline.videoStopRequested = false;
    pipeline.videoWorkerStarted = true;
    pipeline.videoThread = std::thread(&PerParticipantNdiRouter::videoWorkerLoop, this, &pipeline);

    Logger::info(
        "PerParticipantNdiRouter: v93 per-source video worker started endpoint=",
        pipeline.endpointId
    );
}

void PerParticipantNdiRouter::stopVideoWorker(ParticipantPipeline& pipeline) {
    {
        std::lock_guard<std::mutex> lock(pipeline.videoQueueMutex);
        if (!pipeline.videoWorkerStarted) {
            pipeline.videoQueue.clear();
            return;
        }
        pipeline.videoStopRequested = true;
        pipeline.videoQueue.clear();
    }

    pipeline.videoQueueCv.notify_all();

    if (pipeline.videoThread.joinable()) {
        pipeline.videoThread.join();
    }

    {
        std::lock_guard<std::mutex> lock(pipeline.videoQueueMutex);
        pipeline.videoQueue.clear();
        pipeline.videoStopRequested = false;
        pipeline.videoWorkerStarted = false;
    }

    Logger::info(
        "PerParticipantNdiRouter: v93 per-source video worker stopped endpoint=",
        pipeline.endpointId,
        " processed=",
        pipeline.processedVideoRtp,
        " droppedQueued=",
        pipeline.droppedQueuedVideoRtp
    );
}

void PerParticipantNdiRouter::enqueueVideoRtpLocked(
    ParticipantPipeline& pipeline,
    const JitsiSourceInfo& source,
    const RtpPacketView& rtp,
    const std::uint8_t* data,
    std::size_t size,
    bool acceptedAv1,
    bool acceptedVp8
) {
    if (!data || size == 0) {
        return;
    }

    startVideoWorkerLocked(pipeline);

    QueuedVideoRtp queued{};
    queued.bytes.assign(data, data + size);
    queued.sourceName = source.sourceName;
    queued.videoType = source.videoType;
    queued.payloadType = rtp.payloadType;
    queued.ssrc = rtp.ssrc;
    queued.sequenceNumber = rtp.sequenceNumber;
    queued.timestamp = rtp.timestamp;
    queued.marker = rtp.marker;
    queued.acceptedAv1 = acceptedAv1;
    queued.acceptedVp8 = acceptedVp8;
    queued.packetIndex = pipeline.videoPackets;

    // Per-source queue, not global queue. If one camera/source is too heavy, only
    // that source drops old RTP and soft-resyncs; other cameras/screens keep moving.
    constexpr std::size_t kMaxVideoQueuePacketsPerSource = 260;
    constexpr std::size_t kTargetVideoQueuePacketsPerSource = 160;

    std::uint64_t droppedNow = 0;
    std::size_t queuedSize = 0;
    {
        std::lock_guard<std::mutex> lock(pipeline.videoQueueMutex);

        while (pipeline.videoQueue.size() >= kMaxVideoQueuePacketsPerSource) {
            pipeline.videoQueue.pop_front();
            ++pipeline.droppedQueuedVideoRtp;
            ++droppedNow;
            if (pipeline.videoQueue.size() <= kTargetVideoQueuePacketsPerSource) {
                break;
            }
        }

        pipeline.videoQueue.push_back(std::move(queued));
        queuedSize = pipeline.videoQueue.size();
    }

    if (droppedNow > 0) {
        Logger::warn(
            "PerParticipantNdiRouter: v93 source-local video queue overload endpoint=",
            pipeline.endpointId,
            " droppedOldRtp=",
            droppedNow,
            " totalDropped=",
            pipeline.droppedQueuedVideoRtp,
            " queued=",
            queuedSize,
            " source=",
            source.sourceName,
            " type=",
            source.videoType
        );
    }

    pipeline.videoQueueCv.notify_one();
}

void PerParticipantNdiRouter::videoWorkerLoop(ParticipantPipeline* pipeline) {
    if (!pipeline) {
        return;
    }

    for (;;) {
        QueuedVideoRtp packet;
        {
            std::unique_lock<std::mutex> lock(pipeline->videoQueueMutex);
            pipeline->videoQueueCv.wait(lock, [pipeline]() {
                return pipeline->videoStopRequested || !pipeline->videoQueue.empty();
            });

            if (pipeline->videoStopRequested && pipeline->videoQueue.empty()) {
                break;
            }

            packet = std::move(pipeline->videoQueue.front());
            pipeline->videoQueue.pop_front();
        }

        processQueuedVideoRtp(*pipeline, packet);
        ++pipeline->processedVideoRtp;
    }
}

void PerParticipantNdiRouter::processQueuedVideoRtp(ParticipantPipeline& p, const QueuedVideoRtp& packet) {
    if (packet.bytes.empty()) {
        return;
    }

    const auto rtp = RtpPacket::parse(packet.bytes.data(), packet.bytes.size());
    if (!rtp.valid || rtp.payloadSize == 0) {
        return;
    }

    if (packet.acceptedAv1) {
        const auto frames = p.av1.pushRtp(rtp);
        std::size_t decodedFrameCount = 0;

        for (const auto& encoded : frames) {
            const auto decodedFrames = p.av1Decoder.decode(encoded);
            decodedFrameCount += decodedFrames.size();

            for (const auto& decoded : decodedFrames) {
                p.ndi->sendVideoFrame(decoded, 30, 1);
            }
        }

        const auto now = std::chrono::steady_clock::now();
        if (decodedFrameCount > 0) {
            p.decodedAv1Frames += decodedFrameCount;
            p.av1EncodedUnitsWithoutDecodedFrame = 0;
            p.lastAv1DecodedFrameAt = now;
        } else if (!frames.empty() && p.decodedAv1Frames > 0) {
            ++p.av1EncodedUnitsWithoutDecodedFrame;

            const auto sinceDecodedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                now - p.lastAv1DecodedFrameAt
            ).count();
            const auto sinceResetMs = p.lastAv1SoftResetAt.time_since_epoch().count() == 0
                ? 1000000LL
                : std::chrono::duration_cast<std::chrono::milliseconds>(now - p.lastAv1SoftResetAt).count();

            /*
                v93: source-local decoder smoothing.
                When one camera temporarily stops producing decoded frames while RTP/AV1 temporal
                units still arrive, do not reconnect the whole conference. Flush only this source's
                FFmpeg AV1 decoder. This is deliberately conservative: it triggers after several
                encoded units and more than ~1.5 s since the last decoded frame, with a cooldown.
            */
            if (p.av1EncodedUnitsWithoutDecodedFrame >= 30 && sinceDecodedMs >= 1500 && sinceResetMs >= 3000) {
                ++p.av1DecoderSoftResets;
                Logger::warn(
                    "PerParticipantNdiRouter: v93 source-local AV1 decoder soft reset endpoint=",
                    p.endpointId,
                    " source=",
                    packet.sourceName,
                    " type=",
                    packet.videoType,
                    " noDecodedUnits=",
                    p.av1EncodedUnitsWithoutDecodedFrame,
                    " sinceDecodedMs=",
                    sinceDecodedMs,
                    " resets=",
                    p.av1DecoderSoftResets
                );
                p.av1Decoder.reset();
                p.av1EncodedUnitsWithoutDecodedFrame = 0;
                p.lastAv1SoftResetAt = now;
            }
        }

        if ((packet.packetIndex % 300) == 0 || !frames.empty()) {
            Logger::info(
                "PerParticipantNdiRouter: AV1 video packets endpoint=",
                p.endpointId,
                " count=",
                packet.packetIndex,
                " producedFrames=",
                frames.size(),
                " decodedFrames=",
                decodedFrameCount,
                " v93Worker=1"
            );
        }
        return;
    }

    if (!packet.acceptedVp8) {
        const std::string dropKey =
            p.endpointId + ":ssrc-" + RtpPacket::ssrcHex(rtp.ssrc) + ":pt-" + std::to_string(packet.payloadType);
        const auto dropped = ++g_droppedUnsupportedVideoPackets[dropKey];
        if (dropped == 1 || (dropped % 300) == 0) {
            Logger::warn(
                "PerParticipantNdiRouter: dropping unsupported non-AV1/non-VP8 video RTP endpoint=",
                p.endpointId,
                " ssrc=",
                RtpPacket::ssrcHex(rtp.ssrc),
                " pt=",
                static_cast<int>(packet.payloadType),
                " dropped=",
                dropped,
                " v93Worker=1"
            );
        }
        return;
    }

    auto encoded = p.vp8.push(rtp);
    if (encoded) {
        for (const auto& decoded : p.videoDecoder.decode(*encoded)) {
            p.ndi->sendVideoFrame(decoded, 30, 1);
        }
    }

    if ((packet.packetIndex % 300) == 0) {
        Logger::info(
            "PerParticipantNdiRouter: VP8 video packets endpoint=",
            p.endpointId,
            " count=",
            packet.packetIndex,
            " pt=",
            static_cast<int>(packet.payloadType),
            " v93Worker=1"
        );
    }
}

void PerParticipantNdiRouter::handleRtp(
    const std::string& mid,
    const std::uint8_t* data,
    std::size_t size
) {
    const auto rtp = RtpPacket::parse(data, size);

    if (!rtp.valid || rtp.payloadSize == 0) {
        return;
    }

    const std::uint8_t payloadType = readRtpPayloadType(data, size);

    if (mid == "video" && sourceMap_.isRtxSsrc(rtp.ssrc)) {
        const auto dropped = ++droppedRtxVideoPackets_;
        if (dropped == 1 || (dropped % 300) == 0) {
            Logger::warn(
                "PerParticipantNdiRouter: dropping RTX/retransmission video RTP ssrc=",
                RtpPacket::ssrcHex(rtp.ssrc),
                " pt=",
                static_cast<int>(payloadType),
                " dropped=",
                dropped
            );
        }
        return;
    }

    auto source = sourceMap_.lookup(rtp.ssrc);

    if (!source) {
        ++unknownSsrcPackets_;

        const bool haveKnownSources = !sourceMap_.allSources().empty();
        if (haveKnownSources) {
            if (unknownSsrcPackets_ == 1 || (unknownSsrcPackets_ % 200) == 0) {
                Logger::warn(
                    "PerParticipantNdiRouter: dropping unknown SSRC ",
                    RtpPacket::ssrcHex(rtp.ssrc),
                    " mid=",
                    mid,
                    " pt=",
                    static_cast<int>(payloadType),
                    "; known source map is present; not creating ssrc-* NDI placeholder"
                );
            }
            return;
        }

        // Emergency fallback only for very early sessions where the source map is
        // still empty. Once Jitsi has advertised any real source, unknown SSRCs
        // are usually RTX/JVB/late stale packets and must not create extra NDI inputs.
        JitsiSourceInfo fallback;
        fallback.ssrc = rtp.ssrc;
        fallback.media = (mid == "audio" || mid == "video") ? mid : "video";
        fallback.endpointId = std::string("ssrc-") + RtpPacket::ssrcHex(rtp.ssrc);
        fallback.displayName = fallback.endpointId;
        fallback.sourceName = fallback.endpointId + (fallback.media == "audio" ? "-a0" : "-v0");

        if (unknownSsrcPackets_ == 1 || (unknownSsrcPackets_ % 200) == 0) {
            Logger::warn(
                "PerParticipantNdiRouter: unknown SSRC ",
                RtpPacket::ssrcHex(rtp.ssrc),
                " mid=",
                mid,
                " pt=",
                static_cast<int>(payloadType),
                "; using emergency fallback endpoint=",
                fallback.endpointId
            );
        }

        source = fallback;
    }

    const std::string media = !source->media.empty() ? source->media : mid;

    if (startsWith(source->endpointId, "jvb") || startsWith(source->sourceName, "jvb")) {
        const auto dropped = ++droppedJvbAudioPackets_;
        if (dropped == 1 || (dropped % 200) == 0) {
            Logger::warn(
                "PerParticipantNdiRouter: dropping JVB/mixed placeholder RTP ssrc=",
                RtpPacket::ssrcHex(rtp.ssrc),
                " media=",
                media,
                " source=",
                source->sourceName,
                " endpoint=",
                source->endpointId,
                " dropped=",
                dropped
            );
        }
        return;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    auto& p = pipelineForLocked(*source);

    if (media == "audio" || mid == "audio") {
        ++p.audioPackets;

        if (!isAcceptedOpusPayloadTypeLocked(rtp.payloadType)) {
            const auto dropped = ++droppedNonOpusAudioPackets_;
            if (dropped == 1 || (dropped % 200) == 0) {
                Logger::warn(
                    "PerParticipantNdiRouter: dropping non-Opus audio RTP endpoint=",
                    p.endpointId,
                    " ssrc=",
                    RtpPacket::ssrcHex(rtp.ssrc),
                    " pt=",
                    static_cast<int>(rtp.payloadType),
                    " opusPts=",
                    payloadSetToString(opusPayloadTypes_),
                    " dropped=",
                    dropped
                );
            }
            return;
        }

        ++routedAudioPackets_;

        for (const auto& decoded : p.audioDecoder.decodeRtpPayload(
                 rtp.payload,
                 rtp.payloadSize,
                 rtp.timestamp
             )) {
            p.ndi->sendAudioFrame(decoded);
        }

        if ((p.audioPackets % 500) == 0) {
            Logger::info(
                "PerParticipantNdiRouter: audio packets endpoint=",
                p.endpointId,
                " count=",
                p.audioPackets,
                " pt=",
                static_cast<int>(rtp.payloadType)
            );
        }

        return;
    }

    if (media == "video" || mid == "video") {
        ++p.videoPackets;

        if (p.videoPackets <= 3 || (p.videoPackets % 300) == 0) {
            Logger::info(
                "PerParticipantNdiRouter: video RTP endpoint=",
                p.endpointId,
                " source=",
                source->sourceName,
                " type=",
                source->videoType,
                " pt=",
                static_cast<int>(rtp.payloadType),
                " marker=",
                static_cast<int>(rtp.marker),
                " payloadBytes=",
                rtp.payloadSize,
                " ssrc=",
                rtp.ssrc,
                " v93Queued=1"
            );
        }

        const bool acceptedAv1 = isAcceptedAv1PayloadTypeLocked(rtp.payloadType);
        const bool acceptedVp8 = isAcceptedVp8PayloadTypeLocked(rtp.payloadType);

        if (acceptedAv1 || acceptedVp8) {
            ++routedVideoPackets_;
        }

        enqueueVideoRtpLocked(
            p,
            *source,
            rtp,
            data,
            size,
            acceptedAv1,
            acceptedVp8
        );

        return;
    }
}
