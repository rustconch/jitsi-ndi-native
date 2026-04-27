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
    createDesc.clock_audio = true; // PATCH_V10_AUDIO_PLANAR_CLOCK: let NDI pace audio; Opus/RTP decode is already 20 ms frames

    ndiSend_ = NDIlib_send_create(&createDesc);
    if (!ndiSend_) {
        Logger::error("NDIlib_send_create failed for ", sourceName_);
        NDIlib_destroy();
        return false;
    }

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
    if (ndiSend_) {
        NDIlib_send_destroy(static_cast<NDIlib_send_instance_t>(ndiSend_));
        ndiSend_ = nullptr;
    }
    NDIlib_destroy();
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
    NDIlib_audio_frame_v2_t audio{};
    audio.sample_rate = frame.sampleRate;
    audio.no_channels = frame.channels;
    audio.no_samples = frame.samples;
    audio.timecode = NDIlib_send_timecode_synthesize;
    audio.p_data = const_cast<float*>(frame.planar.data());
    audio.channel_stride_in_bytes = frame.samples * static_cast<int>(sizeof(float));
    NDIlib_send_send_audio_v2(static_cast<NDIlib_send_instance_t>(ndiSend_), &audio);
#else
    if ((sentAudioFrames_ % 500) == 0) {
        Logger::info("Mock NDI audio frame ", sentAudioFrames_, " ", sourceName_, " samples=", frame.samples);
    }
#endif

    ++sentAudioFrames_;
    return true;
}
