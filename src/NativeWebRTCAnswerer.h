#pragma once

#include "JingleSession.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

class NativeWebRTCAnswerer {
public:
    struct IceServer {
        std::string uri;
    };

    struct Answer {
        std::string sdp;
        std::string iceUfrag;
        std::string icePwd;
        std::string fingerprint;
    };

    using LocalCandidateCallback = std::function<void(const LocalIceCandidate&)>;
    using MediaPacketCallback = std::function<void(const std::string& mid, const std::uint8_t* data, std::size_t size)>;
    using SessionFailureCallback = std::function<void(const std::string& reason)>;
    // Fired when the JVB data channel delivers an EndpointMessage from a peer
    // (e.g. move_to_room_request from the moderator). Receives the raw JSON text.
    using EndpointMessageCallback = std::function<void(const std::string& messageJson)>;

    NativeWebRTCAnswerer();
    ~NativeWebRTCAnswerer();

    NativeWebRTCAnswerer(const NativeWebRTCAnswerer&) = delete;
    NativeWebRTCAnswerer& operator=(const NativeWebRTCAnswerer&) = delete;

    void setIceServers(std::vector<IceServer> servers);
    void setLocalCandidateCallback(LocalCandidateCallback cb);
    void setMediaPacketCallback(MediaPacketCallback cb);
    void setSessionFailureCallback(SessionFailureCallback cb);
    void setEndpointMessageCallback(EndpointMessageCallback cb);

    bool createAnswer(const JingleSession& session, Answer& outAnswer);
    void updateReceiverSourcesFromJingleXml(const std::string& xml);
    void addRemoteCandidate(const LocalIceCandidate& candidate);
    void resetSession();

    // v101: send RTCP PLI to ask the JVB for a keyframe on the video track.
    // Called by PerParticipantNdiRouter when an AV1 stall is detected.
    void requestVideoKeyframe();

    std::uint64_t audioPackets() const { return audioPackets_; }
    std::uint64_t videoPackets() const { return videoPackets_; }
    std::uint64_t audioBytes() const { return audioBytes_; }
    std::uint64_t videoBytes() const { return videoBytes_; }

private:
    void notifySessionFailureOnce(std::uint64_t generation, const std::string& reason);

    struct Impl;
    std::unique_ptr<Impl> impl_;

    std::vector<IceServer> iceServers_;
    LocalCandidateCallback onLocalCandidate_;
    MediaPacketCallback onMediaPacket_;
    SessionFailureCallback onSessionFailure_;
    EndpointMessageCallback onEndpointMessage_;

    std::atomic<std::uint64_t> audioPackets_{0};
    std::atomic<std::uint64_t> videoPackets_{0};
    std::atomic<std::uint64_t> audioBytes_{0};
    std::atomic<std::uint64_t> videoBytes_{0};
};
