#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct JinglePayloadType {
    int id = -1;
    std::string name;
    int clockrate = 0;
    int channels = 0;
};

struct JingleCandidate {
    std::string foundation;
    int component = 1;
    std::string protocol = "udp";
    std::uint32_t priority = 0;
    std::string ip;
    int port = 0;
    std::string type = "host";
    std::string relAddr;
    int relPort = 0;
};

struct JingleSource {
    std::uint32_t ssrc = 0;
    std::string owner;
    std::string name;
    std::string videoType;
};

struct JingleContent {
    std::string name;
    std::string media;
    std::string iceUfrag;
    std::string icePwd;
    std::string fingerprintHash = "sha-256";
    std::string fingerprint;
    std::string dtlsSetup = "actpass";
    std::vector<JinglePayloadType> payloads;
    std::vector<JingleCandidate> candidates;
    std::vector<JingleSource> sources;
};

struct JingleSessionInitiate {
    bool valid = false;
    std::string sid;
    std::string iqId;
    std::string from;
    std::string initiator;
    std::string bridgeSessionId;
    std::string region;
    std::vector<JingleContent> contents;

    const JingleContent* findContent(const std::string& name) const;
    std::string toSdpOffer() const;
    std::string summary() const;
};

class JingleSessionParser {
public:
    static bool isSessionInitiate(const std::string& xml);
    static JingleSessionInitiate parseSessionInitiate(const std::string& xml);
};
