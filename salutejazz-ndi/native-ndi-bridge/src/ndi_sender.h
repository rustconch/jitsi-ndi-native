#pragma once

#include <Processing.NDI.Lib.h>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>

namespace salutejazz_ndi {

// Wraps a single NDI sender — one network NDI source ("SaluteJazz NDI - Alice").
// Thread-safe: SendVideo / SendAudio can be called from multiple threads
// (a single mutex serialises calls into NDI SDK, since the SDK is not guaranteed
// to be reentrant per-instance for the v2/v3 send paths).
class NdiSender {
public:
    NdiSender(const std::string& sourceName, bool clockVideo, bool clockAudio);
    ~NdiSender();

    NdiSender(const NdiSender&) = delete;
    NdiSender& operator=(const NdiSender&) = delete;

    bool IsValid() const { return instance_ != nullptr; }
    const std::string& SourceName() const { return sourceName_; }

    // Release the NDI sender immediately while leaving this object alive
    // (so that its V8 finalizer can still safely free heap memory later).
    // Subsequent SendVideo/SendAudio calls become no-ops.
    void Reset();

    // VideoFrame from Chromium can come in different layouts. We accept the
    // raw plane buffer + stride and FourCC tag, no conversions on this side.
    // Supported FourCCs: NV12, I420, BGRA, BGRX, RGBA, RGBX, UYVY.
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

    // Planar float audio (FLTP) — that's what AudioData yields when copied
    // with format='f32-planar'. Channel stride in bytes is samples * 4.
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

// Process-wide NDI library lifetime helper. NDIlib_initialize must be called
// once before any senders are created and NDIlib_destroy at process exit.
class NdiLibraryGuard {
public:
    static bool EnsureInitialized();
    static void Shutdown();

private:
    static std::atomic<int> refCount_;
    static std::mutex initMutex_;
    static bool initialized_;
};

} // namespace salutejazz_ndi
