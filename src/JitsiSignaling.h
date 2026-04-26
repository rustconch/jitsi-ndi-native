#pragma once

#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include "NativeWebRTCAnswerer.h"

class XmppWebSocketClient;

struct JitsiSignalingConfig {
    std::string room;
    std::string participantFilter;
    std::string nick = "probe123";

    bool realXmpp = true;

    std::string websocketUrl = "https://meet.jit.si/xmpp-websocket";
    std::string domain = "meet.jit.si";
    std::string guestDomain = "guest.meet.jit.si";
    std::string mucDomain = "conference.meet.jit.si";

    bool guestMode = true;
    bool addRoomAndTokenToWebSocketUrl = true;

    std::string authMode = "anonymous";
    std::string authUser;
    std::string authPassword;
    std::string authToken;
};

class JitsiSignaling {
public:
    explicit JitsiSignaling(JitsiSignalingConfig config);
    ~JitsiSignaling();

    bool connect();
    bool joinRoom();
    void disconnect();

private:
    static std::string sanitizeRoomName(const std::string& room);
    static std::string xmlEscape(const std::string& value);
    static std::string base64Encode(const std::string& value);
    static std::string urlEncode(const std::string& value);
    static std::string extractAttr(const std::string& tag, const std::string& name);
    static std::string firstTag(const std::string& xml, const std::string& tagName);
    static std::string htmlUnescape(std::string value);

    std::string websocketUrlForConnect() const;
    std::string activeXmppDomain() const;
    std::string roomJid() const;

    bool send(const std::string& xml);

    void sendOpen();
    void sendAuth();
    void sendBind();
    void sendSession();

    void sendIqResult(const std::string& to, const std::string& id);
    void sendDiscoInfoResult(const std::string& requestXml);

    void handleXmppMessage(const std::string& xml);
    void handleJingleSessionInitiate(const std::string& xml);

    void parseAndStoreTurnServices(const std::string& xml);

private:
    JitsiSignalingConfig config_;

    std::unique_ptr<XmppWebSocketClient> ws_;

    bool connected_ = false;
    bool authSucceeded_ = false;
    bool bindSent_ = false;
    bool sessionSent_ = false;
    bool joinSent_ = false;
    bool jingleSessionInitiateSeen_ = false;

    std::string boundJid_;

    std::atomic<int> incomingCount_{0};

    NativeWebRTCAnswerer webRtcAnswerer_;
    std::vector<std::string> iceServers_;
};
