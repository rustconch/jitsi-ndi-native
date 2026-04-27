#include "Av1RtpFrameAssembler.h"

#include <algorithm>
#include <cstring>

namespace {

constexpr size_t kMaxReorderPackets = 8;
constexpr uint8_t kAv1Z = 0x80;
constexpr uint8_t kAv1Y = 0x40;
constexpr uint8_t kAv1WMask = 0x30;
constexpr uint8_t kAv1N = 0x08;

} // namespace

void Av1RtpFrameAssembler::reset() {
    reorder_.clear();
    haveExpectedSeq_ = false;
    expectedSeq_ = 0;
    clearCurrentFrameState();
    sequenceGaps_ = 0;
}

void Av1RtpFrameAssembler::clearCurrentFrameState() {
    currentFrame_.clear();
    continuationObu_.clear();
    waitingContinuation_ = false;
    corruptFrame_ = false;
    haveFrameTimestamp_ = false;
    frameTimestamp_ = 0;
    currentFrameKey_ = false;
}

void Av1RtpFrameAssembler::markCorruptUntilMarker() {
    currentFrame_.clear();
    continuationObu_.clear();
    waitingContinuation_ = false;
    corruptFrame_ = true;
}

bool Av1RtpFrameAssembler::parseRtp(const uint8_t* data, size_t size, RtpPacket& out) {
    if (!data || size < 12) return false;
    const uint8_t vpxcc = data[0];
    if ((vpxcc >> 6) != 2) return false;
    const bool extension = (vpxcc & 0x10) != 0;
    const uint8_t csrcCount = static_cast<uint8_t>(vpxcc & 0x0F);
    size_t pos = 12 + static_cast<size_t>(csrcCount) * 4;
    if (pos > size) return false;

    out.marker = (data[1] & 0x80) != 0;
    out.sequence = static_cast<uint16_t>((static_cast<uint16_t>(data[2]) << 8) | data[3]);
    out.timestamp =
        (static_cast<uint32_t>(data[4]) << 24) |
        (static_cast<uint32_t>(data[5]) << 16) |
        (static_cast<uint32_t>(data[6]) << 8) |
        static_cast<uint32_t>(data[7]);

    if (extension) {
        if (pos + 4 > size) return false;
        const uint16_t extLenWords = static_cast<uint16_t>((static_cast<uint16_t>(data[pos + 2]) << 8) | data[pos + 3]);
        pos += 4 + static_cast<size_t>(extLenWords) * 4;
        if (pos > size) return false;
    }

    out.payload.assign(data + pos, data + size);
    return !out.payload.empty();
}

std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::pushRtp(const uint8_t* data, size_t size) {
    RtpPacket packet;
    if (!parseRtp(data, size, packet)) return {};

    if (!haveExpectedSeq_) {
        haveExpectedSeq_ = true;
        expectedSeq_ = packet.sequence;
    }

    if (reorder_.find(packet.sequence) != reorder_.end()) return {};
    reorder_.emplace(packet.sequence, std::move(packet));
    return drainReorderBuffer();
}


std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::pushRtpPayload(
    uint16_t sequence,
    uint32_t timestamp,
    bool marker,
    const uint8_t* payload,
    size_t payloadSize) {

    if (!payload || payloadSize == 0) {
        return {};
    }

    if (!haveExpectedSeq_) {
        haveExpectedSeq_ = true;
        expectedSeq_ = sequence;
    }

    if (reorder_.find(sequence) != reorder_.end()) {
        return {};
    }

    RtpPacket packet;
    packet.sequence = sequence;
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
            markCorruptUntilMarker();
            expectedSeq_ = reorder_.begin()->first;
            it = reorder_.find(expectedSeq_);
            if (it == reorder_.end()) break;
        }

        RtpPacket packet = std::move(it->second);
        reorder_.erase(it);
        expectedSeq_ = nextSeq(packet.sequence);
        auto frames = processOrderedPacket(packet);
        out.insert(out.end(), frames.begin(), frames.end());
    }
    return out;
}

std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::processOrderedPacket(const RtpPacket& packet) {
    std::vector<EncodedVideoFrame> out;
    appendAv1Payload(packet.payload.data(), packet.payload.size(), packet.timestamp, packet.marker, out);
    return out;
}

bool Av1RtpFrameAssembler::readLeb128(const uint8_t* data, size_t size, size_t& pos, size_t& value) {
    value = 0;
    unsigned shift = 0;
    while (pos < size && shift <= 28) {
        const uint8_t byte = data[pos++];
        value |= static_cast<size_t>(byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) return true;
        shift += 7;
    }
    return false;
}

bool Av1RtpFrameAssembler::appendAv1Payload(const uint8_t* data, size_t size, uint32_t timestamp, bool marker, std::vector<EncodedVideoFrame>& out) {
    if (!data || size < 1) return false;

    if (haveFrameTimestamp_ && timestamp != frameTimestamp_) {
        clearCurrentFrameState();
    }
    if (!haveFrameTimestamp_) {
        haveFrameTimestamp_ = true;
        frameTimestamp_ = timestamp;
    }

    if (corruptFrame_) {
        if (marker) clearCurrentFrameState();
        return false;
    }

    const uint8_t aggr = data[0];
    const bool z = (aggr & kAv1Z) != 0;
    const bool y = (aggr & kAv1Y) != 0;
    const uint8_t w = static_cast<uint8_t>((aggr & kAv1WMask) >> 4);
    const bool n = (aggr & kAv1N) != 0;
    if (n) currentFrameKey_ = true;

    size_t pos = 1;
    size_t elementIndex = 0;

    if (z && !waitingContinuation_) {
        markCorruptUntilMarker();
        if (marker) clearCurrentFrameState();
        return false;
    }

    while (pos < size) {
        ++elementIndex;
        size_t obuLen = 0;
        const bool lastElement = (w != 0 && elementIndex == static_cast<size_t>(w));

        if (w != 0 && lastElement) {
            obuLen = size - pos;
        } else {
            if (!readLeb128(data, size, pos, obuLen)) { markCorruptUntilMarker(); return false; }
            if (obuLen > size - pos) { markCorruptUntilMarker(); return false; }
        }

        const uint8_t* obuData = data + pos;
        pos += obuLen;
        const bool thisElementContinues = y && (pos >= size);

        if ((z && elementIndex == 1) || waitingContinuation_) {
            continuationObu_.insert(continuationObu_.end(), obuData, obuData + obuLen);
            if (!thisElementContinues) {
                currentFrame_.insert(currentFrame_.end(), continuationObu_.begin(), continuationObu_.end());
                continuationObu_.clear();
                waitingContinuation_ = false;
            } else {
                waitingContinuation_ = true;
            }
        } else {
            if (thisElementContinues) {
                continuationObu_.assign(obuData, obuData + obuLen);
                waitingContinuation_ = true;
            } else {
                currentFrame_.insert(currentFrame_.end(), obuData, obuData + obuLen);
            }
        }

        if (w != 0 && elementIndex >= static_cast<size_t>(w)) break;
    }

    if (marker) {
        if (!waitingContinuation_ && !currentFrame_.empty() && !corruptFrame_) {
            EncodedVideoFrame frame{};
            frame.bytes = std::move(currentFrame_);
    frame.timestamp = timestamp;
    frame.keyFrame = currentFrameKey_;
            out.push_back(std::move(frame));
            ++producedFrames_;
        }
        clearCurrentFrameState();
    }
    return true;
}
