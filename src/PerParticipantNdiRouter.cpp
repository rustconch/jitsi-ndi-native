#include "PerParticipantNdiRouter.h"

#include "Logger.h"

#include <utility>

PerParticipantNdiRouter::PerParticipantNdiRouter(std::string ndiBaseName)
    : ndiBaseName_(std::move(ndiBaseName)) {
    if (ndiBaseName_.empty()) ndiBaseName_ = "JitsiNDI";
}

PerParticipantNdiRouter::~PerParticipantNdiRouter() = default;

void PerParticipantNdiRouter::updateSourcesFromJingleXml(const std::string& xml) {
    if (xml.find("<source") == std::string::npos) return;
    sourceMap_.updateFromJingleXml(xml);
}

void PerParticipantNdiRouter::removeSourcesFromJingleXml(const std::string& xml) {
    if (xml.find("<source") == std::string::npos) return;
    sourceMap_.removeFromJingleXml(xml);
}

std::string PerParticipantNdiRouter::sourceNameFor(const JitsiSourceInfo& source) const {
    const std::string safe = JitsiSourceMap::sanitizeForNdiName(source.displayName.empty() ? source.endpointId : source.displayName);
    return ndiBaseName_ + " - " + safe;
}

PerParticipantNdiRouter::ParticipantPipeline& PerParticipantNdiRouter::pipelineFor(const JitsiSourceInfo& source) {
    const std::string key = source.endpointId.empty() ? source.displayName : source.endpointId;
    auto it = pipelines_.find(key);
    if (it != pipelines_.end()) return *it->second;

    auto pipeline = std::make_unique<ParticipantPipeline>();
    pipeline->endpointId = key;
    pipeline->displayName = source.displayName;
    pipeline->ndi = std::make_unique<NDISender>(sourceNameFor(source));
    pipeline->ndi->start();
    Logger::info("PerParticipantNdiRouter: created NDI participant source: ", pipeline->ndi->sourceName());

    auto* ptr = pipeline.get();
    pipelines_[key] = std::move(pipeline);
    return *ptr;
}

void PerParticipantNdiRouter::handleRtp(const std::string& mid, const std::uint8_t* data, std::size_t size) {
    const auto rtp = RtpPacket::parse(data, size);
    if (!rtp.valid || rtp.payloadSize == 0) return;

    auto source = sourceMap_.lookup(rtp.ssrc);
    if (!source) {
        ++unknownSsrcPackets_;
        if ((unknownSsrcPackets_ % 500) == 0) {
            Logger::warn("PerParticipantNdiRouter: unknown SSRC ", RtpPacket::ssrcHex(rtp.ssrc), " mid=", mid);
        }
        return;
    }

    const std::string media = !source->media.empty() ? source->media : mid;

    std::lock_guard<std::mutex> lock(mutex_);
    auto& p = pipelineFor(*source);

    if (media == "audio" || mid == "audio") {
        ++p.audioPackets;
        ++routedAudioPackets_;
        for (const auto& decoded : p.audioDecoder.decodeRtpPayload(rtp.payload, rtp.payloadSize, rtp.timestamp)) {
            p.ndi->sendAudioFrame(decoded);
        }
        if ((p.audioPackets % 500) == 0) {
            Logger::info("PerParticipantNdiRouter: audio packets endpoint=", p.endpointId, " count=", p.audioPackets);
        }
        return;
    }

    if (media == "video" || mid == "video") {
        ++p.videoPackets;
        ++routedVideoPackets_;
        auto encoded = p.vp8.push(rtp);
        if (encoded) {
            for (const auto& decoded : p.videoDecoder.decode(*encoded)) {
                p.ndi->sendVideoFrame(decoded, 30, 1);
            }
        }
        if ((p.videoPackets % 300) == 0) {
            Logger::info("PerParticipantNdiRouter: video packets endpoint=", p.endpointId, " count=", p.videoPackets);
        }
        return;
    }
}
