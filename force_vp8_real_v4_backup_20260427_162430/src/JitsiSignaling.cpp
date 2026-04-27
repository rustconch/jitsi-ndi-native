#include "JitsiSignaling.h"

#include "Logger.h"

#include <regex>
#include <sstream>
#include <utility>

#include <string>





// JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN
// Temporary compatibility fix: do not advertise AV1/H264/VP9 in outgoing
// Jingle session-accept. This avoids libdav1d errors from malformed/unsupported
// AV1 RTP reassembly while we stabilize the native RTP path.
static std::string jnnErasePayloadTypeByCodecName(std::string xml, const std::string& codecName) {
    for (;;) {
        size_t pos = xml.find("name='" + codecName + "'");
        if (pos == std::string::npos) pos = xml.find("name=\"" + codecName + "\"");
        if (pos == std::string::npos) break;

        const size_t start = xml.rfind("<payload-type", pos);
        if (start == std::string::npos) break;

        size_t end = xml.find("</payload-type>", pos);
        if (end != std::string::npos) {
            end += std::string("</payload-type>").size();
        } else {
            end = xml.find("/>", pos);
            if (end == std::string::npos) break;
            end += 2;
        }
        xml.erase(start, end - start);
    }
    return xml;
}

static std::string jnnEraseHeaderExtensionByText(std::string xml, const std::string& needle) {
    for (;;) {
        size_t pos = xml.find(needle);
        if (pos == std::string::npos) break;
        const size_t start = xml.rfind("<rtp-hdrext", pos);
        if (start == std::string::npos) break;
        size_t end = xml.find("/>", pos);
        if (end == std::string::npos) break;
        end += 2;
        xml.erase(start, end - start);
    }
    return xml;
}

static std::string jnnForceJingleSessionAcceptVp8Only(std::string xml) {
    if (xml.find("session-accept") == std::string::npos) {
        return xml;
    }
    xml = jnnErasePayloadTypeByCodecName(std::move(xml), "AV1");
    xml = jnnErasePayloadTypeByCodecName(std::move(xml), "H264");
    xml = jnnErasePayloadTypeByCodecName(std::move(xml), "VP9");
    xml = jnnEraseHeaderExtensionByText(std::move(xml), "dependency-descriptor");
    xml = jnnEraseHeaderExtensionByText(std::move(xml), "video-layers-allocation");
    return xml;
}
// JNN_FORCE_JINGLE_VP8_HOTFIX_END

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
}

JitsiSignaling::~JitsiSignaling() {
    disconnect();
}

std::string JitsiSignaling::activeDomain() const {
    return cfg_.guestMode ? cfg_.guestDomain : cfg_.domain;
}

std::string JitsiSignaling::bareMucJid() const {
    return cfg_.room + "@" + cfg_.mucDomain;
}

std::string JitsiSignaling::mucJid() const {
    return bareMucJid() + "/" + cfg_.nick;
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

    answerer_.resetSession();
    ws_.close();

    {
        std::lock_guard<std::mutex> lock(mutex_);

        currentSid_.clear();
        currentFocusJid_.clear();
        currentIceUfrag_.clear();
        currentIcePwd_.clear();
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
    Logger::info("Joining MUC room as: ", mucJid());

    std::ostringstream xml;

    xml
        << "<presence xmlns='jabber:client'"
        << " to='" << xmlEscape(mucJid()) << "'>";

    xml << "<x xmlns='http://jabber.org/protocol/muc'/>";

    xml
        << "<nick xmlns='http://jabber.org/protocol/nick'>"
        << xmlEscape(cfg_.nick)
        << "</nick>";

    xml
        << "<c xmlns='http://jabber.org/protocol/caps'"
        << " hash='sha-1'"
        << " node='https://github.com/jitsi-ndi-native'"
        << " ver='native'/>";

    xml << "<jitsi_participant_codecList>vp8,opus</jitsi_participant_codecList>";

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

    if (contains(decoded, "meet-jit-si-turnrelay.jitsi.net")) {
        NativeWebRTCAnswerer::IceServer stunServer;
        stunServer.uri = "stun:meet-jit-si-turnrelay.jitsi.net:443";
        servers.push_back(stunServer);
    }

    if (!servers.empty()) {
        answerer_.setIceServers(servers);

        Logger::info("Jitsi TURN metadata parsed. ICE servers count=", servers.size());

        for (const auto& server : servers) {
            Logger::info("Jitsi ICE server: ", server.uri);
        }
    }

    if (contains(decoded, "\"type\":\"turns\"")) {
        Logger::warn("Jitsi TURNS service skipped because libjuice backend does not support TURN/TLS");
    }

    const std::string username = extractJsonString(decoded, "username");
    const std::string password = extractJsonString(decoded, "password");

    if (!username.empty() && !password.empty()) {
        Logger::info("Jitsi TURN credentials present in metadata, but only STUN is currently passed to libdatachannel");
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

    const std::string acceptXml = buildJingleSessionAccept(
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

    Logger::warn("MEDIA EVENT: Jingle session-terminate detected");

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
        if (contains(xml, "<presence") || contains(xml, "<message")) {
            ndiRouter_->updateSourcesFromJingleXml(xml);
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