#include "NDISender.h"

#include "Logger.h"

#include <utility>

#if JNN_HAS_NDI
#include <Processing.NDI.Lib.h>
#endif

NDISender::NDISender(std::string sourceName) : sourceName_(std::move(sourceName)) {}

NDISender::~NDISender() {
    stop();
}

bool NDISender::start() {
    if (started_) return true;

#if JNN_HAS_NDI
    if (!NDIlib_initialize()) {
        Logger::error("NDIlib_initialize failed");
        return false;
    }

    NDIlib_send_create_t createDesc{};
    createDesc.p_ndi_name = sourceName_.c_str();
    createDesc.clock_video = false;
    // PATCH_V12_AUDIO_QUEUE_CLOCK: let the SDK pace audio, but do it from a worker
    // thread so the WebRTC RTP callback never blocks and video packets keep flowing.
    createDesc.clock_audio = true;

    ndiSend_ = NDIlib_send_create(&createDesc);
    if (!ndiSend_) {
        Logger::error("NDIlib_send_create failed for ", sourceName_);
        NDIlib_destroy();
        return false;
    }

    startAudioWorker();

    Logger::info("Real NDI sender started: ", sourceName_);
#else
    Logger::warn("Mock NDI sender started: ", sourceName_, " (JNN_HAS_NDI=0)");
#endif

    started_ = true;
    return true;
}

void NDISender::stop() {
    if (!started_) return;

#if JNN_HAS_NDI
    stopAudioWorker();

    if (ndiSend_) {
        NDIlib_send_destroy(static_cast<NDIlib_send_instance_t>(ndiSend_));
        ndiSend_ = nullptr;
    }
    NDIlib_destroy();
#else
    {
        std::lock_guard<std::mutex> lock(audioMutex_);
        audioQueue_.clear();
    }
#endif

    started_ = false;
    Logger::info("NDI sender stopped: ", sourceName_);
}

bool NDISender::sendFrame(const VideoFrameBGRA& frame, int fpsNum, int fpsDen) {
    if (!started_) return false;
    if (frame.width <= 0 || frame.height <= 0 || frame.pixels.empty()) return false;

#if JNN_HAS_NDI
    NDIlib_video_frame_v2_t video{};
    video.xres = frame.width;
    video.yres = frame.height;
    video.FourCC = NDIlib_FourCC_type_BGRA;
    video.frame_rate_N = fpsNum;
    video.frame_rate_D = fpsDen <= 0 ? 1 : fpsDen;
    video.picture_aspect_ratio = static_cast<float>(frame.width) / static_cast<float>(frame.height);
    video.frame_format_type = NDIlib_frame_format_type_progressive;
    video.p_data = const_cast<std::uint8_t*>(frame.pixels.data());
    video.line_stride_in_bytes = frame.stride;
    NDIlib_send_send_video_v2(static_cast<NDIlib_send_instance_t>(ndiSend_), &video);
    if ((sentFrames_ % 300) == 0) {
        Logger::info("NDI video frame sent: ", sourceName_, " ", frame.width, "x", frame.height);
    }
#else
    if ((sentFrames_ % 300) == 0) {
        Logger::info("Mock NDI video frame ", sentFrames_, " ", sourceName_, " ", frame.width, "x", frame.height);
    }
#endif

    ++sentFrames_;
    return true;
}

bool NDISender::sendVideoFrame(const DecodedVideoFrameBGRA& frame, int fpsNum, int fpsDen) {
    if (!started_) return false;
    if (frame.width <= 0 || frame.height <= 0 || frame.bgra.empty()) return false;

#if JNN_HAS_NDI
    NDIlib_video_frame_v2_t video{};
    video.xres = frame.width;
    video.yres = frame.height;
    video.FourCC = NDIlib_FourCC_type_BGRA;
    video.frame_rate_N = fpsNum;
    video.frame_rate_D = fpsDen <= 0 ? 1 : fpsDen;
    video.picture_aspect_ratio = static_cast<float>(frame.width) / static_cast<float>(frame.height);
    video.frame_format_type = NDIlib_frame_format_type_progressive;
    video.p_data = const_cast<std::uint8_t*>(frame.bgra.data());
    video.line_stride_in_bytes = frame.stride;
    NDIlib_send_send_video_v2(static_cast<NDIlib_send_instance_t>(ndiSend_), &video);
    if ((sentFrames_ % 300) == 0) {
        Logger::info("NDI video frame sent: ", sourceName_, " ", frame.width, "x", frame.height);
    }
#else
    if ((sentFrames_ % 300) == 0) {
        Logger::info("Mock NDI decoded video ", sentFrames_, " ", sourceName_, " ", frame.width, "x", frame.height);
    }
#endif

    ++sentFrames_;
    return true;
}

bool NDISender::sendAudioFrame(const DecodedAudioFrameFloat32Planar& frame) {
    if (!started_) return false;
    if (frame.sampleRate <= 0 || frame.channels <= 0 || frame.samples <= 0 || frame.planar.empty()) return false;

#if JNN_HAS_NDI
    {
        std::lock_guard<std::mutex> lock(audioMutex_);

        if (audioQueue_.size() >= kMaxAudioQueueFrames) {
            audioQueue_.pop_front();
            ++droppedQueuedAudioFrames_;

            if (droppedQueuedAudioFrames_ == 1 || (droppedQueuedAudioFrames_ % 100) == 0) {
                Logger::warn(
                    "NDI audio queue overflow for ",
                    sourceName_,
                    "; dropped=",
                    droppedQueuedAudioFrames_,
                    " queueMax=",
                    kMaxAudioQueueFrames
                );
            }
        }

        audioQueue_.push_back(frame);
    }

    audioCv_.notify_one();
#else
    if ((sentAudioFrames_ % 500) == 0) {
        Logger::info("Mock NDI audio frame ", sentAudioFrames_, " ", sourceName_, " samples=", frame.samples);
    }
#endif

    ++sentAudioFrames_;
    return true;
}

#if JNN_HAS_NDI
void NDISender::startAudioWorker() {
    audioStopRequested_.store(false);
    audioWorkerRunning_.store(true);
    audioThread_ = std::thread(&NDISender::audioWorkerLoop, this);
}

void NDISender::stopAudioWorker() {
    audioStopRequested_.store(true);
    audioCv_.notify_all();

    if (audioThread_.joinable()) {
        audioThread_.join();
    }

    audioWorkerRunning_.store(false);

    std::lock_guard<std::mutex> lock(audioMutex_);
    audioQueue_.clear();
}

void NDISender::audioWorkerLoop() {
    while (true) {
        DecodedAudioFrameFloat32Planar frame;

        {
            std::unique_lock<std::mutex> lock(audioMutex_);
            audioCv_.wait(lock, [this]() {
                return audioStopRequested_.load() || !audioQueue_.empty();
            });

            if (audioStopRequested_.load() && audioQueue_.empty()) {
                break;
            }

            frame = std::move(audioQueue_.front());
            audioQueue_.pop_front();
        }

        sendAudioFrameImmediate(frame);
    }
}

void NDISender::sendAudioFrameImmediate(const DecodedAudioFrameFloat32Planar& frame) {
    if (!ndiSend_) return;
    if (frame.sampleRate <= 0 || frame.channels <= 0 || frame.samples <= 0 || frame.planar.empty()) return;

    NDIlib_audio_frame_v2_t audio{};
    audio.sample_rate = frame.sampleRate;
    audio.no_channels = frame.channels;
    audio.no_samples = frame.samples;
    audio.timecode = NDIlib_send_timecode_synthesize;
    audio.p_data = const_cast<float*>(frame.planar.data());
    audio.channel_stride_in_bytes = frame.samples * static_cast<int>(sizeof(float));
    NDIlib_send_send_audio_v2(static_cast<NDIlib_send_instance_t>(ndiSend_), &audio);
}
#endif

