#include "NDISender.h"

#include "Logger.h"

#include <algorithm>
#include <cstring>
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
    startVideoWorker();

    Logger::info("Real NDI sender started: ", sourceName_, " (v90 async video queue + 1080p NDI cap)");
#else
    Logger::warn("Mock NDI sender started: ", sourceName_, " (JNN_HAS_NDI=0)");
#endif

    started_ = true;
    return true;
}

void NDISender::stop() {
    if (!started_) return;

#if JNN_HAS_NDI
    stopVideoWorker();
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

    DecodedVideoFrameBGRA decoded{};
    decoded.width = frame.width;
    decoded.height = frame.height;
    decoded.stride = frame.stride;
    decoded.pixelFormat = VideoPixelFormat::BGRA;
    decoded.data = frame.pixels;
    return sendVideoFrame(std::move(decoded), fpsNum, fpsDen);
}

bool NDISender::sendVideoFrame(DecodedVideoFrameBGRA frame, int fpsNum, int fpsDen) {
    if (!started_) return false;
    if (frame.width <= 0 || frame.height <= 0 || frame.data.empty()) return false;

#if JNN_HAS_NDI
    QueuedVideoFrame queued{};
    // v100: forward BGRA ownership through the cap helper. For frames already
    // <= 1080p / contiguous stride this avoids copying ~8MB per FullHD frame.
    queued.frame = capVideoFrameForNdi(std::move(frame));
    queued.fpsNum = fpsNum <= 0 ? 30 : fpsNum;
    queued.fpsDen = fpsDen <= 0 ? 1 : fpsDen;

    {
        std::lock_guard<std::mutex> lock(videoMutex_);

        while (videoQueue_.size() >= kMaxVideoQueueFrames) {
            videoQueue_.pop_front();
            ++droppedQueuedVideoFrames_;
        }

        videoQueue_.push_back(std::move(queued));
    }

    videoCv_.notify_one();
#else
    if ((sentFrames_ % 300) == 0) {
        Logger::info("Mock NDI decoded video ", sentFrames_, " ", sourceName_, " ", frame.width, "x", frame.height);
    }
    ++sentFrames_;
#endif

    return true;
}

bool NDISender::sendAudioFrame(DecodedAudioFrameFloat32Planar frame) {
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

        // v100: move the planar buffer instead of copying ~kB-sized vector per frame.
        audioQueue_.push_back(std::move(frame));
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
DecodedVideoFrameBGRA NDISender::capVideoFrameForNdi(DecodedVideoFrameBGRA frame) const {
    static constexpr int kMaxNdiWidth  = 1920;
    static constexpr int kMaxNdiHeight = 1080;

    if (frame.width <= 0 || frame.height <= 0 || frame.data.empty()) {
        return frame;
    }

    // Fast path: frame already fits within 1920×1080 and stride is packed.
    // For I420: stride == width. For BGRA: stride == width*4.
    const bool fitsInCap = frame.width <= kMaxNdiWidth && frame.height <= kMaxNdiHeight;
    const bool strideIsPacked = (frame.pixelFormat == VideoPixelFormat::I420)
        ? (frame.stride == frame.width)
        : (frame.stride == frame.width * 4);
    if (fitsInCap && strideIsPacked) {
        // v100/v102: forward ownership with no copy.
        return frame;
    }

    // Compute destination dimensions (maintain aspect ratio, cap at 1920×1080).
    const double scaleW = static_cast<double>(kMaxNdiWidth)  / static_cast<double>(frame.width);
    const double scaleH = static_cast<double>(kMaxNdiHeight) / static_cast<double>(frame.height);
    const double scale  = std::min(1.0, std::min(scaleW, scaleH));

    int dstW = std::max(2, static_cast<int>(frame.width  * scale + 0.5));
    int dstH = std::max(2, static_cast<int>(frame.height * scale + 0.5));
    if ((dstW % 2) != 0) --dstW;
    if ((dstH % 2) != 0) --dstH;
    dstW = std::max(2, dstW);
    dstH = std::max(2, dstH);

    DecodedVideoFrameBGRA out{};
    out.width   = dstW;
    out.height  = dstH;
    out.pts90k  = frame.pts90k;
    out.pixelFormat = frame.pixelFormat;

    if (frame.pixelFormat == VideoPixelFormat::I420) {
        // --- I420 downscale (nearest-neighbour, 3 planes) ---
        // Precompute x lookup tables for Y and UV planes separately.
        const int uvSrcW = (frame.width  + 1) / 2;
        const int uvSrcH = (frame.height + 1) / 2;
        const int uvDstW = dstW / 2;
        const int uvDstH = dstH / 2;

        out.stride = dstW; // Y-plane row width
        out.data.resize(
            static_cast<std::size_t>(dstW) * static_cast<std::size_t>(dstH) +
            static_cast<std::size_t>(uvDstW) * static_cast<std::size_t>(uvDstH) * 2
        );

        const std::uint8_t* srcY = frame.data.data();
        const std::uint8_t* srcU = srcY + static_cast<std::size_t>(frame.width)  * static_cast<std::size_t>(frame.height);
        const std::uint8_t* srcV = srcU + static_cast<std::size_t>(uvSrcW) * static_cast<std::size_t>(uvSrcH);

        std::uint8_t* dstY = out.data.data();
        std::uint8_t* dstU = dstY + static_cast<std::size_t>(dstW) * static_cast<std::size_t>(dstH);
        std::uint8_t* dstV = dstU + static_cast<std::size_t>(uvDstW) * static_cast<std::size_t>(uvDstH);

        // Y-plane xMap
        std::vector<int> xMapY(static_cast<std::size_t>(dstW));
        for (int x = 0; x < dstW; ++x) {
            xMapY[x] = std::min(frame.width - 1,
                static_cast<int>((static_cast<long long>(x) * frame.width) / dstW));
        }
        for (int y = 0; y < dstH; ++y) {
            const int srcRow = std::min(frame.height - 1,
                static_cast<int>((static_cast<long long>(y) * frame.height) / dstH));
            const std::uint8_t* sRow = srcY + static_cast<std::size_t>(srcRow) * static_cast<std::size_t>(frame.width);
            std::uint8_t*       dRow = dstY + static_cast<std::size_t>(y)      * static_cast<std::size_t>(dstW);
            for (int x = 0; x < dstW; ++x) {
                dRow[x] = sRow[xMapY[x]];
            }
        }

        // UV-plane xMap
        std::vector<int> xMapUV(static_cast<std::size_t>(uvDstW));
        for (int x = 0; x < uvDstW; ++x) {
            xMapUV[x] = std::min(uvSrcW - 1,
                static_cast<int>((static_cast<long long>(x) * uvSrcW) / uvDstW));
        }
        for (int y = 0; y < uvDstH; ++y) {
            const int srcRow = std::min(uvSrcH - 1,
                static_cast<int>((static_cast<long long>(y) * uvSrcH) / uvDstH));
            const std::uint8_t* sU = srcU + static_cast<std::size_t>(srcRow) * static_cast<std::size_t>(uvSrcW);
            const std::uint8_t* sV = srcV + static_cast<std::size_t>(srcRow) * static_cast<std::size_t>(uvSrcW);
            std::uint8_t*       dU = dstU + static_cast<std::size_t>(y)      * static_cast<std::size_t>(uvDstW);
            std::uint8_t*       dV = dstV + static_cast<std::size_t>(y)      * static_cast<std::size_t>(uvDstW);
            for (int x = 0; x < uvDstW; ++x) {
                dU[x] = sU[xMapUV[x]];
                dV[x] = sV[xMapUV[x]];
            }
        }
    } else {
        // --- BGRA downscale (nearest-neighbour, 4 bytes/pixel) ---
        // v102: precomputed xMap to eliminate per-pixel integer division.
        const int srcStride = frame.stride > 0 ? frame.stride : frame.width * 4;
        out.stride = dstW * 4;
        out.data.resize(static_cast<std::size_t>(out.stride) * static_cast<std::size_t>(dstH));

        std::vector<int> xByteOffset(static_cast<std::size_t>(dstW));
        for (int x = 0; x < dstW; ++x) {
            const int srcX = std::min(frame.width - 1,
                static_cast<int>((static_cast<long long>(x) * frame.width) / dstW));
            xByteOffset[x] = srcX * 4;
        }
        for (int y = 0; y < dstH; ++y) {
            const int srcY = std::min(frame.height - 1,
                static_cast<int>((static_cast<long long>(y) * frame.height) / dstH));
            const std::uint8_t* srcRow = frame.data.data() +
                static_cast<std::size_t>(srcY) * static_cast<std::size_t>(srcStride);
            std::uint8_t* dstRow = out.data.data() +
                static_cast<std::size_t>(y) * static_cast<std::size_t>(out.stride);
            for (int x = 0; x < dstW; ++x) {
                std::memcpy(dstRow + static_cast<std::size_t>(x) * 4,
                            srcRow + static_cast<std::size_t>(xByteOffset[x]), 4);
            }
        }
    }

    return out;
}

void NDISender::startVideoWorker() {
    videoStopRequested_.store(false);
    videoWorkerRunning_.store(true);
    videoThread_ = std::thread(&NDISender::videoWorkerLoop, this);
}

void NDISender::stopVideoWorker() {
    videoStopRequested_.store(true);
    videoCv_.notify_all();

    if (videoThread_.joinable()) {
        videoThread_.join();
    }

    videoWorkerRunning_.store(false);

    std::lock_guard<std::mutex> lock(videoMutex_);
    videoQueue_.clear();
}

void NDISender::videoWorkerLoop() {
    while (true) {
        QueuedVideoFrame queued;
        std::size_t droppedInWorker = 0;

        {
            std::unique_lock<std::mutex> lock(videoMutex_);
            videoCv_.wait(lock, [this]() {
                return videoStopRequested_.load() || !videoQueue_.empty();
            });

            if (videoStopRequested_.load() && videoQueue_.empty()) {
                break;
            }

            // Low-latency policy: when NDI/vMix blocks, discard older decoded frames and
            // send only the newest one. Audio remains on its own queue and is untouched.
            if (videoQueue_.size() > 1) {
                droppedInWorker = videoQueue_.size() - 1;
            }

            queued = std::move(videoQueue_.back());
            videoQueue_.clear();
        }

        if (droppedInWorker > 0) {
            droppedQueuedVideoFrames_ += droppedInWorker;
            if (droppedQueuedVideoFrames_ == droppedInWorker || (droppedQueuedVideoFrames_ % 300) < droppedInWorker) {
                Logger::warn(
                    "NDI video queue lag for ",
                    sourceName_,
                    "; dropped stale decoded frames=",
                    droppedQueuedVideoFrames_,
                    " queueMax=",
                    kMaxVideoQueueFrames
                );
            }
        }

        sendVideoFrameImmediate(queued.frame, queued.fpsNum, queued.fpsDen);
    }
}

void NDISender::sendVideoFrameImmediate(const DecodedVideoFrameBGRA& frame, int fpsNum, int fpsDen) {
    if (!ndiSend_) return;
    if (frame.width <= 0 || frame.height <= 0 || frame.data.empty()) return;

    NDIlib_video_frame_v2_t video{};
    video.xres = frame.width;
    video.yres = frame.height;
    video.frame_rate_N = fpsNum;
    video.frame_rate_D = fpsDen <= 0 ? 1 : fpsDen;
    video.picture_aspect_ratio = static_cast<float>(frame.width) / static_cast<float>(frame.height);
    video.frame_format_type = NDIlib_frame_format_type_progressive;
    video.p_data = const_cast<std::uint8_t*>(frame.data.data());

    // v102: I420 is the native output of libdav1d (AV1) and FFmpeg VP8.
    // Sending I420 directly to NDI avoids the YUV→BGRA conversion that used
    // to happen in sws_scale. NDI SDK and downstream tools (vMix, OBS, etc.)
    // all handle I420 natively. BGRA remains as fallback for exotic formats.
    if (frame.pixelFormat == VideoPixelFormat::I420) {
        video.FourCC = NDIlib_FourCC_type_I420;
        video.line_stride_in_bytes = frame.stride > 0 ? frame.stride : frame.width;
    } else {
        video.FourCC = NDIlib_FourCC_type_BGRA;
        video.line_stride_in_bytes = frame.stride > 0 ? frame.stride : frame.width * 4;
    }

    NDIlib_send_send_video_v2(static_cast<NDIlib_send_instance_t>(ndiSend_), &video);

    if ((sentFrames_ % 300) == 0) {
        Logger::info("NDI video frame sent: ", sourceName_, " ", frame.width, "x", frame.height, " fps=", fpsNum, "/", fpsDen <= 0 ? 1 : fpsDen);
    }

    ++sentFrames_;
}
#endif

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

