#pragma once

#include "DecodedMedia.h"
#include "TestPattern.h"

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

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
#if JNN_HAS_NDI
    void audioWorkerLoop();
    void startAudioWorker();
    void stopAudioWorker();
    void sendAudioFrameImmediate(const DecodedAudioFrameFloat32Planar& frame);
#endif

    std::string sourceName_;
    bool started_ = false;
    std::uint64_t sentFrames_ = 0;
    std::uint64_t sentAudioFrames_ = 0;
    std::uint64_t droppedQueuedAudioFrames_ = 0;

    static constexpr std::size_t kMaxAudioQueueFrames = 50;

    std::mutex audioMutex_;
    std::condition_variable audioCv_;
    std::deque<DecodedAudioFrameFloat32Planar> audioQueue_;
    std::thread audioThread_;
    std::atomic<bool> audioStopRequested_{false};
    std::atomic<bool> audioWorkerRunning_{false};

#if JNN_HAS_NDI
    void* ndiSend_ = nullptr;
#endif
};
