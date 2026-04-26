#include "AppConfig.h"
#include "JitsiSignaling.h"
#include "Logger.h"
#include "NDISender.h"
#include "TestPattern.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <thread>

namespace {
std::atomic<bool> g_running{true};

void handleSignal(int) {
    g_running = false;
}
}

int main(int argc, char** argv) {
    std::signal(SIGINT, handleSignal);
    std::signal(SIGTERM, handleSignal);

    const AppConfig cfg = parseArgs(argc, argv);

    Logger::info("Starting jitsi-ndi-native");
    Logger::info("Room: ", cfg.room);
    Logger::info("Participant filter: ", cfg.participantFilter.empty() ? "<none>" : cfg.participantFilter);
    Logger::info("NDI source name: ", cfg.ndiName);

    NDISender ndi(cfg.ndiName);
    if (!ndi.start()) {
        Logger::error("Could not start NDI sender");
        return 1;
    }

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

    JitsiSignaling signaling(signalingConfig);
    if (!signaling.connect()) {
        Logger::error("Jitsi signaling connect failed");
        return 2;
    }

    Logger::info("WebRTC stub client started");
    Logger::info("Running Jitsi XMPP bootstrap + test-pattern NDI mode. Press Ctrl+C to stop.");

    TestPattern pattern(cfg.width, cfg.height);
    const int fps = cfg.fps > 0 ? cfg.fps : 30;
    const auto delay = std::chrono::milliseconds(1000 / fps);

    while (g_running) {
        VideoFrameBGRA frame = pattern.nextFrame();
        ndi.sendFrame(frame, fps, 1);
        std::this_thread::sleep_for(delay);
    }

    signaling.disconnect();
    ndi.stop();
    Logger::info("Stopped jitsi-ndi-native");
    return 0;
}
