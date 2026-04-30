#pragma once

#include "FfmpegMediaDecoder.h"
#include "Av1RtpFrameAssembler.h"
#include "JitsiSourceMap.h"
#include "NDISender.h"
#include "RtpPacket.h"
#include "Vp8RtpDepacketizer.h"

#include <cstddef>
#include <cstdint>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

class PerParticipantNdiRouter {
public:
    explicit PerParticipantNdiRouter(std::string ndiBaseName);
    ~PerParticipantNdiRouter();

    void updateSourcesFromJingleXml(const std::string& xml);
    void removeSourcesFromJingleXml(const std::string& xml);
    void handleParticipantUnavailableXml(const std::string& xml);

    void handleRtp(const std::string& mid, const std::uint8_t* data, std::size_t size);

    std::uint64_t routedAudioPackets() const { return routedAudioPackets_; }
    std::uint64_t routedVideoPackets() const { return routedVideoPackets_; }
    std::uint64_t unknownSsrcPackets() const { return unknownSsrcPackets_; }

private:
    struct QueuedVideoRtp {
        std::vector<std::uint8_t> bytes;
        std::string sourceName;
        std::string videoType;
        std::uint8_t payloadType = 0;
        std::uint32_t ssrc = 0;
        std::uint16_t sequenceNumber = 0;
        std::uint32_t timestamp = 0;
        bool marker = false;
        bool acceptedAv1 = false;
        bool acceptedVp8 = false;
        std::uint64_t packetIndex = 0;
        std::chrono::steady_clock::time_point queuedAt{};
    };

    // v100: Opus payload deliberately small (~120-300 B) so a per-pipeline audio
    // worker can decode off the RTP receiver thread without holding the global
    // router mutex during avcodec_send_packet/receive_frame.
    struct QueuedAudioRtp {
        std::vector<std::uint8_t> payload;
        std::uint32_t timestamp = 0;
        std::uint8_t payloadType = 0;
        std::chrono::steady_clock::time_point queuedAt{};
    };

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

        std::mutex videoQueueMutex;
        std::condition_variable videoQueueCv;
        std::deque<QueuedVideoRtp> videoQueue;
        std::thread videoThread;
        bool videoStopRequested = false;
        bool videoWorkerStarted = false;
        std::uint64_t droppedQueuedVideoRtp = 0;
        std::uint64_t droppedStaleVideoRtp = 0;
        std::uint64_t processedVideoRtp = 0;
        std::uint64_t decodedAv1Frames = 0;
        std::uint64_t av1EncodedUnitsWithoutDecodedFrame = 0;
        std::uint64_t av1DecoderSoftResets = 0;
        std::uint64_t av1ConsecutiveSoftResets = 0;
        std::uint64_t av1WarmHardReprimes = 0;

        // v99: a same-device participant can arrive as a "cold" AV1 stream:
        // RTP assembles into temporal units, but dav1d never returns the first
        // decoded frame. Warm-stall recovery does not trigger in that case
        // because decodedAv1Frames is still zero, so keep separate counters.
        std::uint64_t av1ColdStartNoDecodeUnits = 0;
        std::uint64_t av1ColdStartDecoderResets = 0;
        std::uint64_t av1ColdStartAssemblerResets = 0;
        std::chrono::steady_clock::time_point firstAv1ColdNoDecodeAt{};
        std::chrono::steady_clock::time_point lastAv1ColdResetAt{};

        std::chrono::steady_clock::time_point lastAv1DecodedFrameAt{};
        std::chrono::steady_clock::time_point lastAv1SoftResetAt{};
        std::chrono::steady_clock::time_point lastAv1WarmHardReprimeAt{};

        // v100: per-pipeline audio worker so Opus decode no longer runs on the
        // libdatachannel RTP receiver thread under the router mutex.
        std::mutex audioQueueMutex;
        std::condition_variable audioQueueCv;
        std::deque<QueuedAudioRtp> audioQueue;
        std::thread audioThread;
        bool audioStopRequested = false;
        bool audioWorkerStarted = false;
        std::uint64_t droppedQueuedAudioRtp = 0;
        std::uint64_t droppedStaleAudioRtp = 0;
        std::uint64_t processedAudioRtp = 0;

        // v100: was a global std::unordered_map without synchronization; access from
        // multiple per-pipeline worker threads was a data race. Now scoped to the
        // pipeline (single owner thread = the video worker).
        std::unordered_map<std::string, std::uint64_t> droppedUnsupportedVideoByKey;
    };

    ParticipantPipeline& pipelineForLocked(const JitsiSourceInfo& source);
    std::string pipelineKeyForLocked(const JitsiSourceInfo& source) const;
    std::string sourceNameFor(const JitsiSourceInfo& source) const;
    void startVideoWorkerLocked(ParticipantPipeline& pipeline);
    void stopVideoWorker(ParticipantPipeline& pipeline);
    void enqueueVideoRtpLocked(
        ParticipantPipeline& pipeline,
        const JitsiSourceInfo& source,
        const RtpPacketView& rtp,
        const std::uint8_t* data,
        std::size_t size,
        bool acceptedAv1,
        bool acceptedVp8
    );
    void videoWorkerLoop(ParticipantPipeline* pipeline);
    void processQueuedVideoRtp(ParticipantPipeline& pipeline, const QueuedVideoRtp& packet);

    // v100: audio worker counterparts to the video pipeline above.
    void startAudioWorkerLocked(ParticipantPipeline& pipeline);
    void stopAudioWorker(ParticipantPipeline& pipeline);
    void enqueueAudioRtpLocked(
        ParticipantPipeline& pipeline,
        const RtpPacketView& rtp
    );
    void audioWorkerLoop(ParticipantPipeline* pipeline);
    void processQueuedAudioRtp(ParticipantPipeline& pipeline, const QueuedAudioRtp& packet);
    void removePipelineLocked(const std::string& key, const std::string& reason);
    void removeEndpointPipelinesLocked(const std::string& endpointId, const std::string& reason);
    void updateDisplayNameLifecycleFromXml(const std::string& xml);
    void updatePayloadTypesFromJingleXmlLocked(const std::string& xml);
    bool isAcceptedOpusPayloadTypeLocked(std::uint8_t payloadType) const;
    bool isAcceptedAv1PayloadTypeLocked(std::uint8_t payloadType) const;
    bool isAcceptedVp8PayloadTypeLocked(std::uint8_t payloadType) const;

    std::string ndiBaseName_;
    JitsiSourceMap sourceMap_;
    mutable std::mutex mutex_;
    std::unordered_map<std::string, std::unique_ptr<ParticipantPipeline>> pipelines_;
    std::unordered_map<std::string, std::string> displayNameByEndpoint_;

    std::set<std::uint8_t> opusPayloadTypes_{111};
    std::set<std::uint8_t> av1PayloadTypes_{41};
    std::set<std::uint8_t> vp8PayloadTypes_{100};

    std::uint64_t routedAudioPackets_ = 0;
    std::uint64_t routedVideoPackets_ = 0;
    std::uint64_t unknownSsrcPackets_ = 0;
    std::uint64_t droppedNonOpusAudioPackets_ = 0;
    std::uint64_t droppedJvbAudioPackets_ = 0;
    std::uint64_t droppedRtxVideoPackets_ = 0;
};
