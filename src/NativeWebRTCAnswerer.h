#pragma once

#include "JingleSession.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
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

    NativeWebRTCAnswerer();
    ~NativeWebRTCAnswerer();

    NativeWebRTCAnswerer(const NativeWebRTCAnswerer&) = delete;
    NativeWebRTCAnswerer& operator=(const NativeWebRTCAnswerer&) = delete;

    void setIceServers(std::vector<IceServer> servers);
    void setLocalCandidateCallback(LocalCandidateCallback cb);

    bool createAnswer(const JingleSession& session, Answer& outAnswer);
    void addRemoteCandidate(const LocalIceCandidate& candidate);
    void resetSession();

    std::uint64_t audioPackets() const { return audioPackets_; }
    std::uint64_t videoPackets() const { return videoPackets_; }
    std::uint64_t audioBytes() const { return audioBytes_; }
    std::uint64_t videoBytes() const { return videoBytes_; }

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;

    std::vector<IceServer> iceServers_;
    LocalCandidateCallback onLocalCandidate_;

    std::atomic<std::uint64_t> audioPackets_{0};
    std::atomic<std::uint64_t> videoPackets_{0};
    std::atomic<std::uint64_t> audioBytes_{0};
    std::atomic<std::uint64_t> videoBytes_{0};
};
