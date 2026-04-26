#include "AppConfig.h"
#include "JitsiSignaling.h"
#include "Logger.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <exception>
#include <thread>

namespace {
std::atomic<bool> g_running{true};

void handleSignal(int) {
    g_running = false;
}
} // namespace

int main(int argc, char** argv) {
    std::signal(SIGINT, handleSignal);
    std::signal(SIGTERM, handleSignal);

    try {
        const AppConfig cfg = parseArgs(argc, argv);

        Logger::info("Starting jitsi-ndi-native");
        Logger::info("Room: ", cfg.room);
        Logger::info("Participant filter: ", cfg.participantFilter.empty() ? "<none>" : cfg.participantFilter);
        Logger::info("NDI base source name: ", cfg.ndiName);

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
        while (g_running) {
            const auto now = std::chrono::steady_clock::now();
            if (now - lastLog > std::chrono::seconds(10)) {
                Logger::info(
                    "Runtime stats: audio RTP packets=",
                    signaling.audioPackets(),
                    " video RTP packets=",
                    signaling.videoPackets()
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
