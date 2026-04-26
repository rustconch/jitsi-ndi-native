#pragma once

#include <cstdint>
#include <vector>

struct VideoFrameBGRA {
    int width = 0;
    int height = 0;
    int strideBytes = 0;
    std::vector<std::uint8_t> pixels;
};

class TestPattern {
public:
    TestPattern(int width, int height);
    VideoFrameBGRA nextFrame();

private:
    int width_ = 1280;
    int height_ = 720;
    int frameIndex_ = 0;
};
