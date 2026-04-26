#pragma once

#include <cstdint>
#include <vector>

struct DecodedVideoFrameBGRA {
    int width = 0;
    int height = 0;
    int stride = 0;
    std::int64_t pts90k = 0;
    std::vector<std::uint8_t> bgra;
};

struct DecodedAudioFrameFloat32Planar {
    int sampleRate = 48000;
    int channels = 2;
    int samples = 0;
    std::int64_t pts48k = 0;
    // NDI expects float32 planar audio: channel 0 block, then channel 1 block, etc.
    std::vector<float> planar;
};
