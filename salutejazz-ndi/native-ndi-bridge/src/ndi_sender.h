#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <string>

#include <Processing.NDI.Lib.h>
#include <Processing.NDI.DynamicLoad.h>

namespace salutejazz_ndi {

// Thread-safe NDI sender for one network NDI source ("SaluteJazz NDI - Alice").
// Uses dynamic loading (dlopen/LoadLibrary) so the addon compiles without
// linking against a static NDI import library — the runtime is loaded at first
// use from the path indicated by the NDI_RUNTIME_DIR_V6 env var.
class NdiSender {
public:
    NdiSender(const std::string& sourceName, bool clockVideo, bool clockAudio);
    ~NdiSender();

    NdiSender(const NdiSender&) = delete;
    NdiSender& operator=(const NdiSender&) = delete;

    bool IsValid() const { return instance_ != nullptr; }
    const std::string& SourceName() const { return sourceName_; }

    // Release the NDI sender immediately while leaving this object alive
    // (so its V8 finalizer can still safely free heap memory later).
    // Subsequent SendVideo/SendAudio calls become no-ops.
    void Reset();

    // Raw plane buffer + stride + FourCC (NV12/I420/BGRA/BGRX/RGBA/RGBX/UYVY).
    bool SendVideo(
        const uint8_t* data,
        size_t dataSize,
        int width,
        int height,
        int strideOrSize,
        uint32_t fourCC,
        int frameRateN,
        int frameRateD,
        int64_t timecode100ns
    );

    // Planar f32 audio (FLTP) — as produced by AudioData.copyTo(f32-planar).
    // channelStrideBytes == numSamples * sizeof(float) for packed planar.
    bool SendAudio(
        const float* planarData,
        int sampleRate,
        int numChannels,
        int numSamples,
        int channelStrideBytes,
        int64_t timecode100ns
    );

private:
    std::string sourceName_;
    NDIlib_send_instance_t instance_;
    std::mutex sendMutex_;
};

// Process-wide NDI library lifetime. Dynamically loads libndi.so.6 / .dll
// on first use, calls NDIlib_initialize, and reference-counts callers.
class NdiLibraryGuard {
public:
    static bool EnsureInitialized();
    static void Shutdown();
    static const NDIlib_v6* GetLib() { return p_ndi_lib_; }

private:
    static std::atomic<int> refCount_;
    static std::mutex initMutex_;
    static bool initialized_;
    static const NDIlib_v6* p_ndi_lib_;
    static void* lib_handle_;
};

} // namespace salutejazz_ndi
