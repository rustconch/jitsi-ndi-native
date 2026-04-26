#include "Vp8RtpDepacketizer.h"

namespace {
struct Vp8PayloadDescriptor {
    bool ok = false;
    bool startOfPartition = false;
    std::uint8_t partitionId = 0;
    std::size_t headerSize = 0;
};

Vp8PayloadDescriptor parseVp8PayloadDescriptor(const std::uint8_t* p, std::size_t size) {
    Vp8PayloadDescriptor d{};
    if (!p || size < 1) return d;

    const bool x = (p[0] & 0x80) != 0;
    d.startOfPartition = (p[0] & 0x10) != 0;
    d.partitionId = p[0] & 0x0F;
    d.headerSize = 1;

    if (x) {
        if (size < d.headerSize + 1) return {};
        const std::uint8_t ext = p[d.headerSize++];
        const bool i = (ext & 0x80) != 0;
        const bool l = (ext & 0x40) != 0;
        const bool t = (ext & 0x20) != 0;
        const bool k = (ext & 0x10) != 0;

        if (i) {
            if (size < d.headerSize + 1) return {};
            const bool pictureId16 = (p[d.headerSize] & 0x80) != 0;
            d.headerSize += pictureId16 ? 2 : 1;
        }
        if (l) d.headerSize += 1;
        if (t || k) d.headerSize += 1;
        if (size < d.headerSize) return {};
    }

    d.ok = true;
    return d;
}

bool isVp8KeyFrame(const std::vector<std::uint8_t>& frame) {
    if (frame.size() < 10) return false;
    // First bit of first VP8 payload byte: 0 = key frame, 1 = interframe.
    return (frame[0] & 0x01) == 0;
}
} // namespace

std::optional<EncodedVideoFrame> Vp8RtpDepacketizer::push(const RtpPacketView& rtp) {
    if (!rtp.valid || !rtp.payload || rtp.payloadSize == 0) return std::nullopt;
    const auto desc = parseVp8PayloadDescriptor(rtp.payload, rtp.payloadSize);
    if (!desc.ok || desc.headerSize >= rtp.payloadSize) return std::nullopt;

    const bool startsFrame = desc.startOfPartition && desc.partitionId == 0;
    if (startsFrame) {
        haveFrame_ = true;
        timestamp_ = rtp.timestamp;
        lastSeq_ = rtp.sequenceNumber;
        buffer_.clear();
        keyFrame_ = false;
    } else if (!haveFrame_) {
        return std::nullopt;
    } else {
        const std::uint16_t expected = static_cast<std::uint16_t>(lastSeq_ + 1);
        if (rtp.sequenceNumber != expected && rtp.timestamp == timestamp_) {
            reset();
            return std::nullopt;
        }
        lastSeq_ = rtp.sequenceNumber;
    }

    if (rtp.timestamp != timestamp_) {
        reset();
        return std::nullopt;
    }

    buffer_.insert(buffer_.end(), rtp.payload + desc.headerSize, rtp.payload + rtp.payloadSize);

    if (!rtp.marker) return std::nullopt;

    EncodedVideoFrame frame;
    frame.timestamp = timestamp_;
    frame.bytes = std::move(buffer_);
    frame.keyFrame = isVp8KeyFrame(frame.bytes);
    reset();
    return frame;
}

void Vp8RtpDepacketizer::reset() {
    haveFrame_ = false;
    keyFrame_ = false;
    timestamp_ = 0;
    lastSeq_ = 0;
    buffer_.clear();
}
