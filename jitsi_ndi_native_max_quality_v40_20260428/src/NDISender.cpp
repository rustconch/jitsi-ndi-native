#include "NDISender.h"

#include "Logger.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <utility>

#if JNN_HAS_NDI
#include <Processing.NDI.Lib.h>
#endif

namespace {

constexpr int kNdiMinimumCanvasWidth = 1920;
constexpr int kNdiMinimumCanvasHeight = 1080;

bool shouldUpscaleToMinimumNdiCanvas(const DecodedVideoFrameBGRA& frame) {
    if (frame.width <= 0 || frame.height <= 0 || frame.stride <= 0 || frame.bgra.empty()) {
        return false;
    }

    // Never downscale. If the incoming decoded frame is already Full HD or larger
    // in either dimension, keep the original resolution exactly as received.
    return frame.width < kNdiMinimumCanvasWidth && frame.height < kNdiMinimumCanvasHeight;
}

DecodedVideoFrameBGRA upscaleToMinimumNdiCanvas(const DecodedVideoFrameBGRA& frame) {
    DecodedVideoFrameBGRA out;
    out.width = kNdiMinimumCanvasWidth;
    out.height = kNdiMinimumCanvasHeight;
    out.stride = out.width * 4;
    out.pts90k = frame.pts90k;
    out.bgra.assign(static_cast<std::size_t>(out.stride) * static_cast<std::size_t>(out.height), 0);

    const double scaleX = static_cast<double>(out.width) / static_cast<double>(frame.width);
    const double scaleY = static_cast<double>(out.height) / static_cast<double>(frame.height);
    const double scale = std::min(scaleX, scaleY);

    const int scaledW = std::max(1, static_cast<int>(std::round(static_cast<double>(frame.width) * scale)));
    const int scaledH = std::max(1, static_cast<int>(std::round(static_cast<double>(frame.height) * scale)));
    const int offsetX = std::max(0, (out.width - scaledW) / 2);
    const int offsetY = std::max(0, (out.height - scaledH) / 2);

    for (int y = 0; y < scaledH; ++y) {
        const int srcY = std::min(frame.height - 1, (y * frame.height) / scaledH);
        const auto* srcRow = frame.bgra.data() + static_cast<std::size_t>(srcY) * static_cast<std::size_t>(frame.stride);
        auto* dstRow = out.bgra.data()
            + static_cast<std::size_t>(offsetY + y) * static_cast<std::size_t>(out.stride)
            + static_cast<std::size_t>(offsetX) * 4u;

        for (int x = 0; x < scaledW; ++x) {
            const int srcX = std::min(frame.width - 1, (x * frame.width) / scaledW);
            const auto* srcPx = srcRow + static_cast<std::size_t>(srcX) * 4u;
            auto* dstPx = dstRow + static_cast<std::size_t>(x) * 4u;
            std::memcpy(dstPx, srcPx, 4u);
        }
    }

    return out;
}

} // namespace

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

    DecodedVideoFrameBGRA upscaled;
    const DecodedVideoFrameBGRA* sendFrame = &frame;
    bool upscaledForNdi = false;

    if (shouldUpscaleToMinimumNdiCanvas(frame)) {
        upscaled = upscaleToMinimumNdiCanvas(frame);
        sendFrame = &upscaled;
        upscaledForNdi = true;
    }

#if JNN_HAS_NDI
    NDIlib_video_frame_v2_t video{};
    video.xres = sendFrame->width;
    video.yres = sendFrame->height;
    video.FourCC = NDIlib_FourCC_type_BGRA;
    video.frame_rate_N = fpsNum;
    video.frame_rate_D = fpsDen <= 0 ? 1 : fpsDen;
    video.picture_aspect_ratio = static_cast<float>(sendFrame->width) / static_cast<float>(sendFrame->height);
    video.frame_format_type = NDIlib_frame_format_type_progressive;
    video.p_data = const_cast<std::uint8_t*>(sendFrame->bgra.data());
    video.line_stride_in_bytes = sendFrame->stride;
    NDIlib_send_send_video_v2(static_cast<NDIlib_send_instance_t>(ndiSend_), &video);
    if ((sentFrames_ % 300) == 0) {
        if (upscaledForNdi) {
            Logger::info("NDI video frame sent: ", sourceName_, " ", sendFrame->width, "x", sendFrame->height, " upscaled-from=", frame.width, "x", frame.height);
        } else {
            Logger::info("NDI video frame sent: ", sourceName_, " ", sendFrame->width, "x", sendFrame->height);
        }
    }
#else
    if ((sentFrames_ % 300) == 0) {
        if (upscaledForNdi) {
            Logger::info("Mock NDI decoded video ", sentFrames_, " ", sourceName_, " ", sendFrame->width, "x", sendFrame->height, " upscaled-from=", frame.width, "x", frame.height);
        } else {
            Logger::info("Mock NDI decoded video ", sentFrames_, " ", sourceName_, " ", sendFrame->width, "x", sendFrame->height);
        }
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

