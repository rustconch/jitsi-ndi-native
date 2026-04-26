#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct VideoFrameBGRA {
    int width = 0;
    int height = 0;
    int stride = 0;
    std::vector<std::uint8_t> pixels;
};

class TestPattern {
public:
    TestPattern(int width, int height);

    VideoFrameBGRA nextFrame();
    void setStatus(std::string status);

private:
    void drawRect(VideoFrameBGRA& frame, int x, int y, int w, int h, std::uint8_t b, std::uint8_t g, std::uint8_t r);
    void drawDigit(VideoFrameBGRA& frame, int x, int y, int scale, int digit);
    void drawNumber(VideoFrameBGRA& frame, int x, int y, int scale, std::uint64_t value);

    int width_ = 1280;
    int height_ = 720;
    std::uint64_t frameIndex_ = 0;
    std::string status_ = "native jitsi ndi";
};
