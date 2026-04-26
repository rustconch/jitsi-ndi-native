#pragma once

#include "RtpPacket.h"

#include <cstdint>
#include <optional>
#include <vector>

struct EncodedVideoFrame {
    std::uint32_t timestamp = 0;
    bool keyFrame = false;
    std::vector<std::uint8_t> bytes;
};

class Vp8RtpDepacketizer {
public:
    std::optional<EncodedVideoFrame> push(const RtpPacketView& rtp);
    void reset();

private:
    bool haveFrame_ = false;
    bool keyFrame_ = false;
    std::uint32_t timestamp_ = 0;
    std::uint16_t lastSeq_ = 0;
    std::vector<std::uint8_t> buffer_;
};
