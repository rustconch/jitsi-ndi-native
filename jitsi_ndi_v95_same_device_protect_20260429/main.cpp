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
        Logger::info("v95: global reconnect watchdog disabled; observer-safe join + camera stale-drop + source-local AV1 decoder reset");

        auto lastLog = std::chrono::steady_clock::now();
        std::uint64_t lastAudioPackets = signaling.audioPackets();
        std::uint64_t lastVideoPackets = signaling.videoPackets();
        auto lastPacketProgress = std::chrono::steady_clock::now();

        while (g_running) {
            const auto now = std::chrono::steady_clock::now();
            const auto audioNow = signaling.audioPackets();
            const auto videoNow = signaling.videoPackets();

            if (audioNow != lastAudioPackets || videoNow != lastVideoPackets) {
                lastAudioPackets = audioNow;
                lastVideoPackets = videoNow;
                lastPacketProgress = now;
            }

            if (now - lastLog > std::chrono::seconds(10)) {
                const auto stalledFor = std::chrono::duration_cast<std::chrono::seconds>(
                    now - lastPacketProgress
                ).count();

                Logger::info(
                    "Runtime stats: audio RTP packets=", audioNow,
                    " video RTP packets=", videoNow,
                    " noGlobalReconnect=1",
                    " lastPacketProgressSecAgo=", stalledFor
                );
                lastLog = now;
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
