#pragma once

#include <string>

struct AppConfig {
    std::string room = "test-room";
    std::string participantFilter;
    std::string ndiName = "JitsiNativeNDI";
    std::string nick = "probe123";

    bool realXmpp = true;
    bool guestMode = true;
    bool addRoomAndTokenToWebSocketUrl = true;

    std::string websocketUrl = "https://meet.jit.si/xmpp-websocket";
    std::string domain = "meet.jit.si";
    std::string guestDomain = "guest.meet.jit.si";
    std::string mucDomain = "conference.meet.jit.si";

    std::string authMode = "anonymous";
    std::string authUser;
    std::string authPassword;
    std::string authToken;

    int width = 1280;
    int height = 720;
    int fps = 30;
};

AppConfig parseArgs(int argc, char** argv);
void printUsage();
