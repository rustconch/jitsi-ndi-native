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

// STABILITY_WATCHDOG_V77:
// If WebRTC dies, the NDI senders keep their last frames while RTP counters stop.
// Reconnect the Jitsi/XMPP session when audio/video RTP counters stay frozen.
auto lastPacketProgress = std::chrono::steady_clock::now();
auto lastReconnectAttempt = std::chrono::steady_clock::now() - std::chrono::minutes(5);
auto reconnectGraceUntil = std::chrono::steady_clock::now() + std::chrono::seconds(45);

std::uint64_t lastAudioPackets = signaling.audioPackets();
std::uint64_t lastVideoPackets = signaling.videoPackets();
bool sawRtpOnce = (lastAudioPackets != 0 || lastVideoPackets != 0);
int reconnectAttempt = 0;

while (g_running) {
    const auto now = std::chrono::steady_clock::now();
    const auto audioNow = signaling.audioPackets();
    const auto videoNow = signaling.videoPackets();

    const bool packetsMoved =
        (audioNow != lastAudioPackets) ||
        (videoNow != lastVideoPackets);

    if (packetsMoved) {
        lastAudioPackets = audioNow;
        lastVideoPackets = videoNow;
        lastPacketProgress = now;
        sawRtpOnce = true;
        reconnectAttempt = 0;
        reconnectGraceUntil = now;
    }

    if (now - lastLog > std::chrono::seconds(10)) {
        Logger::info(
            "Runtime stats: audio RTP packets=", audioNow,
            " video RTP packets=", videoNow
        );
        lastLog = now;
    }

    const auto stalledFor = std::chrono::duration_cast<std::chrono::seconds>(
        now - lastPacketProgress
    ).count();

    const bool mayReconnect =
        sawRtpOnce &&
        now >= reconnectGraceUntil &&
        (now - lastPacketProgress > std::chrono::seconds(25)) &&
        (now - lastReconnectAttempt > std::chrono::seconds(45));

    if (mayReconnect) {
        ++reconnectAttempt;
        lastReconnectAttempt = now;
        reconnectGraceUntil = now + std::chrono::seconds(45);

        Logger::warn(
            "StabilityWatchdog: RTP counters stalled for ",
            stalledFor,
            "s; reconnecting Jitsi session, attempt=",
            reconnectAttempt
        );

        signaling.disconnect();

        if (!g_running) {
            break;
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(1500));

        if (!signaling.connect()) {
            Logger::error("StabilityWatchdog: reconnect failed; will retry after cooldown");
        } else {
            Logger::info("StabilityWatchdog: reconnect started; waiting for fresh Jitsi media");
        }

        lastAudioPackets = signaling.audioPackets();
        lastVideoPackets = signaling.videoPackets();
        lastPacketProgress = std::chrono::steady_clock::now();
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
