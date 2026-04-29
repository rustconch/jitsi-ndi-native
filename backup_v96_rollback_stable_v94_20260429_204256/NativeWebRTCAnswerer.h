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

    NativeWebRTCAnswerer();
    ~NativeWebRTCAnswerer();

    NativeWebRTCAnswerer(const NativeWebRTCAnswerer&) = delete;
    NativeWebRTCAnswerer& operator=(const NativeWebRTCAnswerer&) = delete;

    void setIceServers(std::vector<IceServer> servers);
    void setLocalCandidateCallback(LocalCandidateCallback cb);
    void setMediaPacketCallback(MediaPacketCallback cb);
    void setSessionFailureCallback(SessionFailureCallback cb);

    bool createAnswer(const JingleSession& session, Answer& outAnswer);
    void updateReceiverSourcesFromJingleXml(const std::string& xml);
    void addRemoteCandidate(const LocalIceCandidate& candidate);
    void resetSession();

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

    std::atomic<std::uint64_t> audioPackets_{0};
    std::atomic<std::uint64_t> videoPackets_{0};
    std::atomic<std::uint64_t> audioBytes_{0};
    std::atomic<std::uint64_t> videoBytes_{0};
};
