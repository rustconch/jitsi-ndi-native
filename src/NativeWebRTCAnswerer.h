#pragma once

#include "JingleSession.h"

#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace rtc {
class PeerConnection;
class Track;
}

struct NativeWebRTCAnswerResult {
    bool ok = false;
    std::string error;
    std::string localSdp;
    std::string sessionAcceptXml;
};

class NativeWebRTCAnswerer {
public:
    using LocalCandidateCallback = std::function<void(const std::string& candidateXml)>;

    NativeWebRTCAnswerer();
    ~NativeWebRTCAnswerer();

    void setIceServers(std::vector<std::string> servers);
    void setResponderJid(std::string jid);

    NativeWebRTCAnswerResult acceptOffer(
        const JingleSessionInitiate& session,
        const std::string& offerSdp,
        LocalCandidateCallback localCandidateCallback
    );

    bool addRemoteCandidatesFromTransportInfo(const std::string& xml);

private:
    struct ParsedCandidate;

    void closeCurrentPeerConnection();
    void queueOrSendLocalCandidate(const std::string& candidateLine, const std::string& mid);
    void flushQueuedLocalCandidates();

    std::string buildSessionAcceptXml(const JingleSessionInitiate& session, const std::string& localSdp) const;
    std::string buildTransportInfoXml(const ParsedCandidate& c, const std::string& mid) const;

    static std::string xmlEscape(const std::string& value);
    static std::string extractSdpLineValue(const std::string& sdp, const std::string& prefix);
    static bool parseCandidateLine(const std::string& candidateLine, ParsedCandidate& out);
    static std::string attr(const std::string& tag, const std::string& name);
    static std::string firstTag(const std::string& xml, const std::string& tagName);

private:
    std::shared_ptr<rtc::PeerConnection> pc_;
    std::vector<std::string> iceServers_;

    std::string activeSid_;
    std::string activeResponder_;
    std::string activeInitiator_;
    std::string activeFocusJid_;
    std::string localUfrag_;
    std::string localPwd_;

    bool sessionAcceptSent_ = false;
    mutable int transportInfoCounter_ = 1;

    LocalCandidateCallback localCandidateCallback_;
    std::vector<std::pair<std::string, std::string>> queuedLocalCandidates_;
    std::mutex mutex_;
};
