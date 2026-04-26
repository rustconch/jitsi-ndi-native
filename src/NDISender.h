#pragma once

#include "TestPattern.h"

#include <cstdint>
#include <memory>
#include <string>

class NDISender {
public:
    explicit NDISender(std::string sourceName);
    ~NDISender();

    bool start();
    void stop();
    bool sendFrame(const VideoFrameBGRA& frame, int fpsNum, int fpsDen);

private:
    std::string sourceName_;
    bool started_ = false;
    std::uint64_t sentFrames_ = 0;

#if JNN_HAS_NDI
    void* ndiSend_ = nullptr;
#endif
};
