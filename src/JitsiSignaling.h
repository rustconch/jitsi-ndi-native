#pragma once

#include "JingleSession.h"
#include "NativeWebRTCAnswerer.h"
#include "XmppWebSocketClient.h"

#include <atomic>
#include <mutex>
#include <string>
#include <vector>

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
    void disconnect();

    std::uint64_t audioPackets() const { return answerer_.audioPackets(); }
    std::uint64_t videoPackets() const { return answerer_.videoPackets(); }

private:
    void handleXmppMessage(const std::string& xml);
    void sendRaw(const std::string& xml);
    void sendOpen();
    void sendAnonymousAuth();
    void sendBind();
    void sendSession();
    void joinMuc();
    void sendIqResult(const std::string& to, const std::string& id);
    void sendDiscoInfoResult(const std::string& to, const std::string& id);
    void handleRoomMetadata(const std::string& xml);
    void handleJingleInitiate(const std::string& xml);
    void flushPendingCandidates();

    std::string activeDomain() const;
    std::string mucJid() const;
    std::string buildConnectUrl() const;
    std::string makeIqId(const std::string& prefix);

    JitsiSignalingConfig cfg_;
    XmppWebSocketClient ws_;
    NativeWebRTCAnswerer answerer_;

    std::atomic<bool> connected_{false};
    std::atomic<int> iqCounter_{1};
    std::mutex mutex_;

    std::string boundJid_;
    std::string currentSid_;
    std::string currentFocusJid_;
    std::string currentIceUfrag_;
    std::string currentIcePwd_;
	std::vector<std::string> currentContentNames_;
	bool sessionAcceptSent_ = false;
	std::vector<LocalIceCandidate> pendingLocalCandidates_;
};
