#include "ndi_sender.h"

#include <cstring>
#include <cstdlib>
#include <string>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace salutejazz_ndi {

// --- NdiLibraryGuard statics ---

std::atomic<int> NdiLibraryGuard::refCount_{0};
std::mutex NdiLibraryGuard::initMutex_;
bool NdiLibraryGuard::initialized_ = false;
const NDIlib_v6* NdiLibraryGuard::p_ndi_lib_ = nullptr;
void* NdiLibraryGuard::lib_handle_ = nullptr;

static void* PlatformLoadNdi() {
    std::string lib_path;
    const char* runtime_dir = getenv(NDILIB_REDIST_FOLDER);
    if (runtime_dir) {
#ifdef _WIN32
        lib_path = std::string(runtime_dir) + "\\" + NDILIB_LIBRARY_NAME;
#else
        lib_path = std::string(runtime_dir) + "/" + NDILIB_LIBRARY_NAME;
#endif
    } else {
        lib_path = NDILIB_LIBRARY_NAME;
    }

#ifdef _WIN32
    return static_cast<void*>(LoadLibraryA(lib_path.c_str()));
#else
    return dlopen(lib_path.c_str(), RTLD_LOCAL | RTLD_LAZY);
#endif
}

static const NDIlib_v6* PlatformResolveVtable(void* handle) {
    if (!handle) return nullptr;
    using LoadFn = const NDIlib_v6* (*)(void);
    LoadFn fn = nullptr;
#ifdef _WIN32
    *reinterpret_cast<FARPROC*>(&fn) =
        GetProcAddress(static_cast<HMODULE>(handle), "NDIlib_v6_load");
#else
    *reinterpret_cast<void**>(&fn) = dlsym(handle, "NDIlib_v6_load");
#endif
    return fn ? fn() : nullptr;
}

static void PlatformUnloadNdi(void* handle) {
    if (!handle) return;
#ifdef _WIN32
    FreeLibrary(static_cast<HMODULE>(handle));
#else
    dlclose(handle);
#endif
}

bool NdiLibraryGuard::EnsureInitialized() {
    std::lock_guard<std::mutex> lock(initMutex_);
    if (initialized_) {
        refCount_.fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    lib_handle_ = PlatformLoadNdi();
    p_ndi_lib_ = PlatformResolveVtable(lib_handle_);
    if (!p_ndi_lib_) {
        PlatformUnloadNdi(lib_handle_);
        lib_handle_ = nullptr;
        return false;
    }

    if (!p_ndi_lib_->initialize()) {
        PlatformUnloadNdi(lib_handle_);
        lib_handle_ = nullptr;
        p_ndi_lib_ = nullptr;
        return false;
    }

    initialized_ = true;
    refCount_.store(1, std::memory_order_relaxed);
    return true;
}

void NdiLibraryGuard::Shutdown() {
    std::lock_guard<std::mutex> lock(initMutex_);
    if (!initialized_) return;
    int prev = refCount_.fetch_sub(1, std::memory_order_acq_rel);
    if (prev <= 1) {
        if (p_ndi_lib_) p_ndi_lib_->destroy();
        p_ndi_lib_ = nullptr;
        PlatformUnloadNdi(lib_handle_);
        lib_handle_ = nullptr;
        initialized_ = false;
    }
}

// --- NdiSender ---

NdiSender::NdiSender(const std::string& sourceName, bool clockVideo, bool clockAudio)
    : sourceName_(sourceName), instance_(nullptr) {
    if (!NdiLibraryGuard::EnsureInitialized()) {
        return;
    }
    const NDIlib_v6* lib = NdiLibraryGuard::GetLib();
    NDIlib_send_create_t desc = {};
    desc.p_ndi_name = sourceName_.c_str();
    desc.p_groups = nullptr;
    desc.clock_video = clockVideo;
    desc.clock_audio = clockAudio;
    instance_ = lib->send_create(&desc);
}

NdiSender::~NdiSender() {
    Reset();
    NdiLibraryGuard::Shutdown();
}

void NdiSender::Reset() {
    std::lock_guard<std::mutex> lock(sendMutex_);
    if (instance_) {
        const NDIlib_v6* lib = NdiLibraryGuard::GetLib();
        if (lib) {
            // Flush any pending async sends before destroying.
            lib->send_send_video_v2(instance_, nullptr);
            lib->send_destroy(instance_);
        }
        instance_ = nullptr;
    }
}

bool NdiSender::SendVideo(
    const uint8_t* data,
    size_t dataSize,
    int width,
    int height,
    int strideOrSize,
    uint32_t fourCC,
    int frameRateN,
    int frameRateD,
    int64_t timecode100ns
) {
    if (!data || width <= 0 || height <= 0) return false;

    std::lock_guard<std::mutex> lock(sendMutex_);
    if (!instance_) return false;
    const NDIlib_v6* lib = NdiLibraryGuard::GetLib();
    if (!lib) return false;

    NDIlib_video_frame_v2_t frame = {};
    frame.xres = width;
    frame.yres = height;
    frame.FourCC = static_cast<NDIlib_FourCC_video_type_e>(fourCC);
    frame.frame_rate_N = frameRateN > 0 ? frameRateN : 30000;
    frame.frame_rate_D = frameRateD > 0 ? frameRateD : 1001;
    frame.picture_aspect_ratio = 0.0f; // square pixels
    frame.frame_format_type = NDIlib_frame_format_type_progressive;
    frame.timecode = timecode100ns ? timecode100ns : NDIlib_send_timecode_synthesize;
    frame.line_stride_in_bytes = strideOrSize;
    frame.p_data = const_cast<uint8_t*>(data);
    frame.p_metadata = nullptr;
    (void)dataSize;

    lib->send_send_video_v2(instance_, &frame);
    return true;
}

bool NdiSender::SendAudio(
    const float* planarData,
    int sampleRate,
    int numChannels,
    int numSamples,
    int channelStrideBytes,
    int64_t timecode100ns
) {
    if (!planarData || numChannels <= 0 || numSamples <= 0) return false;

    std::lock_guard<std::mutex> lock(sendMutex_);
    if (!instance_) return false;
    const NDIlib_v6* lib = NdiLibraryGuard::GetLib();
    if (!lib) return false;

    NDIlib_audio_frame_v3_t frame = {};
    frame.sample_rate = sampleRate;
    frame.no_channels = numChannels;
    frame.no_samples = numSamples;
    frame.timecode = timecode100ns ? timecode100ns : NDIlib_send_timecode_synthesize;
    frame.FourCC = NDIlib_FourCC_audio_type_FLTP;
    frame.p_data = reinterpret_cast<uint8_t*>(const_cast<float*>(planarData));
    frame.channel_stride_in_bytes = channelStrideBytes > 0
        ? channelStrideBytes
        : numSamples * static_cast<int>(sizeof(float));
    frame.p_metadata = nullptr;

    lib->send_send_audio_v3(instance_, &frame);
    return true;
}

} // namespace salutejazz_ndi
