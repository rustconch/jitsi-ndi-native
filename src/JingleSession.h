#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct JingleCodec {
    std::string name;
    int payloadType = -1;
    int clockRate = 0;
    int channels = 0;
};

struct JingleCandidate {
    std::string foundation;
    std::string component = "1";
    std::string protocol = "udp";
    std::string priority;
    std::string ip;
    std::string port;
    std::string type = "host";
    std::string id;
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
    std::string senders = "both";
    std::string iceUfrag;
    std::string icePwd;
    std::string fingerprintHash = "sha-256";
    std::string fingerprint;
    std::string setup = "actpass";
    std::vector<JingleCodec> codecs;
    std::vector<JingleCandidate> candidates;
    std::vector<JingleSource> sources;
};

struct JingleSession {
    std::string sid;
    std::string iqId;
    std::string from;
    std::string initiator;
    std::string bridgeSessionId;
    std::string region;
    std::vector<JingleContent> contents;

    const JingleContent* contentByName(const std::string& name) const;
    const JingleContent* audio() const { return contentByName("audio"); }
    const JingleContent* video() const { return contentByName("video"); }
};

struct LocalIceCandidate {
    std::string mid;
    std::string candidateLine;
    std::string foundation;
    std::string component = "1";
    std::string protocol = "udp";
    std::string priority;
    std::string ip;
    std::string port;
    std::string type = "host";
};

std::string xmlEscape(const std::string& s);
std::string xmlUnescape(std::string s);
std::string attrValue(const std::string& tag, const std::string& attr);
std::string findFirstTag(const std::string& xml, const std::string& tagName);
std::vector<std::string> findTags(const std::string& xml, const std::string& tagName);

bool parseJingleSessionInitiate(const std::string& xml, JingleSession& out);
bool parseTransportInfoCandidate(const std::string& xml, LocalIceCandidate& out);
bool parseLocalCandidateLine(const std::string& candidate, LocalIceCandidate& out);

std::string buildSdpOfferFromJingle(const JingleSession& session);
std::string buildJingleSessionAccept(
    const JingleSession& session,
    const std::string& responderJid,
    const std::string& id,
    const std::string& localIceUfrag,
    const std::string& localIcePwd,
    const std::string& localFingerprint);

std::string buildJingleTransportInfo(
    const std::string& to,
    const std::string& id,
    const std::string& sid,
    const std::string& localIceUfrag,
    const std::string& localIcePwd,
    const LocalIceCandidate& cand);
