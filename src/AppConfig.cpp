#include "AppConfig.h"
#include "Logger.h"

#include <cstdlib>
#include <iostream>
#include <stdexcept>

namespace {

bool isFlag(const char* arg, const char* name) {
    return std::string(arg) == name;
}

std::string requireValue(int& i, int argc, char** argv, const char* flag) {
    if (i + 1 >= argc) {
        throw std::runtime_error(std::string("Missing value for ") + flag);
    }
    return argv[++i];
}

int toInt(const std::string& value, const char* flag) {
    try {
        return std::stoi(value);
    } catch (...) {
        throw std::runtime_error(std::string("Invalid integer for ") + flag + ": " + value);
    }
}

} // namespace

void printUsage() {
    std::cout
        << "jitsi-ndi-native\n"
        << "  --room ROOM_NAME                 Jitsi room name without URL\n"
        << "  --participant-filter TEXT        Optional display/source filter\n"
        << "  --ndi-name NAME                  NDI source name\n"
        << "  --nick NICK                      MUC nickname\n"
        << "  --width N                        Status pattern width\n"
        << "  --height N                       Status pattern height\n"
        << "  --fps N                          NDI/status frame rate\n"
        << "  --websocket-url URL              XMPP websocket URL\n"
        << "  --domain DOMAIN                  XMPP domain\n"
        << "  --guest-domain DOMAIN            Anonymous guest XMPP domain\n"
        << "  --muc-domain DOMAIN              MUC domain\n"
        << "  --no-real-xmpp                   Do not connect to Jitsi; NDI pattern only\n"
        << "  --no-ws-room-query               Do not append ?room=... to websocket URL\n"
        << "  --help                           Show this text\n";
}

AppConfig parseArgs(int argc, char** argv) {
    AppConfig cfg;

    for (int i = 1; i < argc; ++i) {
        const char* arg = argv[i];

        if (isFlag(arg, "--help") || isFlag(arg, "-h")) {
            printUsage();
            std::exit(0);
        } else if (isFlag(arg, "--room")) {
            cfg.room = requireValue(i, argc, argv, arg);
        } else if (isFlag(arg, "--participant-filter")) {
            cfg.participantFilter = requireValue(i, argc, argv, arg);
        } else if (isFlag(arg, "--ndi-name")) {
            cfg.ndiName = requireValue(i, argc, argv, arg);
        } else if (isFlag(arg, "--nick")) {
            cfg.nick = requireValue(i, argc, argv, arg);
        } else if (isFlag(arg, "--width")) {
            cfg.width = toInt(requireValue(i, argc, argv, arg), arg);
        } else if (isFlag(arg, "--height")) {
            cfg.height = toInt(requireValue(i, argc, argv, arg), arg);
        } else if (isFlag(arg, "--fps")) {
            cfg.fps = toInt(requireValue(i, argc, argv, arg), arg);
        } else if (isFlag(arg, "--websocket-url")) {
            cfg.websocketUrl = requireValue(i, argc, argv, arg);
        } else if (isFlag(arg, "--domain")) {
            cfg.domain = requireValue(i, argc, argv, arg);
        } else if (isFlag(arg, "--guest-domain")) {
            cfg.guestDomain = requireValue(i, argc, argv, arg);
        } else if (isFlag(arg, "--muc-domain")) {
            cfg.mucDomain = requireValue(i, argc, argv, arg);
        } else if (isFlag(arg, "--no-real-xmpp")) {
            cfg.realXmpp = false;
        } else if (isFlag(arg, "--no-ws-room-query")) {
            cfg.addRoomAndTokenToWebSocketUrl = false;
        } else if (isFlag(arg, "--auth-user")) {
            cfg.authUser = requireValue(i, argc, argv, arg);
            cfg.authMode = "plain";
            cfg.guestMode = false;
        } else if (isFlag(arg, "--auth-password")) {
            cfg.authPassword = requireValue(i, argc, argv, arg);
        } else if (isFlag(arg, "--token")) {
            cfg.authToken = requireValue(i, argc, argv, arg);
        } else {
            Logger::warn("Unknown argument ignored: ", arg);
        }
    }

    if (cfg.room.empty()) {
        cfg.room = "6767676766767penxyi";
        Logger::warn("No --room supplied, using test/default room: ", cfg.room);
    }

    if (cfg.width < 320) cfg.width = 320;
    if (cfg.height < 180) cfg.height = 180;
    if (cfg.fps <= 0 || cfg.fps > 120) cfg.fps = 30;

    return cfg;
}
