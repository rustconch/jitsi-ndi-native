#include "RtpPacket.h"

#include <iomanip>
#include <sstream>

namespace {
std::uint16_t readU16(const std::uint8_t* p) {
    return static_cast<std::uint16_t>((static_cast<std::uint16_t>(p[0]) << 8) | p[1]);
}

std::uint32_t readU32(const std::uint8_t* p) {
    return (static_cast<std::uint32_t>(p[0]) << 24) |
           (static_cast<std::uint32_t>(p[1]) << 16) |
           (static_cast<std::uint32_t>(p[2]) << 8) |
            static_cast<std::uint32_t>(p[3]);
}
} // namespace

RtpPacketView RtpPacket::parse(const std::uint8_t* data, std::size_t size) {
    RtpPacketView out{};
    if (!data || size < 12) return out;

    const std::uint8_t v = data[0] >> 6;
    if (v != 2) return out;

    const bool padding = (data[0] & 0x20) != 0;
    const bool extension = (data[0] & 0x10) != 0;
    const std::uint8_t csrcCount = data[0] & 0x0F;

    std::size_t offset = 12 + static_cast<std::size_t>(csrcCount) * 4;
    if (size < offset) return out;

    if (extension) {
        if (size < offset + 4) return out;
        const std::uint16_t extLenWords = readU16(data + offset + 2);
        offset += 4 + static_cast<std::size_t>(extLenWords) * 4;
        if (size < offset) return out;
    }

    std::size_t payloadEnd = size;
    if (padding) {
        const std::uint8_t paddingBytes = data[size - 1];
        if (paddingBytes == 0 || paddingBytes > size - offset) return out;
        payloadEnd -= paddingBytes;
    }

    out.valid = true;
    out.marker = (data[1] & 0x80) != 0;
    out.payloadType = data[1] & 0x7F;
    out.sequenceNumber = readU16(data + 2);
    out.timestamp = readU32(data + 4);
    out.ssrc = readU32(data + 8);
    out.payload = data + offset;
    out.payloadSize = payloadEnd > offset ? payloadEnd - offset : 0;
    return out;
}

std::string RtpPacket::ssrcHex(std::uint32_t ssrc) {
    std::ostringstream oss;
    oss << "0x" << std::hex << std::uppercase << std::setw(8) << std::setfill('0') << ssrc;
    return oss.str();
}
