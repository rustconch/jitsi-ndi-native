#include "Av1RtpFrameAssembler.h"
// AV1_LOW_OVERHEAD_V80_LOSS_GATE

#include "Logger.h"

#include <algorithm>
#include <cstring>
#include <iterator>
#include <utility>

namespace {

constexpr std::size_t kMaxReorderPackets = 32;
constexpr std::uint8_t kAv1Z = 0x80;
constexpr std::uint8_t kAv1Y = 0x40;
constexpr std::uint8_t kAv1WMask = 0x30;
constexpr std::uint8_t kAv1N = 0x08;

constexpr int kObuSequenceHeader = 1;
constexpr int kObuTemporalDelimiter = 2;
constexpr int kObuFrameHeader = 3;
constexpr int kObuTileGroup = 4;
constexpr int kObuFrame = 6;
constexpr int kObuTileList = 8;
constexpr int kObuPadding = 15;

} // namespace

void Av1RtpFrameAssembler::reset() {
    reorder_.clear();
    haveExpectedSeq_ = false;
    expectedSeq_ = 0;
    haveTimestamp_ = false;
    currentTimestamp_ = 0;
    cachedSequenceHeaderObu_.clear();
    decoderPrimed_ = false;
    needKeyframeAfterLoss_ = false;
    sequenceGaps_ = 0;
    droppedUntilSequenceHeader_ = 0;
    droppedAfterLoss_ = 0;
    malformedPayloads_ = 0;
    clearCurrentUnit();
}

void Av1RtpFrameAssembler::clearCurrentUnit() {
    currentUnit_.clear();
    continuationObu_.clear();
    waitingContinuation_ = false;
    corruptUntilMarker_ = false;
    currentUnitHasSequenceHeader_ = false;
    currentUnitHasFrameData_ = false;
    currentUnitKey_ = false;
}

void Av1RtpFrameAssembler::markCorruptUntilMarker() {
    currentUnit_.clear();
    continuationObu_.clear();
    waitingContinuation_ = false;
    corruptUntilMarker_ = true;
    currentUnitHasSequenceHeader_ = false;
    currentUnitHasFrameData_ = false;
    currentUnitKey_ = false;

    // v80: after any RTP loss/corruption, do not feed cached-header delta
    // frames into dav1d. AV1 inter frames can depend on the missing temporal
    // unit and dav1d will spam "Error parsing frame header / OBU data" or
    // freeze until a real in-band sequence header/keyframe arrives.
    needKeyframeAfterLoss_ = true;
    decoderPrimed_ = false;
}

bool Av1RtpFrameAssembler::shouldEmitAfterLoss() const {
    if (!needKeyframeAfterLoss_) {
        return true;
    }

    // The AV1 RTP N bit is not enough by itself here. Require an in-band
    // sequence header in the current temporal unit before resuming the decoder.
    // Cached sequence headers are deliberately not accepted after packet loss.
    return currentUnitHasSequenceHeader_ && currentUnitHasFrameData_;
}

bool Av1RtpFrameAssembler::parseRtp(const std::uint8_t* data, std::size_t size, RtpPacket& out) {
    if (!data || size < 12) return false;
    const std::uint8_t vpxcc = data[0];
    if ((vpxcc >> 6) != 2) return false;
    const bool extension = (vpxcc & 0x10) != 0;
    const std::uint8_t csrcCount = static_cast<std::uint8_t>(vpxcc & 0x0F);
    std::size_t pos = 12 + static_cast<std::size_t>(csrcCount) * 4;
    if (pos > size) return false;

    out.marker = (data[1] & 0x80) != 0;
    out.sequence = static_cast<std::uint16_t>((static_cast<std::uint16_t>(data[2]) << 8) | data[3]);
    out.timestamp =
        (static_cast<std::uint32_t>(data[4]) << 24) |
        (static_cast<std::uint32_t>(data[5]) << 16) |
        (static_cast<std::uint32_t>(data[6]) << 8) |
        static_cast<std::uint32_t>(data[7]);

    if (extension) {
        if (pos + 4 > size) return false;
        const std::uint16_t extLenWords = static_cast<std::uint16_t>((static_cast<std::uint16_t>(data[pos + 2]) << 8) | data[pos + 3]);
        pos += 4 + static_cast<std::size_t>(extLenWords) * 4;
        if (pos > size) return false;
    }

    out.payload.assign(data + pos, data + size);
    return !out.payload.empty();
}

std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::pushRtp(const std::uint8_t* data, std::size_t size) {
    RtpPacket packet;
    if (!parseRtp(data, size, packet)) return {};
    return push(packet.payload.data(), packet.payload.size(), packet.sequence, packet.timestamp, packet.marker);
}

std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::push(
    const std::uint8_t* payload,
    std::size_t payloadSize,
    std::uint16_t sequenceNumber,
    std::uint32_t timestamp,
    bool marker
) {
    if (!payload || payloadSize == 0) return {};

    if (!haveExpectedSeq_) {
        haveExpectedSeq_ = true;
        expectedSeq_ = sequenceNumber;
    }

    if (reorder_.find(sequenceNumber) != reorder_.end()) return {};

    RtpPacket packet;
    packet.sequence = sequenceNumber;
    packet.timestamp = timestamp;
    packet.marker = marker;
    packet.payload.assign(payload, payload + payloadSize);
    reorder_.emplace(packet.sequence, std::move(packet));

    return drainReorderBuffer();
}

std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::drainReorderBuffer() {
    std::vector<EncodedVideoFrame> out;

    while (!reorder_.empty()) {
        auto it = reorder_.find(expectedSeq_);
        if (it == reorder_.end()) {
            if (reorder_.size() < kMaxReorderPackets) break;
            ++sequenceGaps_;
            Logger::warn("Av1RtpFrameAssembler: RTP sequence gap, skipping to next available packet. gaps=", sequenceGaps_);
            markCorruptUntilMarker();
            expectedSeq_ = reorder_.begin()->first;
            it = reorder_.find(expectedSeq_);
            if (it == reorder_.end()) break;
        }

        RtpPacket packet = std::move(it->second);
        reorder_.erase(it);
        expectedSeq_ = nextSeq(packet.sequence);
        auto frames = processOrderedPacket(packet);
        out.insert(out.end(), std::make_move_iterator(frames.begin()), std::make_move_iterator(frames.end()));
    }

    return out;
}

std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::processOrderedPacket(const RtpPacket& packet) {
    std::vector<EncodedVideoFrame> out;
    appendAv1Payload(packet.payload.data(), packet.payload.size(), packet.timestamp, packet.marker, out);
    return out;
}

bool Av1RtpFrameAssembler::appendAv1Payload(
    const std::uint8_t* data,
    std::size_t size,
    std::uint32_t timestamp,
    bool marker,
    std::vector<EncodedVideoFrame>& out
) {
    if (!data || size < 1) return false;

    if (haveTimestamp_ && timestamp != currentTimestamp_) {
        emitCurrentTemporalUnit(currentTimestamp_, out);
        clearCurrentUnit();
        currentTimestamp_ = timestamp;
    } else if (!haveTimestamp_) {
        haveTimestamp_ = true;
        currentTimestamp_ = timestamp;
    }

    if (corruptUntilMarker_) {
        if (marker) clearCurrentUnit();
        return false;
    }

    const std::uint8_t aggr = data[0];
    if ((aggr & 0x07) != 0) {
        ++malformedPayloads_;
        if (malformedPayloads_ <= 5 || (malformedPayloads_ % 100) == 0) {
            Logger::warn(
                "Av1RtpFrameAssembler: AV1 aggregation header has reserved bits set; payload may include unstripped RTP extension. aggr=",
                static_cast<int>(aggr),
                " malformed=", malformedPayloads_
            );
        }
    }

    const bool z = (aggr & kAv1Z) != 0;
    const bool y = (aggr & kAv1Y) != 0;
    const std::uint8_t w = static_cast<std::uint8_t>((aggr & kAv1WMask) >> 4);
    const bool n = (aggr & kAv1N) != 0;

    if (n) currentUnitKey_ = true;

    if (z && !waitingContinuation_) {
        markCorruptUntilMarker();
        if (marker) clearCurrentUnit();
        return false;
    }

    std::size_t pos = 1;
    std::size_t elementIndex = 0;

    while (pos < size) {
        ++elementIndex;
        std::size_t obuLen = 0;
        const bool lastElementByW = (w != 0 && elementIndex == static_cast<std::size_t>(w));

        if (w != 0 && lastElementByW) {
            obuLen = size - pos;
        } else {
            if (!readLeb128(data, size, pos, obuLen)) {
                markCorruptUntilMarker();
                return false;
            }
            if (obuLen > size - pos) {
                markCorruptUntilMarker();
                return false;
            }
        }

        const std::uint8_t* obuData = data + pos;
        pos += obuLen;

        const bool firstElement = elementIndex == 1;
        const bool lastElement = pos >= size || (w != 0 && elementIndex >= static_cast<std::size_t>(w));
        const bool continuesPreviousObu = firstElement && z;
        const bool continuesInNextPacket = lastElement && y;

        if (!appendObuElement(obuData, obuLen, continuesPreviousObu, continuesInNextPacket)) {
            markCorruptUntilMarker();
            return false;
        }

        if (w != 0 && elementIndex >= static_cast<std::size_t>(w)) break;
    }

    if (marker) {
        emitCurrentTemporalUnit(timestamp, out);
        clearCurrentUnit();
        haveTimestamp_ = false;
    }

    return true;
}

bool Av1RtpFrameAssembler::appendObuElement(
    const std::uint8_t* data,
    std::size_t size,
    bool continuesPreviousObu,
    bool continuesInNextPacket
) {
    if (!data && size > 0) return false;

    if (continuesPreviousObu) {
        if (!waitingContinuation_) return false;
        continuationObu_.insert(continuationObu_.end(), data, data + size);
        if (!continuesInNextPacket) {
            const bool ok = appendCompletedObu(continuationObu_.data(), continuationObu_.size());
            continuationObu_.clear();
            waitingContinuation_ = false;
            return ok;
        }
        return true;
    }

    if (waitingContinuation_) return false;

    if (continuesInNextPacket) {
        continuationObu_.assign(data, data + size);
        waitingContinuation_ = true;
        return true;
    }

    return appendCompletedObu(data, size);
}

bool Av1RtpFrameAssembler::appendCompletedObu(const std::uint8_t* data, std::size_t size) {
    if (!data || size == 0) {
        return true;
    }

    const std::uint8_t header = data[0];
    if ((header & 0x80) != 0 || (header & 0x01) != 0) {
        ++malformedPayloads_;
        if (malformedPayloads_ <= 5 || (malformedPayloads_ % 100) == 0) {
            Logger::warn(
                "Av1RtpFrameAssembler: malformed AV1 OBU header=",
                static_cast<int>(header),
                " size=",
                size,
                " malformed=",
                malformedPayloads_
            );
        }
        return false;
    }

    const int obuType = static_cast<int>((header >> 3) & 0x0f);
    const bool hasExtension = (header & 0x04) != 0;
    const bool hasSizeField = (header & 0x02) != 0;

    if (obuType == kObuTemporalDelimiter || obuType == kObuTileList || obuType == kObuPadding) {
        return true;
    }

    const std::size_t headerBytes = 1 + (hasExtension ? 1u : 0u);
    if (size < headerBytes) {
        return false;
    }

    // PATCH_V9_AV1_RESTORE_AUDIO_UNBLOCK:
    // FFmpeg/dav1d expects AV1 low-overhead OBUs with obu_has_size_field=1.
    // RTP AV1 payloads commonly omit the size field, and some senders keep the header bit
    // inconsistent. Normalize every OBU element into a self-contained low-overhead OBU.
    std::vector<std::uint8_t> normalized;
    normalized.reserve(size + 8);

    const std::uint8_t fixedHeader = static_cast<std::uint8_t>(header | 0x02);
    normalized.push_back(fixedHeader);

    std::size_t payloadPos = 1;
    if (hasExtension) {
        normalized.push_back(data[payloadPos]);
        ++payloadPos;
    }

    if (hasSizeField) {
        std::size_t afterLeb = payloadPos;
        std::size_t declaredPayloadSize = 0;
        if (readLeb128(data, size, afterLeb, declaredPayloadSize)) {
            const std::size_t declaredTotalSize = afterLeb + declaredPayloadSize;
            if (declaredTotalSize == size) {
                // A consistent obu_size field is already present. Preserve it.
                normalized.insert(normalized.end(), data + payloadPos, data + size);
            } else {
                // Header said size field was present, but the bytes do not describe this element.
                // Treat the element as RTP-style payload without a valid OBU size field.
                writeLeb128(static_cast<std::uint64_t>(size - payloadPos), normalized);
                normalized.insert(normalized.end(), data + payloadPos, data + size);
            }
        } else {
            writeLeb128(static_cast<std::uint64_t>(size - payloadPos), normalized);
            normalized.insert(normalized.end(), data + payloadPos, data + size);
        }
    } else {
        writeLeb128(static_cast<std::uint64_t>(size - payloadPos), normalized);
        normalized.insert(normalized.end(), data + payloadPos, data + size);
    }

    if (obuType == kObuSequenceHeader) {
        cachedSequenceHeaderObu_ = normalized;
        currentUnitHasSequenceHeader_ = true;
        currentUnitKey_ = true;
    }

    if (obuType == kObuFrameHeader || obuType == kObuTileGroup || obuType == kObuFrame) {
        currentUnitHasFrameData_ = true;
    }

    currentUnit_.insert(currentUnit_.end(), normalized.begin(), normalized.end());
    return true;
}

bool Av1RtpFrameAssembler::emitCurrentTemporalUnit(std::uint32_t timestamp, std::vector<EncodedVideoFrame>& out) {
    if (waitingContinuation_ || corruptUntilMarker_ || currentUnit_.empty() || !currentUnitHasFrameData_) {
        return false;
    }

    if (!shouldEmitAfterLoss()) {
        ++droppedAfterLoss_;
        if (droppedAfterLoss_ <= 20 || (droppedAfterLoss_ % 100) == 0) {
            Logger::warn(
                "Av1RtpFrameAssembler: dropping AV1 temporal unit after RTP loss until in-band sequence header/keyframe arrives. dropped=",
                droppedAfterLoss_
            );
        }
        return false;
    }

    if (!currentUnitHasSequenceHeader_ && cachedSequenceHeaderObu_.empty()) {
        ++droppedUntilSequenceHeader_;
        if (droppedUntilSequenceHeader_ <= 10 || (droppedUntilSequenceHeader_ % 100) == 0) {
            Logger::warn(
                "Av1RtpFrameAssembler: dropping AV1 temporal unit until sequence header/keyframe arrives. dropped=",
                droppedUntilSequenceHeader_
            );
        }
        return false;
    }

    std::vector<std::uint8_t> packet;
    packet.reserve(currentUnit_.size() + cachedSequenceHeaderObu_.size() + 8);

    packet.push_back(0x12); // temporal delimiter OBU with obu_has_size_field=1
    packet.push_back(0x00); // temporal delimiter payload size = 0

    if (!currentUnitHasSequenceHeader_ && !decoderPrimed_ && !cachedSequenceHeaderObu_.empty()) {
        packet.insert(packet.end(), cachedSequenceHeaderObu_.begin(), cachedSequenceHeaderObu_.end());
    }

    packet.insert(packet.end(), currentUnit_.begin(), currentUnit_.end());

    EncodedVideoFrame frame{};
    frame.bytes = std::move(packet);
    frame.timestamp = timestamp;
    frame.keyFrame = currentUnitKey_;
    out.push_back(std::move(frame));

    decoderPrimed_ = true;
    if (currentUnitHasSequenceHeader_) {
        needKeyframeAfterLoss_ = false;
    }
    ++producedFrames_;

    if (producedFrames_ == 1 || (producedFrames_ % 30) == 0) {
        Logger::info(
            "Av1RtpFrameAssembler: produced AV1 temporal units=",
            producedFrames_,
            " sequenceHeaderCached=", !cachedSequenceHeaderObu_.empty(),
            " key=", currentUnitKey_
        );
    }

    return true;
}

bool Av1RtpFrameAssembler::readLeb128(
    const std::uint8_t* data,
    std::size_t size,
    std::size_t& pos,
    std::size_t& value
) const {
    value = 0;
    unsigned shift = 0;
    while (pos < size && shift <= 56) {
        const std::uint8_t byte = data[pos++];
        value |= static_cast<std::size_t>(byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) return true;
        shift += 7;
    }
    return false;
}

void Av1RtpFrameAssembler::writeLeb128(std::uint64_t value, std::vector<std::uint8_t>& out) {
    do {
        std::uint8_t b = static_cast<std::uint8_t>(value & 0x7f);
        value >>= 7;
        if (value != 0) b |= 0x80;
        out.push_back(b);
    } while (value != 0);
}
