from __future__ import annotations

import re
import shutil
from datetime import datetime
from pathlib import Path


def find_project_root() -> Path:
    here = Path.cwd().resolve()
    candidates = [here, *here.parents, Path(__file__).resolve().parent, *Path(__file__).resolve().parents]
    for c in candidates:
        if (c / "src" / "JitsiSignaling.cpp").exists() and (c / "CMakeLists.txt").exists():
            return c
    raise SystemExit("Не нашёл корень проекта. Запусти скрипт из D:/MEDIA/Desktop/jitsi-ndi-native")


def backup_file(root: Path, rel: str, backup_root: Path) -> None:
    src = root / rel
    if not src.exists():
        raise SystemExit(f"Нет файла {rel}")
    dst = backup_root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text(encoding="utf-8", errors="replace")


def write(root: Path, rel: str, text: str) -> None:
    (root / rel).write_text(text, encoding="utf-8", newline="")


NDI_SENDER_H = r'''#pragma once

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
'''

NDI_SENDER_CPP = r'''#include "NDISender.h"

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
'''


def patch_jitsi_signaling(root: Path) -> None:
    text = read(root, "src/JitsiSignaling.cpp")
    # Remove every previous codecList append line, including the broken variant that
    # produced: </jitsi_participant_codecList>vp8,opus</presence>
    text2 = re.sub(
        r'^\s*xml\s*<<\s*"<jitsi_participant_codecList>.*?"\s*;\s*\n',
        '',
        text,
        flags=re.MULTILINE,
    )

    marker = '    xml << "</presence>";'
    if marker not in text2:
        marker = 'xml << "</presence>";'
    if marker not in text2:
        raise SystemExit("Не смог найти joinMuc()/</presence> в src/JitsiSignaling.cpp")

    good = '    xml << "<jitsi_participant_codecList>av1,vp8,opus</jitsi_participant_codecList>";\n'
    text2 = text2.replace(marker, good + marker, 1)
    write(root, "src/JitsiSignaling.cpp", text2)


def patch_participant_router(root: Path) -> None:
    text = read(root, "src/PerParticipantNdiRouter.cpp")
    old = r'''    auto source = sourceMap_.lookup(rtp.ssrc);

    if (!source) {
        ++unknownSsrcPackets_;

        if ((unknownSsrcPackets_ % 500) == 0) {
            Logger::warn(
                "PerParticipantNdiRouter: unknown SSRC ",
                RtpPacket::ssrcHex(rtp.ssrc),
                " mid=",
                mid,
                " pt=",
                static_cast<int>(payloadType)
            );
        }

        return;
    }

    const std::string media = !source->media.empty() ? source->media : mid;
'''
    new = r'''    auto source = sourceMap_.lookup(rtp.ssrc);

    if (!source) {
        ++unknownSsrcPackets_;

        // PATCH_V12_RECOVERY:
        // Do not drop all media just because Jitsi changed/omitted SSRC metadata.
        // The track MID still tells us whether the packet belongs to audio/video,
        // so create a safe SSRC-based fallback NDI source and keep packets flowing.
        JitsiSourceInfo fallback;
        fallback.ssrc = rtp.ssrc;
        fallback.media = (mid == "audio" || mid == "video") ? mid : "video";
        fallback.endpointId = std::string("ssrc-") + RtpPacket::ssrcHex(rtp.ssrc);
        fallback.displayName = fallback.endpointId;
        fallback.sourceName = fallback.endpointId + (fallback.media == "audio" ? "-a0" : "-v0");

        if (unknownSsrcPackets_ == 1 || (unknownSsrcPackets_ % 200) == 0) {
            Logger::warn(
                "PerParticipantNdiRouter: unknown SSRC ",
                RtpPacket::ssrcHex(rtp.ssrc),
                " mid=",
                mid,
                " pt=",
                static_cast<int>(payloadType),
                "; using fallback endpoint=",
                fallback.endpointId
            );
        }

        source = fallback;
    }

    const std::string media = !source->media.empty() ? source->media : mid;
'''
    if old not in text:
        raise SystemExit("Не смог найти блок unknown SSRC в src/PerParticipantNdiRouter.cpp — файл уже сильно отличается")
    write(root, "src/PerParticipantNdiRouter.cpp", text.replace(old, new, 1))


def patch_cmake(root: Path) -> None:
    text = read(root, "CMakeLists.txt")

    if '"${CMAKE_CURRENT_SOURCE_DIR}/NDI 6 SDK"' not in text:
        text = text.replace(
            'set(_ndi_guess_paths\n    "C:/Program Files/NDI/NDI 6 SDK"',
            'set(_ndi_guess_paths\n    "${CMAKE_CURRENT_SOURCE_DIR}/NDI 6 SDK"\n    "${CMAKE_CURRENT_SOURCE_DIR}/NDI SDK"\n    "C:/Program Files/NDI/NDI 6 SDK"',
            1,
        )

    if 'NDI_RUNTIME_DLL' not in text:
        find_library_block = r''')

if (JNN_WITH_REAL_NDI AND NDI_INCLUDE_DIR AND NDI_LIBRARY)'''
        runtime_find = r''')

find_file(
    NDI_RUNTIME_DLL
    NAMES Processing.NDI.Lib.x64.dll Processing.NDI.Lib.dll
    HINTS ${JNN_NDI_SDK_DIR} ${_ndi_guess_paths}
    PATH_SUFFIXES Bin/x64 Bin
)

if (JNN_WITH_REAL_NDI AND NDI_INCLUDE_DIR AND NDI_LIBRARY)'''
        if find_library_block not in text:
            raise SystemExit("Не смог найти блок NDI_LIBRARY в CMakeLists.txt")
        text = text.replace(find_library_block, runtime_find, 1)

        copy_block = r'''    target_link_libraries(jitsi-ndi-native PRIVATE ${NDI_LIBRARY})
    if (NDI_RUNTIME_DLL)
        add_custom_command(TARGET jitsi-ndi-native POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${NDI_RUNTIME_DLL}"
                "$<TARGET_FILE_DIR:jitsi-ndi-native>"
        )
        message(STATUS "NDI runtime DLL will be copied: ${NDI_RUNTIME_DLL}")
    else()
        message(WARNING "NDI runtime DLL was not found; NDI source may not appear until Processing.NDI.Lib.x64.dll is next to the exe or in PATH")
    endif()'''
        text = text.replace('    target_link_libraries(jitsi-ndi-native PRIVATE ${NDI_LIBRARY})', copy_block, 1)

    write(root, "CMakeLists.txt", text)


def basic_brace_check(root: Path, rel: str) -> None:
    text = read(root, rel)
    # Lightweight check only; ignores strings/comments, but catches the previous lone-brace problem.
    balance = 0
    for ch in text:
        if ch == '{':
            balance += 1
        elif ch == '}':
            balance -= 1
            if balance < 0:
                raise SystemExit(f"После патча подозрительный лишний }} в {rel}")
    if balance != 0:
        raise SystemExit(f"После патча подозрительный дисбаланс скобок в {rel}: {balance}")


def main() -> None:
    root = find_project_root()
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_root = root / ".jnn_patch_backups" / f"recovery_v12_{stamp}"

    files = [
        "CMakeLists.txt",
        "src/JitsiSignaling.cpp",
        "src/PerParticipantNdiRouter.cpp",
        "src/NDISender.cpp",
        "src/NDISender.h",
    ]
    for rel in files:
        backup_file(root, rel, backup_root)

    patch_jitsi_signaling(root)
    patch_participant_router(root)
    patch_cmake(root)
    write(root, "src/NDISender.h", NDI_SENDER_H)
    write(root, "src/NDISender.cpp", NDI_SENDER_CPP)

    for rel in ["src/JitsiSignaling.cpp", "src/PerParticipantNdiRouter.cpp", "src/NDISender.cpp", "src/NDISender.h"]:
        basic_brace_check(root, rel)

    print("OK: recovery_v12 applied")
    print(f"Backup: {backup_root}")
    print("Next:")
    print('  cmake -S . -B build -DJNN_NDI_SDK_DIR="D:/MEDIA/Desktop/jitsi-ndi-native/NDI 6 SDK"')
    print("  cmake --build build --config Release")


if __name__ == "__main__":
    main()
