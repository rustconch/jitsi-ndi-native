#include "NDISender.h"
#include "Logger.h"

#include <utility>

#if JNN_HAS_NDI
#include <Processing.NDI.Lib.h>
#endif

struct NDISender::Impl {
#if JNN_HAS_NDI
    NDIlib_send_instance_t sender = nullptr;
#endif
    bool started = false;
};

NDISender::NDISender(std::string sourceName)
    : sourceName_(std::move(sourceName)), impl_(std::make_unique<Impl>()) {}

NDISender::~NDISender() {
    stop();
}

bool NDISender::start() {
    if (impl_->started) return true;

#if JNN_HAS_NDI
    if (!NDIlib_initialize()) {
        Logger::error("NDI initialize failed");
        return false;
    }

    NDIlib_send_create_t desc{};
    desc.p_ndi_name = sourceName_.c_str();
    desc.p_groups = nullptr;
    desc.clock_video = false;
    desc.clock_audio = false;

    impl_->sender = NDIlib_send_create(&desc);
    if (!impl_->sender) {
        Logger::error("Could not create NDI sender: ", sourceName_);
        return false;
    }

    impl_->started = true;
    Logger::info("Real NDI sender started: ", sourceName_);
    return true;
#else
    impl_->started = true;
    Logger::warn("Mock NDI sender started: ", sourceName_, " (NDI SDK was not linked)");
    return true;
#endif
}

void NDISender::stop() {
    if (!impl_ || !impl_->started) return;

#if JNN_HAS_NDI
    if (impl_->sender) {
        NDIlib_send_destroy(impl_->sender);
        impl_->sender = nullptr;
    }
    NDIlib_destroy();
#endif

    impl_->started = false;
}

bool NDISender::sendFrame(const VideoFrameBGRA& frame, int fpsNumerator, int fpsDenominator) {
    if (!impl_->started) return false;

#if JNN_HAS_NDI
    if (!impl_->sender || frame.pixels.empty()) return false;

    NDIlib_video_frame_v2_t vf{};
    vf.xres = frame.width;
    vf.yres = frame.height;
    vf.FourCC = NDIlib_FourCC_type_BGRA;
    vf.frame_rate_N = fpsNumerator;
    vf.frame_rate_D = fpsDenominator;
    vf.picture_aspect_ratio = static_cast<float>(frame.width) / static_cast<float>(frame.height);
    vf.frame_format_type = NDIlib_frame_format_type_progressive;
    vf.timecode = NDIlib_send_timecode_synthesize;
    vf.p_data = const_cast<std::uint8_t*>(frame.pixels.data());
    vf.line_stride_in_bytes = frame.strideBytes;

    NDIlib_send_send_video_v2(impl_->sender, &vf);
#else
    (void)frame;
    (void)fpsNumerator;
    (void)fpsDenominator;
#endif

    return true;
}
