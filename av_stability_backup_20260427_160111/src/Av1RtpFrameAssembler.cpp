#include "Av1RtpFrameAssembler.h"

#include "Logger.h"

#include <utility>

void Av1RtpFrameAssembler::reset() {
    haveTimestamp_ = false;
    currentTimestamp_ = 0;

    haveSeq_ = false;
    lastSeq_ = 0;

    currentFrame_.clear();

    haveFragmentedObu_ = false;
    fragmentedObu_.clear();
}

std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::push(
    const std::uint8_t* payload,
    std::size_t payloadSize,
    std::uint16_t sequenceNumber,
    std::uint32_t timestamp,
    bool marker
) {
    std::vector<EncodedVideoFrame> out;

    if (!payload || payloadSize == 0) {
        return out;
    }

    if (haveSeq_) {
        const std::uint16_t expected = static_cast<std::uint16_t>(lastSeq_ + 1);

        if (sequenceNumber != expected) {
            ++sequenceGaps_;

            Logger::warn(
                "Av1RtpFrameAssembler: RTP sequence gap. expected=",
                expected,
                " got=",
                sequenceNumber,
                " gaps=",
                sequenceGaps_,
                ". Resetting current AV1 frame."
            );

            currentFrame_.clear();
            haveFragmentedObu_ = false;
            fragmentedObu_.clear();
        }
    }

    haveSeq_ = true;
    lastSeq_ = sequenceNumber;

    if (!haveTimestamp_) {
        haveTimestamp_ = true;
        currentTimestamp_ = timestamp;
    } else if (timestamp != currentTimestamp_) {
        auto flushed = flushCurrentFrame();

        out.insert(
            out.end(),
            std::make_move_iterator(flushed.begin()),
            std::make_move_iterator(flushed.end())
        );

        currentTimestamp_ = timestamp;
        currentFrame_.clear();
        haveFragmentedObu_ = false;
        fragmentedObu_.clear();
    }

    if (!appendAv1RtpPayload(payload, payloadSize)) {
        Logger::warn(
            "Av1RtpFrameAssembler: failed to parse AV1 RTP payload ts=",
            timestamp,
            " seq=",
            sequenceNumber,
            " size=",
            payloadSize
        );

        currentFrame_.clear();
        haveFragmentedObu_ = false;
        fragmentedObu_.clear();

        return out;
    }

    if (marker) {
        auto flushed = flushCurrentFrame();

        out.insert(
            out.end(),
            std::make_move_iterator(flushed.begin()),
            std::make_move_iterator(flushed.end())
        );
    }

    return out;
}

std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::flushCurrentFrame() {
    std::vector<EncodedVideoFrame> out;

    if (currentFrame_.empty()) {
        return out;
    }

    if (haveFragmentedObu_) {
        Logger::warn("Av1RtpFrameAssembler: frame boundary while fragmented OBU is still open; dropping partial OBU");
        haveFragmentedObu_ = false;
        fragmentedObu_.clear();
    }

    EncodedVideoFrame frame;

    /*
        This project's EncodedVideoFrame is expected to use:
            std::vector<std::uint8_t> data;
            std::uint32_t timestamp;

        If your local struct uses another field name, change only the next line.
    */
    frame.bytes = std::move(currentFrame_);
    frame.timestamp = currentTimestamp_;

    out.push_back(std::move(frame));

    currentFrame_.clear();

    ++producedFrames_;

    if ((producedFrames_ % 30) == 0 || producedFrames_ == 1) {
        Logger::info(
            "Av1RtpFrameAssembler: produced AV1 frames=",
            producedFrames_
        );
    }

    return out;
}

bool Av1RtpFrameAssembler::appendAv1RtpPayload(
    const std::uint8_t* payload,
    std::size_t payloadSize
) {
    if (!payload || payloadSize < 1) {
        return false;
    }

    /*
        AV1 RTP aggregation header:

            bit 7: Z - first OBU element continues an OBU from previous packet
            bit 6: Y - last OBU element continues in next packet
            bits 5..4: W - number of OBU elements if non-zero
            bit 3: N - starts new coded video sequence
            bits 2..0: reserved

        This byte is not part of the AV1 bitstream.
    */
    const std::uint8_t aggregationHeader = payload[0];

    const bool z = (aggregationHeader & 0x80) != 0;
    const bool y = (aggregationHeader & 0x40) != 0;
    const int w = static_cast<int>((aggregationHeader >> 4) & 0x03);

    const std::uint8_t* body = payload + 1;
    const std::size_t bodySize = payloadSize - 1;

    if (bodySize == 0) {
        return true;
    }

    struct ObuElementView {
        const std::uint8_t* data = nullptr;
        std::size_t size = 0;
    };

    std::vector<ObuElementView> elements;

    std::size_t pos = 0;

    if (w == 0) {
        /*
            W == 0: every OBU element has a LEB128 length prefix.
        */
        while (pos < bodySize) {
            std::uint64_t obuSize64 = 0;

            if (!readLeb128(body, bodySize, pos, obuSize64)) {
                return false;
            }

            if (obuSize64 > static_cast<std::uint64_t>(bodySize - pos)) {
                return false;
            }

            const auto obuSize = static_cast<std::size_t>(obuSize64);

            elements.push_back(ObuElementView{
                body + pos,
                obuSize
            });

            pos += obuSize;
        }
    } else {
        /*
            W == 1..3: packet contains W OBU elements.
            All except the last have LEB128 length.
            Last element consumes the remaining packet body.
        */
        for (int i = 0; i < w; ++i) {
            std::size_t obuSize = 0;

            if (i == w - 1) {
                obuSize = bodySize - pos;
            } else {
                std::uint64_t obuSize64 = 0;

                if (!readLeb128(body, bodySize, pos, obuSize64)) {
                    return false;
                }

                if (obuSize64 > static_cast<std::uint64_t>(bodySize - pos)) {
                    return false;
                }

                obuSize = static_cast<std::size_t>(obuSize64);
            }

            elements.push_back(ObuElementView{
                body + pos,
                obuSize
            });

            pos += obuSize;
        }

        if (pos != bodySize) {
            return false;
        }
    }

    for (std::size_t i = 0; i < elements.size(); ++i) {
        const bool first = i == 0;
        const bool last = i + 1 == elements.size();

        const bool continuesPreviousObu = first && z;
        const bool continuesInNextPacket = last && y;

        if (!appendObuElement(
                elements[i].data,
                elements[i].size,
                continuesPreviousObu,
                continuesInNextPacket
            )) {
            return false;
        }
    }

    return true;
}

bool Av1RtpFrameAssembler::appendObuElement(
    const std::uint8_t* data,
    std::size_t size,
    bool continuesPreviousObu,
    bool continuesInNextPacket
) {
    if (!data && size > 0) {
        return false;
    }

    if (continuesPreviousObu) {
        if (!haveFragmentedObu_) {
            Logger::warn("Av1RtpFrameAssembler: continuation fragment without previous AV1 fragment");
            return false;
        }

        fragmentedObu_.insert(
            fragmentedObu_.end(),
            data,
            data + size
        );

        if (!continuesInNextPacket) {
            const bool ok = appendCompletedObuForDecoder(
                fragmentedObu_.data(),
                fragmentedObu_.size()
            );

            haveFragmentedObu_ = false;
            fragmentedObu_.clear();

            return ok;
        }

        return true;
    }

    if (haveFragmentedObu_) {
        Logger::warn("Av1RtpFrameAssembler: new AV1 OBU while previous fragmented OBU is still open");
        haveFragmentedObu_ = false;
        fragmentedObu_.clear();
    }

    if (continuesInNextPacket) {
        haveFragmentedObu_ = true;
        fragmentedObu_.assign(data, data + size);
        return true;
    }

    return appendCompletedObuForDecoder(data, size);
}

bool Av1RtpFrameAssembler::appendCompletedObuForDecoder(
    const std::uint8_t* data,
    std::size_t size
) {
    if (!data || size == 0) {
        return true;
    }

    /*
        AV1 OBU header:
            bit 7: forbidden
            bits 6..3: obu_type
            bit 2: obu_extension_flag
            bit 1: obu_has_size_field
            bit 0: reserved

        RTP AV1 commonly carries OBUs without size fields.
        FFmpeg expects normal AV1 OBUs; adding size fields is the safest path.
    */
    const std::uint8_t obuHeader = data[0];

    const int obuType = static_cast<int>((obuHeader >> 3) & 0x0f);
    const bool hasExtension = (obuHeader & 0x04) != 0;
    const bool hasSizeField = (obuHeader & 0x02) != 0;

    /*
        Temporal delimiter OBU. Receiver can ignore it.
    */
    if (obuType == 2) {
        return true;
    }

    const std::size_t headerBytes = 1 + (hasExtension ? 1 : 0);

    if (size < headerBytes) {
        return false;
    }

    if (hasSizeField) {
        currentFrame_.insert(
            currentFrame_.end(),
            data,
            data + size
        );

        return true;
    }

    /*
        Rebuild OBU as:
            modified OBU header with obu_has_size_field = 1
            optional extension header
            leb128(obu_payload_size)
            OBU payload
    */
    const std::uint8_t fixedHeader = static_cast<std::uint8_t>(obuHeader | 0x02);

    currentFrame_.push_back(fixedHeader);

    std::size_t pos = 1;

    if (hasExtension) {
        currentFrame_.push_back(data[pos]);
        ++pos;
    }

    const std::uint64_t obuPayloadSize = static_cast<std::uint64_t>(size - pos);

    writeLeb128(obuPayloadSize, currentFrame_);

    currentFrame_.insert(
        currentFrame_.end(),
        data + pos,
        data + size
    );

    return true;
}

bool Av1RtpFrameAssembler::readLeb128(
    const std::uint8_t* data,
    std::size_t size,
    std::size_t& pos,
    std::uint64_t& value
) {
    value = 0;

    int shift = 0;

    for (int i = 0; i < 8 && pos < size; ++i) {
        const std::uint8_t b = data[pos++];

        value |= static_cast<std::uint64_t>(b & 0x7f) << shift;

        if ((b & 0x80) == 0) {
            return true;
        }

        shift += 7;
    }

    return false;
}

void Av1RtpFrameAssembler::writeLeb128(
    std::uint64_t value,
    std::vector<std::uint8_t>& out
) {
    do {
        std::uint8_t b = static_cast<std::uint8_t>(value & 0x7f);
        value >>= 7;

        if (value != 0) {
            b |= 0x80;
        }

        out.push_back(b);
    } while (value != 0);
}
