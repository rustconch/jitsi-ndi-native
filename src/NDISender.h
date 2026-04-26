#pragma once

#include "DecodedMedia.h"
#include "TestPattern.h"

#include <cstdint>
#include <memory>
#include <string>

class NDISender {
public:
    explicit NDISender(std::string sourceName);
    ~NDISender();

    NDISender(const NDISender&) = delete;
    NDISender& operator=(const NDISender&) = delete;

    bool start();
    void stop();

    bool sendFrame(const VideoFrameBGRA& frame, int fpsNum, int fpsDen);
    bool sendVideoFrame(const DecodedVideoFrameBGRA& frame, int fpsNum, int fpsDen);
    bool sendAudioFrame(const DecodedAudioFrameFloat32Planar& frame);

    const std::string& sourceName() const { return sourceName_; }

private:
    std::string sourceName_;
    bool started_ = false;
    std::uint64_t sentFrames_ = 0;
    std::uint64_t sentAudioFrames_ = 0;

#if JNN_HAS_NDI
    void* ndiSend_ = nullptr;
#endif
};
