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
    // v100: by-value sinks. Callers can std::move() decoded frames in to avoid
    // copying the BGRA / planar buffers on the hot path. Old const-ref calls keep
    // working but pay one extra copy.
    bool sendVideoFrame(DecodedVideoFrameBGRA frame, int fpsNum, int fpsDen);
    bool sendAudioFrame(DecodedAudioFrameFloat32Planar frame);

    const std::string& sourceName() const { return sourceName_; }

private:
#if JNN_HAS_NDI
    struct QueuedVideoFrame {
        DecodedVideoFrameBGRA frame;
        int fpsNum = 30;
        int fpsDen = 1;
    };

    void audioWorkerLoop();
    void startAudioWorker();
    void stopAudioWorker();
    void sendAudioFrameImmediate(const DecodedAudioFrameFloat32Planar& frame);

    void videoWorkerLoop();
    void startVideoWorker();
    void stopVideoWorker();
    void sendVideoFrameImmediate(const DecodedVideoFrameBGRA& frame, int fpsNum, int fpsDen);
    // v100: takes ownership of the input. If no scaling is required the moved-in
    // BGRA buffer is forwarded as-is; only on resize do we allocate a new one.
    DecodedVideoFrameBGRA capVideoFrameForNdi(DecodedVideoFrameBGRA frame) const;
#endif

    std::string sourceName_;
    bool started_ = false;
    std::uint64_t sentFrames_ = 0;
    std::uint64_t sentAudioFrames_ = 0;
    std::uint64_t droppedQueuedAudioFrames_ = 0;
    std::uint64_t droppedQueuedVideoFrames_ = 0;
    std::uint64_t scaledVideoFrames_ = 0;

    // v100: was 50 (~1s). With clock_audio=true the SDK paces audio at its own
    // wall clock, so any overflow past ~16 frames (~320ms at 20ms Opus) is just
    // accumulated A/V drift. Cap shorter to keep audio close to the matching
    // video frame; old samples are still dropped from the front on overflow.
    static constexpr std::size_t kMaxAudioQueueFrames = 16;
    static constexpr std::size_t kMaxVideoQueueFrames = 2;

    std::mutex audioMutex_;
    std::condition_variable audioCv_;
    std::deque<DecodedAudioFrameFloat32Planar> audioQueue_;
    std::thread audioThread_;
    std::atomic<bool> audioStopRequested_{false};
    std::atomic<bool> audioWorkerRunning_{false};

#if JNN_HAS_NDI
    std::mutex videoMutex_;
    std::condition_variable videoCv_;
    std::deque<QueuedVideoFrame> videoQueue_;
    std::thread videoThread_;
    std::atomic<bool> videoStopRequested_{false};
    std::atomic<bool> videoWorkerRunning_{false};

    void* ndiSend_ = nullptr;
#endif
};
