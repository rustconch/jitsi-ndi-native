#pragma once

#include "FfmpegMediaDecoder.h"

#include <cstdint>
#include <cstddef>
#include <vector>

/*
    AV1 RTP depacketizer / frame assembler for Jitsi native receiver.

    It accepts raw RTP payload bytes AFTER the RTP header and rebuilds AV1 OBUs
    into an Annex-B-like AV1 bitstream that FFmpeg's AV1 decoder can consume.

    The RTP aggregation header is stripped.
    OBU size fields are reinserted when missing.
*/
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

    /*
        Convenience wrapper for your existing RtpPacketView/RtpPacket object.

        It supports common field names:
            payload / payloadData / payloadPtr / payloadStart
            payloadSize / payloadLength / payloadLen
            sequenceNumber / sequence / seq / seqNo
            timestamp
            marker
    */
    template <typename RtpPacketLike>
    std::vector<EncodedVideoFrame> pushRtp(const RtpPacketLike& rtp) {
        return push(
            getPayload(rtp),
            getPayloadSize(rtp),
            static_cast<std::uint16_t>(getSequenceNumber(rtp)),
            static_cast<std::uint32_t>(rtp.timestamp),
            static_cast<bool>(rtp.marker)
        );
    }

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
    template <typename T>
    static auto getPayloadImpl(const T& rtp, int) -> decltype(rtp.payload) {
        return rtp.payload;
    }

    template <typename T>
    static auto getPayloadImpl(const T& rtp, long) -> decltype(rtp.payloadData) {
        return rtp.payloadData;
    }

    template <typename T>
    static auto getPayloadImpl(const T& rtp, char) -> decltype(rtp.payloadPtr) {
        return rtp.payloadPtr;
    }

    template <typename T>
    static auto getPayloadImpl(const T& rtp, unsigned char) -> decltype(rtp.payloadStart) {
        return rtp.payloadStart;
    }

    template <typename T>
    static const std::uint8_t* getPayload(const T& rtp) {
        return reinterpret_cast<const std::uint8_t*>(getPayloadImpl(rtp, 0));
    }

    template <typename T>
    static auto getPayloadSizeImpl(const T& rtp, int) -> decltype(rtp.payloadSize) {
        return rtp.payloadSize;
    }

    template <typename T>
    static auto getPayloadSizeImpl(const T& rtp, long) -> decltype(rtp.payloadLength) {
        return rtp.payloadLength;
    }

    template <typename T>
    static auto getPayloadSizeImpl(const T& rtp, char) -> decltype(rtp.payloadLen) {
        return rtp.payloadLen;
    }

    template <typename T>
    static std::size_t getPayloadSize(const T& rtp) {
        return static_cast<std::size_t>(getPayloadSizeImpl(rtp, 0));
    }

    template <typename T>
    static auto getSequenceNumberImpl(const T& rtp, int) -> decltype(rtp.sequenceNumber) {
        return rtp.sequenceNumber;
    }

    template <typename T>
    static auto getSequenceNumberImpl(const T& rtp, long) -> decltype(rtp.sequence) {
        return rtp.sequence;
    }

    template <typename T>
    static auto getSequenceNumberImpl(const T& rtp, char) -> decltype(rtp.seq) {
        return rtp.seq;
    }

    template <typename T>
    static auto getSequenceNumberImpl(const T& rtp, unsigned char) -> decltype(rtp.seqNo) {
        return rtp.seqNo;
    }

    template <typename T>
    static std::uint16_t getSequenceNumber(const T& rtp) {
        return static_cast<std::uint16_t>(getSequenceNumberImpl(rtp, 0));
    }

private:
    bool haveTimestamp_ = false;
    std::uint32_t currentTimestamp_ = 0;

    bool haveSeq_ = false;
    std::uint16_t lastSeq_ = 0;

    std::vector<std::uint8_t> currentFrame_;

    bool haveFragmentedObu_ = false;
    std::vector<std::uint8_t> fragmentedObu_;

    std::uint64_t sequenceGaps_ = 0;
    std::uint64_t producedFrames_ = 0;
};
