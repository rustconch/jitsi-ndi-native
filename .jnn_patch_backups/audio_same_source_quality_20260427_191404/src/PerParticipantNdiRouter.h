#pragma once

#include "FfmpegMediaDecoder.h"
#include "Av1RtpFrameAssembler.h"
#include "JitsiSourceMap.h"
#include "NDISender.h"
#include "RtpPacket.h"
#include "Vp8RtpDepacketizer.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

class PerParticipantNdiRouter {
public:
    explicit PerParticipantNdiRouter(std::string ndiBaseName);
    ~PerParticipantNdiRouter();

    void updateSourcesFromJingleXml(const std::string& xml);
    void removeSourcesFromJingleXml(const std::string& xml);

    void handleRtp(const std::string& mid, const std::uint8_t* data, std::size_t size);

    std::uint64_t routedAudioPackets() const { return routedAudioPackets_; }
    std::uint64_t routedVideoPackets() const { return routedVideoPackets_; }
    std::uint64_t unknownSsrcPackets() const { return unknownSsrcPackets_; }

private:
    struct ParticipantPipeline {
        std::string endpointId;
        std::string displayName;
        std::unique_ptr<NDISender> ndi;
        Vp8RtpDepacketizer vp8;
        Av1RtpFrameAssembler av1;
        FfmpegVp8Decoder videoDecoder;

        FfmpegAv1Decoder av1Decoder;
        FfmpegOpusDecoder audioDecoder;
        std::uint64_t videoPackets = 0;
        std::uint64_t audioPackets = 0;
    };

    ParticipantPipeline& pipelineFor(const JitsiSourceInfo& source);
    std::string sourceNameFor(const JitsiSourceInfo& source) const;

    std::string ndiBaseName_;
    JitsiSourceMap sourceMap_;
    mutable std::mutex mutex_;
    std::unordered_map<std::string, std::unique_ptr<ParticipantPipeline>> pipelines_;

    std::uint64_t routedAudioPackets_ = 0;
    std::uint64_t routedVideoPackets_ = 0;
    std::uint64_t unknownSsrcPackets_ = 0;
};
