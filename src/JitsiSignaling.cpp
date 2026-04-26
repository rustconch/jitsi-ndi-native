#include "JitsiSignaling.h"
#include "Logger.h"

#include <algorithm>
#include <regex>
#include <sstream>

namespace {

bool contains(const std::string& s, const std::string& needle) {
    return s.find(needle) != std::string::npos;
}

std::string appendQueryParam(std::string url, const std::string& key, const std::string& value) {
    if (value.empty()) return url;
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
    if (std::regex_search(json, m, re) && m.size() > 1) return m[1].str();
    return {};
}

} // namespace

JitsiSignaling::JitsiSignaling(JitsiSignalingConfig config)
    : cfg_(std::move(config)) {
    answerer_.setLocalCandidateCallback([this](const LocalIceCandidate& cand) {
        bool shouldFlush = false;

        {
            std::lock_guard lock(mutex_);

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
}

JitsiSignaling::~JitsiSignaling() {
    disconnect();
}

std::string JitsiSignaling::activeDomain() const {
    return cfg_.guestMode ? cfg_.guestDomain : cfg_.domain;
}

std::string JitsiSignaling::mucJid() const {
    return cfg_.room + "@" + cfg_.mucDomain + "/" + cfg_.nick;
}

std::string JitsiSignaling::buildConnectUrl() const {
    std::string url = cfg_.websocketUrl;
    if (cfg_.addRoomAndTokenToWebSocketUrl) {
        url = appendQueryParam(url, "room", cfg_.room);
        if (!cfg_.authToken.empty()) url = appendQueryParam(url, "token", cfg_.authToken);
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

    ws_.setOnMessage([this](const std::string& xml) { handleXmppMessage(xml); });
    ws_.setOnClosed([this]() {
        connected_ = false;
        Logger::warn("XMPP websocket closed");
    });

    const std::string url = buildConnectUrl();
    Logger::info("WebSocket connect URL: ", url);
    if (!ws_.connect(url)) return false;

    connected_ = true;
    Logger::info("WebSocket connected: ", url);
    sendOpen();
    return true;
}

void JitsiSignaling::disconnect() {
    connected_ = false;
    answerer_.resetSession();
    ws_.close();
}

void JitsiSignaling::sendRaw(const std::string& xml) {
    Logger::info("XMPP >> ", xml);
    ws_.sendText(xml);
}

void JitsiSignaling::sendOpen() {
    std::ostringstream xml;
    xml << "<open to='" << xmlEscape(activeDomain())
        << "' version='1.0' xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>";
    sendRaw(xml.str());
}

void JitsiSignaling::sendAnonymousAuth() {
    sendRaw("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='ANONYMOUS'/>");
}

void JitsiSignaling::sendBind() {
    sendRaw("<iq xmlns='jabber:client' id='bind_1' type='set'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>jitsi-ndi-native</resource></bind></iq>");
}

void JitsiSignaling::sendSession() {
    sendRaw("<iq xmlns='jabber:client' id='session_1' type='set'><session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></iq>");
}

void JitsiSignaling::joinMuc() {
    Logger::info("Joining MUC room as: ", mucJid());
    std::ostringstream xml;
    xml << "<presence xmlns='jabber:client' to='" << xmlEscape(mucJid()) << "'>";
    xml << "<x xmlns='http://jabber.org/protocol/muc'/>";
    xml << "<nick xmlns='http://jabber.org/protocol/nick'>" << xmlEscape(cfg_.nick) << "</nick>";
    xml << "<c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='https://github.com/jitsi-ndi-native' ver='native'/>";
    xml << "</presence>";
    sendRaw(xml.str());
}

void JitsiSignaling::sendIqResult(const std::string& to, const std::string& id) {
    if (to.empty() || id.empty()) return;
    std::ostringstream xml;
    xml << "<iq xmlns='jabber:client' type='result' id='" << xmlEscape(id)
        << "' to='" << xmlEscape(to) << "'/>";
    sendRaw(xml.str());
}

void JitsiSignaling::sendDiscoInfoResult(const std::string& to, const std::string& id) {
    std::ostringstream xml;
    xml << "<iq xmlns='jabber:client' type='result' id='" << xmlEscape(id)
        << "' to='" << xmlEscape(to) << "'>";
    xml << "<query xmlns='http://jabber.org/protocol/disco#info'>";
    xml << "<identity category='client' type='web' name='jitsi-ndi-native'/>";
    xml << "<feature var='urn:xmpp:jingle:1'/>";
    xml << "<feature var='urn:xmpp:jingle:apps:rtp:1'/>";
    xml << "<feature var='urn:xmpp:jingle:apps:rtp:audio'/>";
    xml << "<feature var='urn:xmpp:jingle:apps:rtp:video'/>";
    xml << "<feature var='urn:xmpp:jingle:transports:ice-udp:1'/>";
    xml << "<feature var='urn:xmpp:jingle:apps:dtls:0'/>";
    xml << "<feature var='http://jitsi.org/protocol/source-info'/>";
    xml << "</query></iq>";
    sendRaw(xml.str());
    Logger::info("XMPP >> disco#info result sent id=", id);
}

void JitsiSignaling::handleRoomMetadata(const std::string& xml) {
    if (!contains(xml, "room_metadata") || !contains(xml, "services")) return;

    const std::string decoded = jsonUnescape(xml);
    std::vector<NativeWebRTCAnswerer::IceServer> servers;

    if (contains(decoded, "meet-jit-si-turnrelay.jitsi.net")) {
        servers.push_back({"stun:meet-jit-si-turnrelay.jitsi.net:443"});

        const std::string username = extractJsonString(decoded, "username");
        const std::string password = extractJsonString(decoded, "password");
        if (!username.empty() && !password.empty()) {
            std::string pass = password;
            std::size_t pos = 0;
            while ((pos = pass.find("/", pos)) != std::string::npos) {
                pass.replace(pos, 1, "%2F");
                pos += 3;
            }
            pos = 0;
            while ((pos = pass.find("=", pos)) != std::string::npos) {
                pass.replace(pos, 1, "%3D");
                pos += 3;
            }
            servers.push_back({"turn:" + username + ":" + pass + "@meet-jit-si-turnrelay.jitsi.net:443?transport=udp"});
        }
    }

    if (!servers.empty()) {
        answerer_.setIceServers(servers);
        Logger::info("Jitsi TURN metadata parsed. ICE servers count=", servers.size());
        for (const auto& s : servers) Logger::info("Jitsi ICE server: ", s.uri);
        if (contains(decoded, "\"type\":\"turns\"")) {
            Logger::warn("Jitsi TURNS service skipped because libjuice backend does not support TURN/TLS");
        }
    }
}

void JitsiSignaling::handleJingleInitiate(const std::string& xml) {
    JingleSession session;
    if (!parseJingleSessionInitiate(xml, session)) {
        Logger::warn("MEDIA EVENT: session-initiate detected but parse failed");
        return;
    }
	    // Нам нужна только конференц-сессия от Jicofo/JVB:
		// room@conference.../focus.
		// P2P session-initiate от обычного участника сбрасывает focus-сессию
		// и оставляет нас без RTP, поэтому его явно отклоняем.
		const bool isFocusSession =
			session.from.find("/focus") != std::string::npos ||
			session.initiator.find("focus@") != std::string::npos;

		if (!isFocusSession) {
			Logger::warn(
				"MEDIA EVENT: ignoring non-focus/P2P Jingle session-initiate from=",
				session.from,
				" sid=",
				session.sid
			);

			sendIqResult(session.from, session.iqId);

			const std::string rejectId = makeIqId("jitsi_ndi_p2p_reject");
			std::ostringstream reject;
			reject
				<< "<iq xmlns='jabber:client' type='set'"
				<< " to='" << xmlEscape(session.from) << "'"
				<< " id='" << xmlEscape(rejectId) << "'>"
				<< "<jingle xmlns='urn:xmpp:jingle:1'"
				<< " action='session-terminate'"
				<< " sid='" << xmlEscape(session.sid) << "'>"
				<< "<reason><decline/>"
				<< "<text>native receiver accepts focus/JVB session only</text>"
				<< "</reason>"
				<< "</jingle>"
				<< "</iq>";

			sendRaw(reject.str());
			return;
		}

    Logger::info("MEDIA EVENT: Jingle session-initiate detected.");
    Logger::info("Jingle sid=", session.sid, " iq=", session.iqId, " from=", session.from,
                 " bridge=", session.bridgeSessionId, " region=", session.region,
                 " contents=", session.contents.size());

    for (const auto& c : session.contents) {
        std::ostringstream codecs;
        for (std::size_t i = 0; i < c.codecs.size(); ++i) {
            if (i) codecs << ",";
            codecs << c.codecs[i].name << "/" << c.codecs[i].payloadType;
        }
        Logger::info("  ", c.name, ": codecs=", codecs.str(), " ice=", c.iceUfrag, ":*** candidates=", c.candidates.size(), " sources=", c.sources.size());
        for (const auto& src : c.sources) {
            Logger::info("    ssrc=", src.ssrc, " owner=", src.owner.empty() ? "?" : src.owner, " name=", src.name);
        }
    }

    sendIqResult(session.from, session.iqId);
    Logger::info("MEDIA EVENT: ACK sent for Jingle session-initiate iq id=", session.iqId);

	{
		std::lock_guard lock(mutex_);
		currentSid_ = session.sid;
		currentFocusJid_ = session.from;
		currentIceUfrag_.clear();
		currentIcePwd_.clear();
		sessionAcceptSent_ = false;
		pendingLocalCandidates_.clear();
	}

	NativeWebRTCAnswerer::Answer answer;
	if (!answerer_.createAnswer(session, answer)) {
		Logger::error("MEDIA EVENT: native WebRTC answer creation failed");
		return;
	}

	{
		std::lock_guard lock(mutex_);
		currentSid_ = session.sid;
		currentFocusJid_ = session.from;
		currentIceUfrag_ = answer.iceUfrag;
		currentIcePwd_ = answer.icePwd;
		sessionAcceptSent_ = false;

		// ВАЖНО:
		// Здесь НЕ очищаем pendingLocalCandidates_.
		// Кандидаты могли появиться во время createAnswer(),
		// и раньше мы сами их стирали до отправки session-accept.
	}

    Logger::info("MEDIA EVENT: native WebRTC answer created.");

    const std::string acceptId = makeIqId("jitsi_ndi_session_accept");
    const std::string acceptXml = buildJingleSessionAccept(
        session, boundJid_, acceptId, answer.iceUfrag, answer.icePwd, answer.fingerprint);
    sendRaw(acceptXml);

    {
        std::lock_guard<std::mutex> lock(mutex_);
        sessionAcceptSent_ = true;
    }

    Logger::info("MEDIA EVENT: experimental Jingle session-accept sent before local transport-info.");
    flushPendingCandidates();
}

void JitsiSignaling::flushPendingCandidates() {
    std::vector<LocalIceCandidate> candidates;
    std::string to, sid, ufrag, pwd;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!sessionAcceptSent_) return;
        candidates.swap(pendingLocalCandidates_);
        to = currentFocusJid_;
        sid = currentSid_;
        ufrag = currentIceUfrag_;
        pwd = currentIcePwd_;
    }

    for (auto& cand : candidates) {
        // libdatachannel часто возвращает mid как "0"/"1",
        // а focus/JVB Jingle-сессия meet.jit.si использует content names
        // "audio" и "video".
        //
        // Если отправить <content name='0'> в focus-сессию,
        // Jicofo может ACK-нуть IQ, но не применить candidate к нужному transport.
        if (cand.mid.empty() || cand.mid == "0") {
            cand.mid = "audio";
        } else if (cand.mid == "1") {
            cand.mid = "video";
        }

        const std::string id = makeIqId("jitsi_ndi_transport_info");

        Logger::info(
            "NativeWebRTCAnswerer: flushing/sending local ICE candidate as Jingle transport-info mid=",
            cand.mid
        );

        sendRaw(buildJingleTransportInfo(to, id, sid, ufrag, pwd, cand));
    }
}

void JitsiSignaling::handleXmppMessage(const std::string& xml) {
    static std::atomic<int> seq{1};
    Logger::info("XMPP << [", seq.fetch_add(1), "] ", xml);

    if (contains(xml, "<success") && contains(xml, "urn:ietf:params:xml:ns:xmpp-sasl")) {
        Logger::info("XMPP auth accepted by server. Re-opening stream for bind/session.");
        sendOpen();
        return;
    }

    if (contains(xml, "<stream:features") && contains(xml, "ANONYMOUS")) {
        sendAnonymousAuth();
        Logger::info("Jitsi XMPP auth bootstrap sent. Watch logs for <success>, <failure>, <presence>, jingle/colibri.");
        return;
    }

    if (contains(xml, "<stream:features") && contains(xml, "<bind")) {
        sendBind();
        return;
    }

    if (contains(xml, "id='bind_1'") || contains(xml, "id=\"bind_1\"")) {
        const std::regex jidRe(R"(<jid>([^<]+)</jid>)");
        std::smatch m;
        if (std::regex_search(xml, m, jidRe) && m.size() > 1) {
            boundJid_ = xmlUnescape(m[1].str());
            Logger::info("Bound XMPP JID: ", boundJid_);
        }
        sendSession();
        return;
    }

    if (contains(xml, "id='session_1'") || contains(xml, "id=\"session_1\"")) {
        joinMuc();
        return;
    }

    if (contains(xml, "<presence")) {
        Logger::info("Presence received. This is the first sign that MUC join is alive.");
        return;
    }

    handleRoomMetadata(xml);

    if (contains(xml, "disco#info") && contains(xml, "type='get'")) {
        const std::string iqTag = findFirstTag(xml, "iq");
        sendDiscoInfoResult(attrValue(iqTag, "from"), attrValue(iqTag, "id"));
        return;
    }

    if (contains(xml, "action='session-initiate'") || contains(xml, "action=\"session-initiate\"")) {
        handleJingleInitiate(xml);
        return;
    }

    if (contains(xml, "action='transport-info'") || contains(xml, "action=\"transport-info\"")) {
        const std::string iqTag = findFirstTag(xml, "iq");
        const std::string from = attrValue(iqTag, "from");
        const std::string id = attrValue(iqTag, "id");
        if (contains(xml, "type='set'") || contains(xml, "type=\"set\"")) {
            LocalIceCandidate cand;
            if (parseTransportInfoCandidate(xml, cand)) {
                answerer_.addRemoteCandidate(cand);
                Logger::info("MEDIA EVENT: remote transport-info candidates processed.");
            }
            sendIqResult(from, id);
        }
        return;
    }

    if (contains(xml, "action='source-add'") || contains(xml, "action=\"source-add\"") ||
        contains(xml, "action='source-remove'") || contains(xml, "action=\"source-remove\"")) {
        const std::string iqTag = findFirstTag(xml, "iq");
        sendIqResult(attrValue(iqTag, "from"), attrValue(iqTag, "id"));
        Logger::info("MEDIA EVENT: source-add/source-remove ACK sent.");
        return;
    }

    if (contains(xml, "action='session-terminate'") || contains(xml, "action=\"session-terminate\"")) {
        const std::string iqTag = findFirstTag(xml, "iq");
        sendIqResult(attrValue(iqTag, "from"), attrValue(iqTag, "id"));
        answerer_.resetSession();
        {
            std::lock_guard<std::mutex> lock(mutex_);
            sessionAcceptSent_ = false;
            pendingLocalCandidates_.clear();
            currentSid_.clear();
        }
        Logger::info("MEDIA EVENT: Jingle session-terminate ACK sent id=", attrValue(iqTag, "id"));
        return;
    }

    flushPendingCandidates();
}
