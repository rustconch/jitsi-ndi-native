#pragma once

#include "TestPattern.h"

#include <memory>
#include <string>

class NDISender {
public:
    explicit NDISender(std::string sourceName);
    ~NDISender();

    bool start();
    void stop();
    bool sendFrame(const VideoFrameBGRA& frame, int fpsNumerator = 30, int fpsDenominator = 1);

private:
    std::string sourceName_;
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
