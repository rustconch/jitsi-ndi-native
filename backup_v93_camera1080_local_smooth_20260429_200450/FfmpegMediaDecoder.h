#pragma once

#include "DecodedMedia.h"
#include "Vp8RtpDepacketizer.h"

#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

class FfmpegVp8Decoder {
public:
    FfmpegVp8Decoder();
    ~FfmpegVp8Decoder();
    FfmpegVp8Decoder(const FfmpegVp8Decoder&) = delete;
    FfmpegVp8Decoder& operator=(const FfmpegVp8Decoder&) = delete;

    std::vector<DecodedVideoFrameBGRA> decode(const EncodedVideoFrame& frame);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

class FfmpegAv1Decoder {
public:
    FfmpegAv1Decoder();
    ~FfmpegAv1Decoder();
    FfmpegAv1Decoder(const FfmpegAv1Decoder&) = delete;
    FfmpegAv1Decoder& operator=(const FfmpegAv1Decoder&) = delete;

    std::vector<DecodedVideoFrameBGRA> decode(const EncodedVideoFrame& frame);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

class FfmpegOpusDecoder {
public:
    FfmpegOpusDecoder();
    ~FfmpegOpusDecoder();
    FfmpegOpusDecoder(const FfmpegOpusDecoder&) = delete;
    FfmpegOpusDecoder& operator=(const FfmpegOpusDecoder&) = delete;

    std::vector<DecodedAudioFrameFloat32Planar> decodeRtpPayload(
        const std::uint8_t* payload,
        std::size_t payloadSize,
        std::uint32_t rtpTimestamp
    );

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
