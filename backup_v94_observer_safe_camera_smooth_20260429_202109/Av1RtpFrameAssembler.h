#pragma once
// AV1_LOW_OVERHEAD_V7

#include "Vp8RtpDepacketizer.h"

#include <cstddef>
#include <cstdint>
#include <map>
#include <vector>

class Av1RtpFrameAssembler {
public:
    Av1RtpFrameAssembler() = default;

    std::vector<EncodedVideoFrame> pushRtp(const std::uint8_t* data, std::size_t size);
    std::vector<EncodedVideoFrame> pushRtp(const std::vector<std::uint8_t>& packet) {
        return pushRtp(packet.data(), packet.size());
    }

    std::vector<EncodedVideoFrame> push(
        const std::uint8_t* payload,
        std::size_t payloadSize,
        std::uint16_t sequenceNumber,
        std::uint32_t timestamp,
        bool marker
    );

    std::vector<EncodedVideoFrame> pushRtpPayload(
        std::uint16_t sequenceNumber,
        std::uint32_t timestamp,
        bool marker,
        const std::uint8_t* payload,
        std::size_t payloadSize
    ) {
        return push(payload, payloadSize, sequenceNumber, timestamp, marker);
    }

    template <typename RtpPacketLike>
    std::vector<EncodedVideoFrame> pushRtp(const RtpPacketLike& rtp) {
        return push(
            getPayload(rtp),
            getPayloadSize(rtp),
            static_cast<std::uint16_t>(getSequenceNumber(rtp)),
            static_cast<std::uint32_t>(getTimestamp(rtp)),
            static_cast<bool>(getMarker(rtp))
        );
    }

    std::vector<EncodedVideoFrame> depacketize(const std::uint8_t* data, std::size_t size) {
        return pushRtp(data, size);
    }
    std::vector<EncodedVideoFrame> depacketize(const std::vector<std::uint8_t>& packet) {
        return pushRtp(packet);
    }

    void reset();

    std::uint64_t producedFrames() const { return producedFrames_; }
    std::uint64_t droppedUntilSequenceHeader() const { return droppedUntilSequenceHeader_; }
    std::uint64_t sequenceGaps() const { return sequenceGaps_; }

private:
    struct RtpPacket {
        std::uint16_t sequence = 0;
        std::uint32_t timestamp = 0;
        bool marker = false;
        std::vector<std::uint8_t> payload;
    };

    std::vector<EncodedVideoFrame> drainReorderBuffer();
    std::vector<EncodedVideoFrame> processOrderedPacket(const RtpPacket& packet);

    bool parseRtp(const std::uint8_t* data, std::size_t size, RtpPacket& out);
    bool appendAv1Payload(const std::uint8_t* data, std::size_t size, std::uint32_t timestamp, bool marker, std::vector<EncodedVideoFrame>& out);
    bool appendObuElement(const std::uint8_t* data, std::size_t size, bool continuesPreviousObu, bool continuesInNextPacket);
    bool appendCompletedObu(const std::uint8_t* data, std::size_t size);
    bool emitCurrentTemporalUnit(std::uint32_t timestamp, std::vector<EncodedVideoFrame>& out);

    bool readLeb128(const std::uint8_t* data, std::size_t size, std::size_t& pos, std::size_t& value) const;
    static void writeLeb128(std::uint64_t value, std::vector<std::uint8_t>& out);

    void clearCurrentUnit();
    void markCorruptUntilMarker();
    static std::uint16_t nextSeq(std::uint16_t v) { return static_cast<std::uint16_t>(v + 1); }

private:
    template <typename T> static auto getPayloadImpl(const T& rtp, int) -> decltype(rtp.payload) { return rtp.payload; }
    template <typename T> static auto getPayloadImpl(const T& rtp, long) -> decltype(rtp.payloadData) { return rtp.payloadData; }
    template <typename T> static auto getPayloadImpl(const T& rtp, char) -> decltype(rtp.payloadPtr) { return rtp.payloadPtr; }
    template <typename T> static auto getPayloadImpl(const T& rtp, unsigned char) -> decltype(rtp.payloadStart) { return rtp.payloadStart; }
    template <typename T> static auto getPayloadImpl(const T& rtp, short) -> decltype(rtp.payloadBytes) { return rtp.payloadBytes; }

    template <typename T> static const std::uint8_t* getPayload(const T& rtp) {
        return reinterpret_cast<const std::uint8_t*>(getPayloadImpl(rtp, 0));
    }

    template <typename T> static auto getPayloadSizeImpl(const T& rtp, int) -> decltype(rtp.payloadSize) { return rtp.payloadSize; }
    template <typename T> static auto getPayloadSizeImpl(const T& rtp, long) -> decltype(rtp.payloadLength) { return rtp.payloadLength; }
    template <typename T> static auto getPayloadSizeImpl(const T& rtp, char) -> decltype(rtp.payloadLen) { return rtp.payloadLen; }

    template <typename T> static std::size_t getPayloadSize(const T& rtp) {
        return static_cast<std::size_t>(getPayloadSizeImpl(rtp, 0));
    }

    template <typename T> static auto getSequenceNumberImpl(const T& rtp, int) -> decltype(rtp.sequenceNumber) { return rtp.sequenceNumber; }
    template <typename T> static auto getSequenceNumberImpl(const T& rtp, long) -> decltype(rtp.sequence) { return rtp.sequence; }
    template <typename T> static auto getSequenceNumberImpl(const T& rtp, char) -> decltype(rtp.seq) { return rtp.seq; }
    template <typename T> static auto getSequenceNumberImpl(const T& rtp, unsigned char) -> decltype(rtp.seqNo) { return rtp.seqNo; }

    template <typename T> static std::uint16_t getSequenceNumber(const T& rtp) {
        return static_cast<std::uint16_t>(getSequenceNumberImpl(rtp, 0));
    }

    template <typename T> static auto getTimestampImpl(const T& rtp, int) -> decltype(rtp.timestamp) { return rtp.timestamp; }
    template <typename T> static auto getTimestampImpl(const T& rtp, long) -> decltype(rtp.rtpTimestamp) { return rtp.rtpTimestamp; }
    template <typename T> static auto getTimestampImpl(const T& rtp, char) -> decltype(rtp.ts) { return rtp.ts; }

    template <typename T> static std::uint32_t getTimestamp(const T& rtp) {
        return static_cast<std::uint32_t>(getTimestampImpl(rtp, 0));
    }

    template <typename T> static auto getMarkerImpl(const T& rtp, int) -> decltype(rtp.marker) { return rtp.marker; }
    template <typename T> static auto getMarkerImpl(const T& rtp, long) -> decltype(rtp.markerBit) { return rtp.markerBit; }
    template <typename T> static auto getMarkerImpl(const T& rtp, char) -> decltype(rtp.isMarker) { return rtp.isMarker; }

    template <typename T> static bool getMarker(const T& rtp) {
        return static_cast<bool>(getMarkerImpl(rtp, 0));
    }

private:
    std::map<std::uint16_t, RtpPacket> reorder_;
    bool haveExpectedSeq_ = false;
    std::uint16_t expectedSeq_ = 0;

    bool haveTimestamp_ = false;
    std::uint32_t currentTimestamp_ = 0;

    std::vector<std::uint8_t> currentUnit_;
    std::vector<std::uint8_t> continuationObu_;
    std::vector<std::uint8_t> cachedSequenceHeaderObu_;

    bool waitingContinuation_ = false;
    bool corruptUntilMarker_ = false;
    bool currentUnitHasSequenceHeader_ = false;
    bool currentUnitHasFrameData_ = false;
    bool currentUnitKey_ = false;
    bool decoderPrimed_ = false;
    bool needKeyframeAfterGap_ = false;
    std::uint64_t dependentDropsAfterGap_ = 0;

    std::uint64_t producedFrames_ = 0;
    std::uint64_t sequenceGaps_ = 0;
    std::uint64_t droppedUntilSequenceHeader_ = 0;
    std::uint64_t malformedPayloads_ = 0;
};
