#pragma once

#include "FfmpegMediaDecoder.h"

#include <cstdint>
#include <optional>
#include <vector>

class Av1RtpFrameAssembler {
public:
    Av1RtpFrameAssembler() = default;

    std::vector<EncodedVideoFrame> push(
        const std::uint8_t* payload,
        std::size_t payloadSize,
        std::uint16_t sequenceNumber,
        std::uint32_t timestamp,
        bool marker
    );

    void reset();

private:
    std::vector<EncodedVideoFrame> flushCurrentFrame();

    bool appendAv1RtpPayload(
        const std::uint8_t* payload,
        std::size_t payloadSize
    );

    bool appendObuElement(
        const std::uint8_t* data,
        std::size_t size,
        bool continuesPreviousObu,
        bool continuesInNextPacket
    );

    bool appendCompletedObuForDecoder(
        const std::uint8_t* data,
        std::size_t size
    );

    static bool readLeb128(
        const std::uint8_t* data,
        std::size_t size,
        std::size_t& pos,
        std::uint64_t& value
    );

    static void writeLeb128(
        std::uint64_t value,
        std::vector<std::uint8_t>& out
    );

private:
    bool haveTimestamp_ = false;
    std::uint32_t currentTimestamp_ = 0;

    bool haveSeq_ = false;
    std::uint16_t lastSeq_ = 0;

    std::vector<std::uint8_t> currentFrame_;

    bool haveFragmentedObu_ = false;
    std::vector<std::uint8_t> fragmentedObu_;

    std::uint64_t droppedPackets_ = 0;
    std::uint64_t producedFrames_ = 0;
};