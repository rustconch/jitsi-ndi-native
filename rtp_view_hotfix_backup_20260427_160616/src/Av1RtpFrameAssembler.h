#pragma once

#include "Vp8RtpDepacketizer.h"

#include <cstddef>
#include <cstdint>
#include <map>
#include <vector>

class Av1RtpFrameAssembler {
public:
    std::vector<EncodedVideoFrame> pushRtp(const uint8_t* data, size_t size);
    std::vector<EncodedVideoFrame> pushRtp(const std::vector<uint8_t>& packet) {
        return pushRtp(packet.data(), packet.size());
    }

    // Compatibility aliases for older call sites.
    std::vector<EncodedVideoFrame> depacketize(const uint8_t* data, size_t size) {
        return pushRtp(data, size);
    }
    std::vector<EncodedVideoFrame> depacketize(const std::vector<uint8_t>& packet) {
        return pushRtp(packet);
    }

    uint64_t producedFrames() const { return producedFrames_; }
    uint64_t sequenceGaps() const { return sequenceGaps_; }

    void reset();

private:
    struct RtpPacket {
        uint16_t sequence = 0;
        uint32_t timestamp = 0;
        bool marker = false;
        std::vector<uint8_t> payload;
    };

    std::vector<EncodedVideoFrame> drainReorderBuffer();
    std::vector<EncodedVideoFrame> processOrderedPacket(const RtpPacket& packet);

    bool parseRtp(const uint8_t* data, size_t size, RtpPacket& out);
    bool appendAv1Payload(const uint8_t* data, size_t size, uint32_t timestamp, bool marker, std::vector<EncodedVideoFrame>& out);
    bool readLeb128(const uint8_t* data, size_t size, size_t& pos, size_t& value);
    void markCorruptUntilMarker();
    void clearCurrentFrameState();

    static uint16_t nextSeq(uint16_t v) { return static_cast<uint16_t>(v + 1); }

    std::map<uint16_t, RtpPacket> reorder_;
    bool haveExpectedSeq_ = false;
    uint16_t expectedSeq_ = 0;

    std::vector<uint8_t> currentFrame_;
    std::vector<uint8_t> continuationObu_;

    bool waitingContinuation_ = false;
    bool corruptFrame_ = false;
    bool haveFrameTimestamp_ = false;
    uint32_t frameTimestamp_ = 0;
    bool currentFrameKey_ = false;

    uint64_t producedFrames_ = 0;
    uint64_t sequenceGaps_ = 0;
};
