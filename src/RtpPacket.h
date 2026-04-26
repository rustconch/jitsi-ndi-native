#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

struct RtpPacketView {
    bool valid = false;
    bool marker = false;
    std::uint8_t payloadType = 0;
    std::uint16_t sequenceNumber = 0;
    std::uint32_t timestamp = 0;
    std::uint32_t ssrc = 0;
    const std::uint8_t* payload = nullptr;
    std::size_t payloadSize = 0;
};

class RtpPacket {
public:
    static RtpPacketView parse(const std::uint8_t* data, std::size_t size);
    static std::string ssrcHex(std::uint32_t ssrc);
};
