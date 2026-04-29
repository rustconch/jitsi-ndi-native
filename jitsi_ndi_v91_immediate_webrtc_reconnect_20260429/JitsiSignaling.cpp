#include "JitsiSignaling.h"


#include <algorithm>
#include <cctype>
#include "Logger.h"

#include <regex>
#include <sstream>
#include <utility>

#include <string>










namespace {

bool contains(const std::string& s, const std::string& needle) {
    return s.find(needle) != std::string::npos;
}

bool containsAnyQuoteAttr(
    const std::string& xml,
    const std::string& attr,
    const std::string& value
) {
    return contains(xml, attr + "='" + value + "'")
        || contains(xml, attr + "=\"" + value + "\"");
}

bool isIqType(const std::string& xml, const std::string& type) {
    return containsAnyQuoteAttr(xml, "type", type);
}

bool isIqId(const std::string& xml, const std::string& id) {
    return containsAnyQuoteAttr(xml, "id", id);
}

bool isIqIdPrefix(const std::string& xml, const std::string& prefix) {
    return contains(xml, "id='" + prefix)
        || contains(xml, "id=\"" + prefix);
}

std::string appendQueryParam(
    std::string url,
    const std::string& key,
    const std::string& value
) {
    if (value.empty()) {
        return url;
    }

    url += (url.find('?') == std::string::npos) ? '?' : '&';
    url += key;
    url += '=';
    url += value;

    return url;
}

std::string jsonUnescape(std::string s) {
    std::size_t pos = 0;

    while ((pos = s.find("&quot;", pos)) != std::string::npos) {
        s.replace(pos, 6, "\"");
        pos += 1;
    }

    return xmlUnescape(s);
}

std::string extractJsonString(const std::string& json, const std::string& key) {
    const std::regex re("\\\"" + key + R"(\\\"\s*:\s*\\\"([^\\\"]+)\\\")");
    std::smatch m;

    if (std::regex_search(json, m, re) && m.size() > 1) {
        return m[1].str();
    }

    return {};
}

std::string extractIqAttr(const std::string& xml, const std::string& name) {
    const std::string iqTag = findFirstTag(xml, "iq");

    if (iqTag.empty()) {
        return {};
    }

    return xmlUnescape(attrValue(iqTag, name));
}

std::string xmlBool(bool value) {
    return value ? "true" : "false";
}

bool isTurnUserInfoUnreserved(unsigned char c) {
    return (c >= 'A' && c <= 'Z')
        || (c >= 'a' && c <= 'z')
        || (c >= '0' && c <= '9')
        || c == '-'
        || c == '_'
        || c == '.'
        || c == '~';
}

std::string percentEncodeTurnUserInfo(const std::string& value) {
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    out.reserve(value.size());

    for (unsigned char c : value) {
        if (isTurnUserInfoUnreserved(c)) {
            out.push_back(static_cast<char>(c));
            continue;
        }

        out.push_back('%');
        out.push_back(hex[(c >> 4) & 0x0F]);
        out.push_back(hex[c & 0x0F]);
    }

    return out;
}
} // namespace

JitsiSignaling::JitsiSignaling(JitsiSignalingConfig config)
    : cfg_(std::move(config)),
      ndiRouter_(std::make_unique<PerParticipantNdiRouter>(cfg_.ndiBaseName)) {
    answerer_.setLocalCandidateCallback([this](const LocalIceCandidate& cand) {
        bool shouldFlush = false;

        {
            std::lock_guard<std::mutex> lock(mutex_);

            pendingLocalCandidates_.push_back(cand);

            if (!sessionAcceptSent_ || currentSid_.empty() || currentFocusJid_.empty()) {
                Logger::info("NativeWebRTCAnswerer: local ICE candidate queued until session-accept is sent");
                return;
            }

            shouldFlush = true;
        }

        if (shouldFlush) {
            flushPendingCandidates();
        }
    });

    answerer_.setMediaPacketCallback([this](
        const std::string& mid,
        const std::uint8_t* data,
        std::size_t size
    ) {
        if (!ndiRouter_) {
            return;
        }

        ndiRouter_->handleRtp(mid, data, size);
    });

    answerer_.setSessionFailureCallback([this](const std::string& reason) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            lastMediaFailureReason_ = reason;
        }

        mediaRecoveryRequested_.store(true);

        Logger::warn(
            "JitsiSignaling: v91 media recovery requested by NativeWebRTCAnswerer, reason=",
            reason
        );
    });
}

JitsiSignaling::~JitsiSignaling() {
    disconnect();
}

bool JitsiSignaling::consumeMediaRecoveryRequest(std::string* reason) {
    if (!mediaRecoveryRequested_.exchange(false)) {
        return false;
    }

    if (reason) {
        std::lock_guard<std::mutex> lock(mutex_);
        *reason = lastMediaFailureReason_;
    }

    return true;
}

std::string JitsiSignaling::activeDomain() const {
    return cfg_.guestMode ? cfg_.guestDomain : cfg_.domain;
}

std::string JitsiSignaling::bareMucJid() const {
    return cfg_.room + "@" + cfg_.mucDomain;
}

std::string JitsiSignaling::mucJid() const {
    // v59 nickname fix:
    // Keep the MUC occupant resource stable and ASCII-safe. Jitsi uses this
    // resource as the technical endpoint id/source owner. Passing a display
    // name with spaces or non-ASCII characters here can break media routing.
    // The user-facing name is still sent below in <nick>.
    return bareMucJid() + "/probe123";
}

std::string JitsiSignaling::focusJid() const {
    return "focus." + cfg_.domain;
}

std::string JitsiSignaling::buildConnectUrl() const {
    std::string url = cfg_.websocketUrl;

    if (cfg_.addRoomAndTokenToWebSocketUrl) {
        url = appendQueryParam(url, "room", cfg_.room);

        if (!cfg_.authToken.empty()) {
            url = appendQueryParam(url, "token", cfg_.authToken);
        }
    }

    return url;
}

std::string JitsiSignaling::makeIqId(const std::string& prefix) {
    return prefix + "_" + std::to_string(iqCounter_.fetch_add(1));
}

bool JitsiSignaling::connect() {
    Logger::info("Jitsi signaling connect");
    Logger::info("Room: ", cfg_.room);
    Logger::info("Participant filter: ", cfg_.participantFilter.empty() ? "<none>" : cfg_.participantFilter);
    Logger::info("WebSocket URL: ", cfg_.websocketUrl);
    Logger::info("XMPP domain: ", cfg_.domain);
    Logger::info("Guest mode: ", cfg_.guestMode ? "ON" : "OFF");
    Logger::info("Active XMPP domain: ", activeDomain());
    Logger::info("MUC domain: ", cfg_.mucDomain);
    Logger::info("Auth mode: ", cfg_.authMode);
    Logger::info("WebSocket query room/token: ", cfg_.addRoomAndTokenToWebSocketUrl ? "ON" : "OFF");

    if (!cfg_.realXmpp) {
        Logger::warn("Real XMPP disabled; running NDI status pattern only");
        return true;
    }

    ws_.setOnMessage([this](const std::string& xml) {
        handleXmppMessage(xml);
    });

    ws_.setOnClosed([this]() {
        connected_ = false;
        Logger::warn("XMPP websocket closed");
    });

    const std::string url = buildConnectUrl();

    Logger::info("WebSocket connect URL: ", url);

    if (!ws_.connect(url)) {
        return false;
    }

    connected_ = true;

    Logger::info("WebSocket connected: ", url);

    sendOpen();

    return true;
}

void JitsiSignaling::disconnect() {
    connected_ = false;
    mediaRecoveryRequested_.store(false);

    answerer_.resetSession();
    ws_.close();

    {
        std::lock_guard<std::mutex> lock(mutex_);

        currentSid_.clear();
        currentFocusJid_.clear();
        currentIceUfrag_.clear();
        currentIcePwd_.clear();
        lastMediaFailureReason_.clear();
        currentContentNames_.clear();

        sessionAcceptSent_ = false;
        pendingLocalCandidates_.clear();
    }
}

void JitsiSignaling::sendRaw(const std::string& xml) {
    Logger::info("XMPP >> ", xml);
    ws_.sendText(xml);
}

void JitsiSignaling::sendOpen() {
    std::ostringstream xml;

    xml
        << "<open"
        << " to='" << xmlEscape(activeDomain()) << "'"
        << " version='1.0'"
        << " xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>";

    sendRaw(xml.str());
}

void JitsiSignaling::sendAnonymousAuth() {
    sendRaw("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='ANONYMOUS'/>");
}

void JitsiSignaling::sendBind() {
    std::ostringstream xml;

    xml
        << "<iq xmlns='jabber:client' id='bind_1' type='set'>"
        << "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
        << "<resource>jitsi-ndi-native</resource>"
        << "</bind>"
        << "</iq>";

    sendRaw(xml.str());
}

void JitsiSignaling::sendSession() {
    std::ostringstream xml;

    xml
        << "<iq xmlns='jabber:client' id='session_1' type='set'>"
        << "<session xmlns='urn:ietf:params:xml:ns:xmpp-session'/>"
        << "</iq>";

    sendRaw(xml.str());
}

void JitsiSignaling::sendConferenceRequest() {
    const std::string id = makeIqId("conference");

    std::ostringstream xml;

    xml
        << "<iq xmlns='jabber:client'"
        << " to='" << xmlEscape(focusJid()) << "'"
        << " type='set'"
        << " id='" << xmlEscape(id) << "'>";

    xml
        << "<conference xmlns='http://jitsi.org/protocol/focus'"
        << " room='" << xmlEscape(bareMucJid()) << "'"
        << " machine-uid='jitsi-ndi-native'>";

    xml
        << "<property name='rtcstatsEnabled' value='false'/>"
        << "<property name='visitors-version' value='1'/>"
        << "<property name='supports-source-name-signaling' value='true'/>"
        << "<property name='supports-json-encoded-sources' value='true'/>"
        << "<property name='supports-ssrc-rewriting' value='true'/>"
        << "<property name='supports-receive-multiple-streams' value='true'/>"
        << "<property name='supports-colibri-websocket' value='true'/>"
        << "<property name='openSctp' value='true'/>"
        << "<property name='startSilent' value='false'/>"
        << "<property name='startAudioMuted' value='false'/>"
        << "<property name='startVideoMuted' value='false'/>"
        << "<property name='disableRtx' value='false'/>"
        << "<property name='enableLipSync' value='false'/>";

    if (!cfg_.authToken.empty()) {
        xml << "<property name='token' value='" << xmlEscape(cfg_.authToken) << "'/>";
    }

    xml
        << "</conference>"
        << "</iq>";

    sendRaw(xml.str());

    Logger::info("Focus conference request sent id=", id, " to=", focusJid());
}

void JitsiSignaling::joinMuc() {
    const std::string displayNick = cfg_.nick.empty() ? "probe123" : cfg_.nick;

    Logger::info("Joining MUC room as technical endpoint: ", mucJid());
    Logger::info("Jitsi display nick: ", displayNick);

    std::ostringstream xml;
    xml
        << "<presence xmlns='jabber:client'"
        << " to='" << xmlEscape(mucJid()) << "'>";

    xml << "<x xmlns='http://jabber.org/protocol/muc'/>";

    xml
        << "<nick xmlns='http://jabber.org/protocol/nick'>"
        << xmlEscape(displayNick)
        << "</nick>";

    xml
        << "<c xmlns='http://jabber.org/protocol/caps'"
        << " hash='sha-1'"
        << " node='https://github.com/jitsi-ndi-native'"
        << " ver='native'/>";

    // PATCH_V9_AV1_RESTORE_AUDIO_UNBLOCK:
    // JVB is an SFU and normally forwards the codec produced by the browser.
    // In current meet.jit.si rooms that is often AV1/PT=41, so advertise AV1 too.
    // Keep this XML well-formed; previous VP8-only patch left stray text after the tag.
    xml << "<jitsi_participant_codecList>av1,vp8,opus</jitsi_participant_codecList>";
    xml << "</presence>";
    sendRaw(xml.str());
}

void JitsiSignaling::sendIqResult(const std::string& to, const std::string& id) {
    if (to.empty() || id.empty()) {
        return;
    }

    std::ostringstream xml;

    xml
        << "<iq xmlns='jabber:client'"
        << " type='result'"
        << " id='" << xmlEscape(id) << "'"
        << " to='" << xmlEscape(to) << "'/>";

    sendRaw(xml.str());
}

void JitsiSignaling::sendDiscoInfoResult(const std::string& to, const std::string& id) {
    if (to.empty() || id.empty()) {
        return;
    }

    std::ostringstream xml;

    xml
        << "<iq xmlns='jabber:client'"
        << " type='result'"
        << " id='" << xmlEscape(id) << "'"
        << " to='" << xmlEscape(to) << "'>";

    xml << "<query xmlns='http://jabber.org/protocol/disco#info'>";

    xml << "<identity category='client' type='web' name='jitsi-ndi-native'/>";

    // Base Jingle / RTP.
    xml << "<feature var='urn:xmpp:jingle:1'/>";
    xml << "<feature var='urn:xmpp:jingle:apps:rtp:1'/>";
    xml << "<feature var='urn:xmpp:jingle:apps:rtp:audio'/>";
    xml << "<feature var='urn:xmpp:jingle:apps:rtp:video'/>";
    xml << "<feature var='urn:xmpp:jingle:transports:ice-udp:1'/>";
    xml << "<feature var='urn:xmpp:jingle:apps:dtls:0'/>";

    // RTP feedback / extensions.
    xml << "<feature var='urn:xmpp:jingle:apps:rtp:rtcp-fb:0'/>";
    xml << "<feature var='urn:xmpp:jingle:apps:rtp:rtp-hdrext:0'/>";

    // SCTP / data channel capability.
    xml << "<feature var='urn:xmpp:jingle:transports:dtls-sctp:1'/>";

    // Jitsi-specific capabilities.
    xml << "<feature var='http://jitsi.org/protocol/colibri'/>";
    xml << "<feature var='http://jitsi.org/protocol/source-info'/>";
    xml << "<feature var='http://jitsi.org/protocol/source-names'/>";
    xml << "<feature var='http://jitsi.org/protocol/json-encoded-sources'/>";
    xml << "<feature var='http://jitsi.org/protocol/ssrc-rewriting'/>";
    xml << "<feature var='http://jitsi.org/protocol/rtx'/>";
    xml << "<feature var='http://jitsi.org/protocol/remb'/>";
    xml << "<feature var='http://jitsi.org/protocol/tcc'/>";
    xml << "<feature var='http://jitsi.org/protocol/receive-multiple-streams'/>";

    xml << "</query>";
    xml << "</iq>";

    sendRaw(xml.str());

    Logger::info("XMPP >> disco#info result sent id=", id);
}

void JitsiSignaling::handleRoomMetadata(const std::string& xml) {
    if (!contains(xml, "room_metadata") || !contains(xml, "services")) {
        return;
    }

    const std::string decoded = jsonUnescape(xml);

    std::vector<NativeWebRTCAnswerer::IceServer> servers;

    const std::string username = extractJsonString(decoded, "username");
    const std::string password = extractJsonString(decoded, "password");

    bool turnUdpAdded = false;

    if (
        contains(decoded, "meet-jit-si-turnrelay.jitsi.net")
        && contains(decoded, "\"type\":\"turn\"")
        && contains(decoded, "\"transport\":\"udp\"")
        && !username.empty()
        && !password.empty()
    ) {
        NativeWebRTCAnswerer::IceServer turnServer;
        turnServer.uri = "turn:"
            + percentEncodeTurnUserInfo(username)
            + ":"
            + percentEncodeTurnUserInfo(password)
            + "@meet-jit-si-turnrelay.jitsi.net:443?transport=udp";
        servers.push_back(turnServer);
        turnUdpAdded = true;

        Logger::info("Jitsi TURN/UDP metadata parsed and passed to libdatachannel");
    }

    if (contains(decoded, "meet-jit-si-turnrelay.jitsi.net")) {
        NativeWebRTCAnswerer::IceServer stunServer;
        stunServer.uri = "stun:meet-jit-si-turnrelay.jitsi.net:443";
        servers.push_back(stunServer);
    }

    if (!servers.empty()) {
        answerer_.setIceServers(servers);

        Logger::info("Jitsi ICE metadata parsed. ICE servers count=", servers.size());

        for (const auto& server : servers) {
            if (server.uri.find("turn:") == 0) {
                Logger::info("Jitsi ICE server: turn:***@meet-jit-si-turnrelay.jitsi.net:443?transport=udp");
            } else {
                Logger::info("Jitsi ICE server: ", server.uri);
            }
        }
    }

    if (contains(decoded, "\"type\":\"turns\"")) {
        Logger::warn("Jitsi TURNS service skipped because libjuice backend does not support TURN/TLS");
    }

    if (!turnUdpAdded && !username.empty() && !password.empty()) {
        Logger::warn("Jitsi TURN credentials present but TURN/UDP server was not added; using STUN fallback only");
    }
}

void JitsiSignaling::handleJingleInitiate(const std::string& xml) {
    JingleSession session;

    if (!parseJingleSessionInitiate(xml, session)) {
        Logger::warn("MEDIA EVENT: session-initiate detected but parse failed");
        return;
    }

    Logger::info("MEDIA EVENT: Jingle session-initiate detected.");
    Logger::info(
        "Jingle sid=", session.sid,
        " iq=", session.iqId,
        " from=", session.from,
        " bridge=", session.bridgeSessionId,
        " region=", session.region,
        " contents=", session.contents.size()
    );

    for (const auto& content : session.contents) {
        std::ostringstream codecs;

        for (std::size_t i = 0; i < content.codecs.size(); ++i) {
            if (i) {
                codecs << ",";
            }

            codecs << content.codecs[i].name << "/" << content.codecs[i].payloadType;
        }

        Logger::info(
            "  ", content.name,
            ": codecs=", codecs.str(),
            " ice=", content.iceUfrag,
            ":*** candidates=", content.candidates.size(),
            " sources=", content.sources.size()
        );

        for (const auto& source : content.sources) {
            Logger::info(
                "    ssrc=", source.ssrc,
                " owner=", source.owner.empty() ? "?" : source.owner,
                " name=", source.name
            );
        }
    }

    if (ndiRouter_) {
        ndiRouter_->updateSourcesFromJingleXml(xml);
    }

    sendIqResult(session.from, session.iqId);
    Logger::info("MEDIA EVENT: ACK sent for Jingle session-initiate iq id=", session.iqId);

    // ВАЖНО: состояние сессии задаём ДО createAnswer(),
    // потому что libdatachannel может начать выдавать ICE candidates прямо во время createAnswer().
    {
        std::lock_guard<std::mutex> lock(mutex_);

        currentSid_ = session.sid;
        currentFocusJid_ = session.from;
        currentIceUfrag_.clear();
        currentIcePwd_.clear();

        currentContentNames_.clear();

        for (const auto& content : session.contents) {
            if (!content.name.empty()) {
                currentContentNames_.push_back(content.name);
            }
        }

        if (currentContentNames_.empty()) {
            currentContentNames_.push_back("audio");
            currentContentNames_.push_back("video");
        }

        sessionAcceptSent_ = false;
        pendingLocalCandidates_.clear();
    }

    NativeWebRTCAnswerer::Answer answer;

    if (!answerer_.createAnswer(session, answer)) {
        Logger::error("MEDIA EVENT: native WebRTC answer creation failed");

        std::lock_guard<std::mutex> lock(mutex_);

        sessionAcceptSent_ = false;
        pendingLocalCandidates_.clear();

        currentSid_.clear();
        currentFocusJid_.clear();
        currentIceUfrag_.clear();
        currentIcePwd_.clear();
        lastMediaFailureReason_.clear();
        currentContentNames_.clear();

        return;
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);

        currentIceUfrag_ = answer.iceUfrag;
        currentIcePwd_ = answer.icePwd;
    }

    Logger::info("MEDIA EVENT: native WebRTC answer created.");

    const std::string acceptId = makeIqId("jitsi_ndi_session_accept");

    std::string acceptXml = buildJingleSessionAccept(
        session,
        boundJid_,
        acceptId,
        answer.iceUfrag,
        answer.icePwd,
        answer.fingerprint
    );

    Logger::info("JingleSession: session-accept XML:\n", acceptXml);

    sendRaw(acceptXml);

    {
        std::lock_guard<std::mutex> lock(mutex_);
        sessionAcceptSent_ = true;
    }

    Logger::info("MEDIA EVENT: experimental Jingle session-accept sent before local transport-info.");

    flushPendingCandidates();
}

void JitsiSignaling::handleJingleTransportInfo(const std::string& xml) {
    const std::string iqTag = findFirstTag(xml, "iq");
    const std::string from = xmlUnescape(attrValue(iqTag, "from"));
    const std::string id = attrValue(iqTag, "id");

    const std::string jingleTag = findFirstTag(xml, "jingle");
    const std::string sid = xmlUnescape(attrValue(jingleTag, "sid"));

    std::string activeFocusJid;
    std::string activeSid;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        activeFocusJid = currentFocusJid_;
        activeSid = currentSid_;
    }

    if (!activeFocusJid.empty() && from != activeFocusJid) {
        Logger::warn(
            "MEDIA EVENT: ignoring non-focus/P2P transport-info from=",
            from,
            " sid=",
            sid.empty() ? "?" : sid,
            " activeFocus=",
            activeFocusJid
        );
        sendIqResult(from, id);
        return;
    }

    if (!activeSid.empty() && !sid.empty() && sid != activeSid) {
        Logger::warn(
            "MEDIA EVENT: ignoring transport-info for stale sid=",
            sid,
            " activeSid=",
            activeSid,
            " from=",
            from
        );
        sendIqResult(from, id);
        return;
    }

    LocalIceCandidate candidate;

    if (parseTransportInfoCandidate(xml, candidate)) {
        answerer_.addRemoteCandidate(candidate);
    } else {
        Logger::warn("MEDIA EVENT: transport-info detected but no candidate parsed");
    }

    sendIqResult(from, id);
}
void JitsiSignaling::handleJingleTerminate(const std::string& xml) {
    const std::string iqTag = findFirstTag(xml, "iq");
    const std::string from = xmlUnescape(attrValue(iqTag, "from"));
    const std::string id = attrValue(iqTag, "id");

    const std::string jingleTag = findFirstTag(xml, "jingle");
    const std::string sid = xmlUnescape(attrValue(jingleTag, "sid"));

    std::string activeFocusJid;
    std::string activeSid;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        activeFocusJid = currentFocusJid_;
        activeSid = currentSid_;
    }

    const bool isFromFocus = activeFocusJid.empty()
        ? (from.find("/focus") != std::string::npos || from.find("focus") != std::string::npos)
        : (from == activeFocusJid);
    const bool sidMatches = activeSid.empty() || sid.empty() || sid == activeSid;

    if (!isFromFocus || !sidMatches) {
        Logger::warn(
            "MEDIA EVENT: ignoring non-active/P2P session-terminate from=",
            from.empty() ? "?" : from,
            " sid=",
            sid.empty() ? "?" : sid,
            " activeFocus=",
            activeFocusJid.empty() ? "?" : activeFocusJid,
            " activeSid=",
            activeSid.empty() ? "?" : activeSid
        );
        sendIqResult(from, id);
        return;
    }

    Logger::warn(
        "MEDIA EVENT: active focus Jingle session-terminate detected from=",
        from,
        " sid=",
        sid.empty() ? "?" : sid
    );

    if (ndiRouter_) {
        ndiRouter_->removeSourcesFromJingleXml(xml);
    }

    answerer_.resetSession();

    {
        std::lock_guard<std::mutex> lock(mutex_);

        currentSid_.clear();
        currentFocusJid_.clear();
        currentIceUfrag_.clear();
        currentIcePwd_.clear();
        lastMediaFailureReason_.clear();
        currentContentNames_.clear();

        sessionAcceptSent_ = false;
        pendingLocalCandidates_.clear();
    }

    sendIqResult(from, id);
}

void JitsiSignaling::flushPendingCandidates() {
    std::vector<LocalIceCandidate> candidates;
    std::vector<std::string> contentNames;

    std::string to;
    std::string sid;
    std::string ufrag;
    std::string pwd;

    {
        std::lock_guard<std::mutex> lock(mutex_);

        if (!sessionAcceptSent_) {
            return;
        }

        candidates.swap(pendingLocalCandidates_);
        contentNames = currentContentNames_;

        to = currentFocusJid_;
        sid = currentSid_;
        ufrag = currentIceUfrag_;
        pwd = currentIcePwd_;
    }

    if (to.empty() || sid.empty() || ufrag.empty() || pwd.empty()) {
        Logger::warn("NativeWebRTCAnswerer: cannot flush ICE candidates: active Jingle session is incomplete");
        return;
    }

    if (contentNames.empty()) {
        contentNames.push_back("audio");
        contentNames.push_back("video");
    }

    for (const auto& originalCandidate : candidates) {
        for (const auto& contentName : contentNames) {
            if (contentName.empty()) {
                continue;
            }

            LocalIceCandidate candidate = originalCandidate;
            candidate.mid = contentName;

            const std::string id = makeIqId("jitsi_ndi_transport_info");

            Logger::info(
                "NativeWebRTCAnswerer: flushing/sending local ICE candidate as Jingle transport-info mid=",
                candidate.mid
            );

            sendRaw(buildJingleTransportInfo(to, id, sid, ufrag, pwd, candidate));
        }
    }
}

void JitsiSignaling::handleXmppMessage(const std::string& xml) {
    static std::atomic<std::uint64_t> seq{1};

    Logger::info("XMPP << [", seq.fetch_add(1), "] ", xml);

    if (contains(xml, "<stream:features") || contains(xml, "<features")) {
        if (contains(xml, "<mechanism>ANONYMOUS</mechanism>")) {
            sendAnonymousAuth();
            Logger::info("Jitsi XMPP auth bootstrap sent. Watch logs for <success>, <failure>, <presence>, jingle/colibri.");
            return;
        }

        if (contains(xml, "urn:ietf:params:xml:ns:xmpp-bind")) {
            sendBind();
            return;
        }
    }

    if (contains(xml, "<success") && contains(xml, "urn:ietf:params:xml:ns:xmpp-sasl")) {
        Logger::info("XMPP auth accepted by server. Re-opening stream for bind/session.");
        sendOpen();
        return;
    }

    if (isIqId(xml, "bind_1") && isIqType(xml, "result")) {
        const std::regex jidRe(R"(<jid>([^<]+)</jid>)");
        std::smatch m;

        if (std::regex_search(xml, m, jidRe) && m.size() > 1) {
            boundJid_ = xmlUnescape(m[1].str());
            Logger::info("Bound XMPP JID: ", boundJid_);
        } else {
            Logger::warn("Bind result received, but bound JID was not found");
        }

        sendSession();
        return;
    }

    if (isIqId(xml, "session_1") && isIqType(xml, "result")) {
        // Раньше здесь сразу вызывался joinMuc().
        // Теперь сначала просим focus создать/подготовить conference,
        // как это делает lib-jitsi-meet перед входом в комнату.
        sendConferenceRequest();
        return;
    }

    if (isIqIdPrefix(xml, "conference_")) {
        if (isIqType(xml, "result")) {
            Logger::info("Focus conference request accepted. Joining MUC now.");
            joinMuc();
            return;
        }

        if (isIqType(xml, "error")) {
            Logger::error("Focus conference request failed: ", xml);
            Logger::warn("Falling back to direct MUC join anyway.");
            joinMuc();
            return;
        }
    }

    handleRoomMetadata(xml);

    if (ndiRouter_) {
        const bool isPresence = contains(xml, "<presence");
        const bool isUnavailablePresence =
            isPresence &&
            containsAnyQuoteAttr(xml, "type", "unavailable") &&
            !contains(xml, "status code='110'") &&
            !contains(xml, "status code=\"110\"");

        if (isUnavailablePresence) {
            Logger::info("MEDIA EVENT: participant unavailable; cleaning stale NDI/source mappings.");
            ndiRouter_->handleParticipantUnavailableXml(xml);
        } else if (isPresence || contains(xml, "<message")) {
            ndiRouter_->updateSourcesFromJingleXml(xml);

            // v46: rejoin/name-change recovery. Jitsi often announces a rejoined
            // participant's new source ids first via presence <SourceInfo>, not only
            // through Jingle source-add. Feed those source ids to the bridge receiver
            // constraints too, otherwise the participant may be present in MUC but not
            // forwarded by JVB/NDI after reconnect.
            if (isPresence && contains(xml, "<SourceInfo")) {
                answerer_.updateReceiverSourcesFromJingleXml(xml);
            }
        }
    }

    if (
        contains(xml, "http://jabber.org/protocol/disco#info")
        && isIqType(xml, "get")
    ) {
        const std::string to = extractIqAttr(xml, "from");
        const std::string id = extractIqAttr(xml, "id");

        sendDiscoInfoResult(to, id);
        return;
    }

    if (
        contains(xml, "urn:xmpp:jingle:1")
        && (
            containsAnyQuoteAttr(xml, "action", "source-add")
            || contains(xml, "source-add")
        )
    ) {
        const std::string to = extractIqAttr(xml, "from");
        const std::string id = extractIqAttr(xml, "id");

        Logger::info("MEDIA EVENT: Jingle source-add detected; ACKing first, then updating source map.");

        // v48: ACK source-add immediately. Delaying the IQ result while we update
        // local maps and bridge constraints can leave Jicofo/JVB in a half-updated
        // state during participant rejoin. The local update is still done right
        // after the ACK.
        sendIqResult(to, id);

        if (ndiRouter_) {
            ndiRouter_->updateSourcesFromJingleXml(xml);
        }

        answerer_.updateReceiverSourcesFromJingleXml(xml);

        return;
    }

    if (
        contains(xml, "urn:xmpp:jingle:1")
        && (
            containsAnyQuoteAttr(xml, "action", "source-remove")
            || contains(xml, "source-remove")
        )
    ) {
        const std::string to = extractIqAttr(xml, "from");
        const std::string id = extractIqAttr(xml, "id");

        Logger::info("MEDIA EVENT: Jingle source-remove detected; updating source map and ACKing.");

        if (ndiRouter_) {
            ndiRouter_->removeSourcesFromJingleXml(xml);
        }

        sendIqResult(to, id);
        return;
    }
    if (
        contains(xml, "urn:xmpp:jingle:1")
        && (
            containsAnyQuoteAttr(xml, "action", "session-initiate")
            || contains(xml, "session-initiate")
        )
    ) {
        handleJingleInitiate(xml);
        return;
    }

    if (
        contains(xml, "urn:xmpp:jingle:1")
        && (
            containsAnyQuoteAttr(xml, "action", "transport-info")
            || contains(xml, "transport-info")
        )
    ) {
        handleJingleTransportInfo(xml);
        return;
    }

    if (
        contains(xml, "urn:xmpp:jingle:1")
        && (
            containsAnyQuoteAttr(xml, "action", "session-terminate")
            || contains(xml, "session-terminate")
        )
    ) {
        handleJingleTerminate(xml);
        return;
    }

    if (
        contains(xml, "<presence")
        && !contains(xml, "status code='110'")
        && !contains(xml, "status code=\"110\"")
    ) {
        Logger::info("Presence received. This is the first sign that MUC join is alive.");
    }
}
