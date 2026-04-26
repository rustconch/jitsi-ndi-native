#include "TestPattern.h"

#include <algorithm>
#include <cstdint>

TestPattern::TestPattern(int width, int height)
    : width_(std::max(16, width)), height_(std::max(16, height)) {}

VideoFrameBGRA TestPattern::nextFrame() {
    VideoFrameBGRA f;
    f.width = width_;
    f.height = height_;
    f.strideBytes = width_ * 4;
    f.pixels.resize(static_cast<std::size_t>(f.strideBytes) * height_);

    const int t = frameIndex_++;

    for (int y = 0; y < height_; ++y) {
        for (int x = 0; x < width_; ++x) {
            const int bar = ((x + t * 8) * 8) / std::max(1, width_);
            std::uint8_t r = 0, g = 0, b = 0;

            switch (bar % 8) {
                case 0: r = 255; g = 255; b = 255; break;
                case 1: r = 255; g = 255; b = 0; break;
                case 2: r = 0; g = 255; b = 255; break;
                case 3: r = 0; g = 255; b = 0; break;
                case 4: r = 255; g = 0; b = 255; break;
                case 5: r = 255; g = 0; b = 0; break;
                case 6: r = 0; g = 0; b = 255; break;
                default: r = 30; g = 30; b = 30; break;
            }

            // Moving grid overlay.
            if (((x + t * 3) % 80) < 2 || ((y + t * 2) % 80) < 2) {
                r = static_cast<std::uint8_t>(255 - r / 2);
                g = static_cast<std::uint8_t>(255 - g / 2);
                b = static_cast<std::uint8_t>(255 - b / 2);
            }

            const std::size_t off = static_cast<std::size_t>(y) * f.strideBytes + static_cast<std::size_t>(x) * 4;
            f.pixels[off + 0] = b;
            f.pixels[off + 1] = g;
            f.pixels[off + 2] = r;
            f.pixels[off + 3] = 255;
        }
    }

    return f;
}
