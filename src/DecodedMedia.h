#pragma once

#include <cstdint>
#include <vector>

// v102: pixel format carried alongside the frame data so NDISender can choose
// the correct FourCC without any additional conversion.
enum class VideoPixelFormat : std::uint8_t {
    // 4 bytes/pixel, B G R A order. Used as fallback for unusual source formats.
    BGRA,
    // YUV 4:2:0 planar (same as AV_PIX_FMT_YUV420P).
    // Layout: Y plane (width*height), U plane ((w+1)/2*(h+1)/2), V plane (same).
    // Stride stored in the `stride` field is the Y-plane row width (== width).
    // This is the common output of both libdav1d (AV1) and FFmpeg VP8 decoder,
    // so sws_scale YUV→BGRA is skipped entirely for 8-bit 4:2:0 sources.
    I420,
};

struct DecodedVideoFrameBGRA {
    int width = 0;
    int height = 0;
    int stride = 0;         // BGRA: bytes per row (width*4). I420: Y-plane width.
    std::int64_t pts90k = 0;
    VideoPixelFormat pixelFormat = VideoPixelFormat::BGRA;
    std::vector<std::uint8_t> data; // renamed from bgra; holds BGRA or packed I420
};

struct DecodedAudioFrameFloat32Planar {
    int sampleRate = 48000;
    int channels = 2;
    int samples = 0;
    std::int64_t pts48k = 0;
    // NDI expects float32 planar audio: channel 0 block, then channel 1 block, etc.
    std::vector<float> planar;
};
