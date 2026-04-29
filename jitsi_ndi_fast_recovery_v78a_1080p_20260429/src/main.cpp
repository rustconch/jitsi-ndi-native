#include "AppConfig.h"
#include "JitsiSignaling.h"
#include "Logger.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <exception>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace {
std::atomic<bool> g_running{true};

void handleSignal(int) {
    g_running = false;
}

#ifdef _WIN32
std::string wideToUtf8(const wchar_t* value) {
    if (!value) {
        return {};
    }

    const int needed = WideCharToMultiByte(
        CP_UTF8,
        0,
        value,
        -1,
        nullptr,
        0,
        nullptr,
        nullptr
    );

    if (needed <= 1) {
        return {};
    }

    std::string out(static_cast<std::size_t>(needed - 1), '\0');
    WideCharToMultiByte(
        CP_UTF8,
        0,
        value,
        -1,
        out.data(),
        needed,
        nullptr,
        nullptr
    );

    return out;
}
#endif

int runApp(int argc, char** argv) {
    std::signal(SIGINT, handleSignal);
    std::signal(SIGTERM, handleSignal);

    try {
        const AppConfig cfg = parseArgs(argc, argv);

        Logger::info("Starting jitsi-ndi-native");
        Logger::info("Room: ", cfg.room);
        Logger::info("Participant filter: ", cfg.participantFilter.empty() ? "<none>" : cfg.participantFilter);
        Logger::info("NDI base source name: ", cfg.ndiName);
        Logger::info("Display nick: ", cfg.nick);

        JitsiSignalingConfig signalingConfig;
        signalingConfig.room = cfg.room;
        signalingConfig.participantFilter = cfg.participantFilter;
        signalingConfig.nick = cfg.nick;
        signalingConfig.realXmpp = cfg.realXmpp;
        signalingConfig.websocketUrl = cfg.websocketUrl;
        signalingConfig.domain = cfg.domain;
        signalingConfig.guestDomain = cfg.guestDomain;
        signalingConfig.mucDomain = cfg.mucDomain;
        signalingConfig.guestMode = cfg.guestMode;
        signalingConfig.addRoomAndTokenToWebSocketUrl = cfg.addRoomAndTokenToWebSocketUrl;
        signalingConfig.authMode = cfg.authMode;
        signalingConfig.authUser = cfg.authUser;
        signalingConfig.authPassword = cfg.authPassword;
        signalingConfig.authToken = cfg.authToken;
        signalingConfig.ndiBaseName = cfg.ndiName.empty() ? "JitsiNativeNDI" : cfg.ndiName;

        JitsiSignaling signaling(signalingConfig);
        if (!signaling.connect()) {
            Logger::error("Jitsi signaling connect failed");
            return 2;
        }

        Logger::info("WebRTC native receiver started");
        Logger::info("Running Jitsi XMPP bootstrap + per-participant NDI media router. Press Ctrl+C to stop.");

        auto lastLog = std::chrono::steady_clock::now();

        // STABILITY_FAST_RECOVERY_V78:
        // Do not use full disconnect/connect as the primary recovery path.
        // Full reconnect is slow and can restore audio while leaving video unsubscribed.
        // Instead, keep the working Jitsi session alive and re-send receiver
        // subscriptions/constraints when video stalls or WebRTC raises a health hint.
        auto lastAudioProgress = std::chrono::steady_clock::now();
        auto lastVideoProgress = std::chrono::steady_clock::now();
        auto lastSoftRefresh = std::chrono::steady_clock::now() - std::chrono::minutes(5);
        auto lastHardStallLog = std::chrono::steady_clock::now() - std::chrono::minutes(5);

        std::uint64_t lastAudioPackets = signaling.audioPackets();
        std::uint64_t lastVideoPackets = signaling.videoPackets();
        std::uint64_t lastRecoveryHints = signaling.recoveryHints();

        bool sawAudioOnce = (lastAudioPackets != 0);
        bool sawVideoOnce = (lastVideoPackets != 0);

        while (g_running) {
            const auto now = std::chrono::steady_clock::now();
            const auto audioNow = signaling.audioPackets();
            const auto videoNow = signaling.videoPackets();
            const auto recoveryHintsNow = signaling.recoveryHints();

            const bool audioMoved = (audioNow != lastAudioPackets);
            const bool videoMoved = (videoNow != lastVideoPackets);

            if (audioMoved) {
                lastAudioPackets = audioNow;
                lastAudioProgress = now;
                sawAudioOnce = true;
            }

            if (videoMoved) {
                lastVideoPackets = videoNow;
                lastVideoProgress = now;
                sawVideoOnce = true;
            }

            if (now - lastLog > std::chrono::seconds(10)) {
                Logger::info(
                    "Runtime stats: audio RTP packets=", audioNow,
                    " video RTP packets=", videoNow
                );
                lastLog = now;
            }

            bool shouldSoftRefresh = false;
            std::string softRefreshReason;

            if (recoveryHintsNow != lastRecoveryHints) {
                const auto delta = recoveryHintsNow - lastRecoveryHints;
                lastRecoveryHints = recoveryHintsNow;

                Logger::warn(
                    "StabilityWatchdog: WebRTC health hint received, delta=",
                    delta,
                    "; requesting soft receiver refresh"
                );

                shouldSoftRefresh = true;
                softRefreshReason = "webrtc-health-hint";
            }

            const auto audioIdleSec = std::chrono::duration_cast<std::chrono::seconds>(
                now - lastAudioProgress
            ).count();

            const auto videoIdleSec = std::chrono::duration_cast<std::chrono::seconds>(
                now - lastVideoProgress
            ).count();

            const bool softRefreshCooldownPassed =
                (now - lastSoftRefresh > std::chrono::seconds(8));

            if (
                !shouldSoftRefresh &&
                sawVideoOnce &&
                videoIdleSec >= 8 &&
                softRefreshCooldownPassed
            ) {
                shouldSoftRefresh = true;
                softRefreshReason = "video-rtp-stall-" + std::to_string(videoIdleSec) + "s";
            }

            if (
                !shouldSoftRefresh &&
                sawAudioOnce &&
                sawVideoOnce &&
                audioIdleSec >= 12 &&
                videoIdleSec >= 12 &&
                softRefreshCooldownPassed
            ) {
                shouldSoftRefresh = true;
                softRefreshReason = "audio-video-rtp-stall";
            }

            if (shouldSoftRefresh && softRefreshCooldownPassed) {
                lastSoftRefresh = now;

                Logger::warn(
                    "StabilityWatchdog: v78 soft refresh, reason=",
                    softRefreshReason,
                    " audioIdleSec=",
                    audioIdleSec,
                    " videoIdleSec=",
                    videoIdleSec
                );

                if (!signaling.refreshReceiverSubscriptions(softRefreshReason)) {
                    Logger::warn(
                        "StabilityWatchdog: v78 soft refresh could not be sent; keeping session alive, no full reconnect"
                    );
                }
            }

            if (
                (sawAudioOnce || sawVideoOnce) &&
                audioIdleSec >= 30 &&
                videoIdleSec >= 30 &&
                now - lastHardStallLog > std::chrono::seconds(30)
            ) {
                lastHardStallLog = now;

                Logger::warn(
                    "StabilityWatchdog: hard RTP stall detected for audio=",
                    audioIdleSec,
                    "s video=",
                    videoIdleSec,
                    "s; v78 does not auto-disconnect because full reconnect was slow/unstable"
                );
            }

            std::this_thread::sleep_for(std::chrono::milliseconds(250));
        }

        signaling.disconnect();
        Logger::info("Stopped jitsi-ndi-native");
        return 0;
    } catch (const std::exception& e) {
        Logger::error("Fatal error: ", e.what());
        return 99;
    }
}
} // namespace

#ifdef _WIN32
int wmain(int argc, wchar_t** wargv) {
    std::vector<std::string> utf8Args;
    utf8Args.reserve(static_cast<std::size_t>(argc));

    for (int i = 0; i < argc; ++i) {
        utf8Args.push_back(wideToUtf8(wargv[i]));
    }

    std::vector<char*> argv;
    argv.reserve(utf8Args.size());
    for (std::string& arg : utf8Args) {
        argv.push_back(arg.data());
    }

    return runApp(argc, argv.data());
}
#else
int main(int argc, char** argv) {
    return runApp(argc, argv);
}
#endif
