#include "TestPattern.h"

#include <algorithm>
#include <cmath>

TestPattern::TestPattern(int width, int height)
    : width_(std::max(320, width)), height_(std::max(180, height)) {}

void TestPattern::setStatus(std::string status) {
    status_ = std::move(status);
}

void TestPattern::drawRect(VideoFrameBGRA& frame, int x, int y, int w, int h, std::uint8_t b, std::uint8_t g, std::uint8_t r) {
    const int x0 = std::max(0, x);
    const int y0 = std::max(0, y);
    const int x1 = std::min(frame.width, x + w);
    const int y1 = std::min(frame.height, y + h);

    for (int yy = y0; yy < y1; ++yy) {
        auto* row = frame.pixels.data() + yy * frame.stride;
        for (int xx = x0; xx < x1; ++xx) {
            row[xx * 4 + 0] = b;
            row[xx * 4 + 1] = g;
            row[xx * 4 + 2] = r;
            row[xx * 4 + 3] = 255;
        }
    }
}

void TestPattern::drawDigit(VideoFrameBGRA& frame, int x, int y, int s, int digit) {
    static const int mask[10] = {
        0b1111110, 0b0110000, 0b1101101, 0b1111001, 0b0110011,
        0b1011011, 0b1011111, 0b1110000, 0b1111111, 0b1111011
    };
    if (digit < 0 || digit > 9) return;
    const int m = mask[digit];
    const int t = s;
    const int W = 5 * s;
    const int H = 9 * s;
    const auto seg = [&](int idx, int rx, int ry, int rw, int rh) {
        if (m & (1 << idx)) drawRect(frame, x + rx, y + ry, rw, rh, 20, 230, 80);
    };
    seg(6, t, 0, W - 2 * t, t);              // top
    seg(5, 0, t, t, H / 2 - t);              // upper left
    seg(4, W - t, t, t, H / 2 - t);          // upper right
    seg(3, t, H / 2, W - 2 * t, t);          // middle
    seg(2, 0, H / 2 + t, t, H / 2 - t);      // lower left
    seg(1, W - t, H / 2 + t, t, H / 2 - t);  // lower right
    seg(0, t, H - t, W - 2 * t, t);          // bottom
}

void TestPattern::drawNumber(VideoFrameBGRA& frame, int x, int y, int scale, std::uint64_t value) {
    std::string s = std::to_string(value);
    for (char c : s) {
        drawDigit(frame, x, y, scale, c - '0');
        x += scale * 7;
    }
}

VideoFrameBGRA TestPattern::nextFrame() {
    VideoFrameBGRA frame;
    frame.width = width_;
    frame.height = height_;
    frame.stride = width_ * 4;
    frame.pixels.resize(static_cast<std::size_t>(frame.stride) * frame.height);

    const int moving = static_cast<int>(frameIndex_ % width_);

    for (int y = 0; y < height_; ++y) {
        auto* row = frame.pixels.data() + y * frame.stride;
        for (int x = 0; x < width_; ++x) {
            const double fx = static_cast<double>(x) / std::max(1, width_ - 1);
            const double fy = static_cast<double>(y) / std::max(1, height_ - 1);
            const std::uint8_t r = static_cast<std::uint8_t>(40 + 100 * fx);
            const std::uint8_t g = static_cast<std::uint8_t>(30 + 120 * fy);
            const std::uint8_t b = static_cast<std::uint8_t>(80 + 80 * std::sin((fx + fy + frameIndex_ * 0.01) * 3.1415926535));
            row[x * 4 + 0] = b;
            row[x * 4 + 1] = g;
            row[x * 4 + 2] = r;
            row[x * 4 + 3] = 255;
        }
    }

    drawRect(frame, 0, 0, width_, 54, 24, 24, 24);
    drawRect(frame, 0, height_ - 54, width_, 54, 24, 24, 24);
    drawRect(frame, moving - 80, height_ / 2 - 12, 160, 24, 0, 255, 90);
    drawRect(frame, 24, 18, 220, 18, 70, 210, 90);
    drawNumber(frame, 270, 13, 4, frameIndex_);

    ++frameIndex_;
    return frame;
}
