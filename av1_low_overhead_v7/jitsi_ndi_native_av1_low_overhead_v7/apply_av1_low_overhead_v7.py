#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations

import datetime
import re
import shutil
import sys
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "src"
BACKUP = ROOT / ("av1_low_overhead_v7_backup_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))


def info(msg: str) -> None:
    print(f"[AV1_LOW_OVERHEAD_V7] {msg}")


def warn(msg: str) -> None:
    print(f"[AV1_LOW_OVERHEAD_V7] WARN: {msg}")


def die(msg: str) -> None:
    print(f"[AV1_LOW_OVERHEAD_V7] ERROR: {msg}")
    sys.exit(1)


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def write(p: Path, s: str) -> None:
    p.write_text(s, encoding="utf-8", newline="")


def backup(p: Path) -> None:
    if not p.exists():
        return
    dst = BACKUP / p.relative_to(ROOT)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(p, dst)


def find_encoded_video_frame_fields() -> tuple[str, str | None, str | None]:
    candidates = list(SRC.rglob("*.h")) + list(SRC.rglob("*.hpp"))
    body = None
    source = None
    for p in candidates:
        t = read(p)
        m = re.search(r"struct\s+EncodedVideoFrame\s*\{(?P<body>.*?)\};", t, re.S)
        if m:
            body = m.group("body")
            source = p
            break
        m = re.search(r"class\s+EncodedVideoFrame\s*\{(?P<body>.*?)\};", t, re.S)
        if m:
            body = m.group("body")
            source = p
            break

    if body is None:
        warn("EncodedVideoFrame definition not found; assuming payload/timestamp/keyFrame")
        return "payload", "timestamp", "keyFrame"

    vector_fields = re.findall(
        r"std::vector\s*<\s*(?:(?:std::)?u?int8_t|unsigned\s+char)\s*>\s+([A-Za-z_]\w*)",
        body,
    )
    payload_field = None
    for name in ["payload", "data", "bytes", "buffer", "encoded", "frame"]:
        if name in vector_fields:
            payload_field = name
            break
    if payload_field is None and vector_fields:
        payload_field = vector_fields[0]
    if payload_field is None:
        warn("No std::vector<uint8_t> field found in EncodedVideoFrame; using payload")
        payload_field = "payload"

    ts_field = None
    for name in ["timestamp", "rtpTimestamp", "timestamp90k", "pts", "pts90k"]:
        if re.search(r"\b" + re.escape(name) + r"\b", body):
            ts_field = name
            break

    key_field = None
    for name in ["keyFrame", "isKeyFrame", "keyframe", "is_keyframe"]:
        if re.search(r"\b" + re.escape(name) + r"\b", body):
            key_field = name
            break

    rel = source.relative_to(ROOT) if source else "<unknown>"
    info(f"Detected EncodedVideoFrame in {rel}: payload={payload_field}, timestamp={ts_field}, key={key_field}")
    return payload_field, ts_field, key_field


HEADER = r'''#pragma once
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

    std::uint64_t producedFrames_ = 0;
    std::uint64_t sequenceGaps_ = 0;
    std::uint64_t droppedUntilSequenceHeader_ = 0;
    std::uint64_t malformedPayloads_ = 0;
};
'''


CPP_TEMPLATE = r'''#include "Av1RtpFrameAssembler.h"
// AV1_LOW_OVERHEAD_V7

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
    sequenceGaps_ = 0;
    droppedUntilSequenceHeader_ = 0;
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
    if (!data || size == 0) return true;

    const std::uint8_t header = data[0];
    if ((header & 0x80) != 0 || (header & 0x01) != 0) {
        ++malformedPayloads_;
        if (malformedPayloads_ <= 5 || (malformedPayloads_ % 100) == 0) {
            Logger::warn(
                "Av1RtpFrameAssembler: malformed AV1 OBU header=",
                static_cast<int>(header),
                " size=", size,
                " malformed=", malformedPayloads_
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
    if (size < headerBytes) return false;

    std::vector<std::uint8_t> normalized;
    normalized.reserve(size + 8);

    if (hasSizeField) {
        normalized.insert(normalized.end(), data, data + size);
    } else {
        const std::uint8_t fixedHeader = static_cast<std::uint8_t>(header | 0x02);
        normalized.push_back(fixedHeader);
        std::size_t pos = 1;
        if (hasExtension) {
            normalized.push_back(data[pos]);
            ++pos;
        }
        writeLeb128(static_cast<std::uint64_t>(size - pos), normalized);
        normalized.insert(normalized.end(), data + pos, data + size);
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
    frame.__PAYLOAD_FIELD__ = std::move(packet);
__TS_SET____KEY_SET__    out.push_back(std::move(frame));

    decoderPrimed_ = true;
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
'''


def make_cpp(payload_field: str, ts_field: str | None, key_field: str | None) -> str:
    ts_set = f"    frame.{ts_field} = timestamp;\n" if ts_field else ""
    key_set = f"    frame.{key_field} = currentUnitKey_;\n" if key_field else ""
    return (CPP_TEMPLATE
        .replace("__PAYLOAD_FIELD__", payload_field)
        .replace("__TS_SET__", ts_set)
        .replace("__KEY_SET__", key_set))

def patch_router_log_spam() -> None:
    p = SRC / "PerParticipantNdiRouter.cpp"
    if not p.exists():
        return
    t = read(p)
    original = t
    t = t.replace("p.videoPackets <= 20 || (p.videoPackets % 300) == 0", "p.videoPackets <= 3 || (p.videoPackets % 300) == 0")
    if t != original:
        backup(p)
        write(p, t)
        info("reduced video RTP payload-type log spam in PerParticipantNdiRouter.cpp")


def main() -> None:
    if not SRC.exists():
        die(r"Run this from the project root, e.g. D:\MEDIA\Desktop\jitsi-ndi-native")

    h = SRC / "Av1RtpFrameAssembler.h"
    cpp = SRC / "Av1RtpFrameAssembler.cpp"
    if not h.exists() or not cpp.exists():
        die("src/Av1RtpFrameAssembler.h/.cpp not found. Apply the AV1 patch first, then this v7 patch.")

    BACKUP.mkdir(parents=True, exist_ok=True)
    payload_field, ts_field, key_field = find_encoded_video_frame_fields()

    backup(h)
    backup(cpp)
    write(h, HEADER)
    write(cpp, make_cpp(payload_field, ts_field, key_field))
    info("replaced Av1RtpFrameAssembler with low-overhead OBU assembler + sequence-header gate")

    patch_router_log_spam()

    info(f"backup folder: {BACKUP}")
    info("done. Rebuild with: cmake --build build --config Release")


if __name__ == "__main__":
    main()
