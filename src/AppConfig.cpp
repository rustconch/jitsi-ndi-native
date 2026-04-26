#include "AppConfig.h"
#include "Logger.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {
std::string nextArg(int& i, int argc, char** argv, const std::string& key) {
    if (i + 1 >= argc) {
        Logger::warn("Missing value for ", key);
        return {};
    }
    return argv[++i];
}
}

void printUsage() {
    std::cout << "jitsi-ndi-native --room ROOM [options]\n"
              << "\nOptions:\n"
              << "  --room ROOM\n"
              << "  --participant FILTER\n"
              << "  --ndi-name NAME\n"
              << "  --nick NICK\n"
              << "  --width PX --height PX --fps N\n"
              << "  --no-real-xmpp\n"
              << "  --no-guest\n"
              << "  --no-ws-room-query\n"
              << "  --xmpp-websocket URL\n"
              << "  --domain DOMAIN\n"
              << "  --guest-domain DOMAIN\n"
              << "  --muc-domain DOMAIN\n"
              << "  --auth-mode anonymous|plain|xoauth2|oauthbearer\n"
              << "  --auth-user USER --auth-password PASS --auth-token TOKEN\n";
}

AppConfig parseArgs(int argc, char** argv) {
    AppConfig cfg;

    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];

        if (a == "--help" || a == "-h") {
            printUsage();
            std::exit(0);
        } else if (a == "--room") {
            cfg.room = nextArg(i, argc, argv, a);
        } else if (a == "--participant") {
            cfg.participantFilter = nextArg(i, argc, argv, a);
        } else if (a == "--ndi-name") {
            cfg.ndiName = nextArg(i, argc, argv, a);
        } else if (a == "--nick") {
            cfg.nick = nextArg(i, argc, argv, a);
        } else if (a == "--width") {
            cfg.width = std::max(16, std::atoi(nextArg(i, argc, argv, a).c_str()));
        } else if (a == "--height") {
            cfg.height = std::max(16, std::atoi(nextArg(i, argc, argv, a).c_str()));
        } else if (a == "--fps") {
            cfg.fps = std::max(1, std::atoi(nextArg(i, argc, argv, a).c_str()));
        } else if (a == "--no-real-xmpp") {
            cfg.realXmpp = false;
        } else if (a == "--no-guest") {
            cfg.guestMode = false;
        } else if (a == "--no-ws-room-query") {
            cfg.addRoomAndTokenToWebSocketUrl = false;
        } else if (a == "--xmpp-websocket") {
            cfg.websocketUrl = nextArg(i, argc, argv, a);
        } else if (a == "--domain") {
            cfg.domain = nextArg(i, argc, argv, a);
        } else if (a == "--guest-domain") {
            cfg.guestDomain = nextArg(i, argc, argv, a);
        } else if (a == "--muc-domain") {
            cfg.mucDomain = nextArg(i, argc, argv, a);
        } else if (a == "--auth-mode") {
            cfg.authMode = nextArg(i, argc, argv, a);
        } else if (a == "--auth-user") {
            cfg.authUser = nextArg(i, argc, argv, a);
        } else if (a == "--auth-password") {
            cfg.authPassword = nextArg(i, argc, argv, a);
        } else if (a == "--auth-token") {
            cfg.authToken = nextArg(i, argc, argv, a);
        } else if (!a.empty() && a[0] != '-') {
            cfg.room = a;
        } else {
            Logger::warn("Unknown argument: ", a);
        }
    }

    return cfg;
}
