#include "JitsiSignaling.h"
#include "Logger.h"
#include "JingleSession.h"
#include "XmppWebSocketClient.h"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <fstream>
#include <regex>
#include <sstream>
#include <thread>
#include <unordered_map>
#include <utility>

JitsiSignaling::JitsiSignaling(JitsiSignalingConfig config)
    : config_(std::move(config)) {}

JitsiSignaling::~JitsiSignaling() = default;

std::string JitsiSignaling::sanitizeRoomName(const std::string& room) {
    std::string out;
    out.reserve(room.size());
    for (char c : room) {
        if (std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '_') {
            out.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
        }
    }
    return out.empty() ? "test-room" : out;
}

std::string JitsiSignaling::xmlEscape(const std::string& value) {
    std::string out;
    for (char c : value) {
        switch (c) {
            case '&': out += "&amp;"; break;
            case '<': out += "&lt;"; break;
            case '>': out += "&gt;"; break;
            case '"': out += "&quot;"; break;
            case '\'': out += "&apos;"; break;
            default: out.push_back(c); break;
        }
    }
    return out;
}

std::string JitsiSignaling::htmlUnescape(std::string value) {
    auto replaceAll = [](std::string& s, const std::string& from, const std::string& to) {
        std::size_t pos = 0;
        while ((pos = s.find(from, pos)) != std::string::npos) {
            s.replace(pos, from.size(), to);
            pos += to.size();
        }
    };

    replaceAll(value, "&quot;", "\"");
    replaceAll(value, "&apos;", "'");
    replaceAll(value, "&lt;", "<");
    replaceAll(value, "&gt;", ">");
    replaceAll(value, "&amp;", "&");
    return value;
}

std::string JitsiSignaling::base64Encode(const std::string& value) {
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    int val = 0;
    int valb = -6;

    for (unsigned char c : value) {
        val = (val << 8) + c;
        valb += 8;

        while (valb >= 0) {
            out.push_back(table[(val >> valb) & 0x3F]);
            valb -= 6;
        }
    }

    if (valb > -6) out.push_back(table[((val << 8) >> (valb + 8)) & 0x3F]);
    while (out.size() % 4) out.push_back('=');
    return out;
}

std::string JitsiSignaling::urlEncode(const std::string& value) {
    static const char hex[] = "0123456789ABCDEF";
    std::string out;

    for (unsigned char c : value) {
        if ((c >= 'a' && c <= 'z') ||
            (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') ||
            c == '-' || c == '_' || c == '.' || c == '~') {
            out.push_back(static_cast<char>(c));
        } else {
            out.push_back('%');
            out.push_back(hex[c >> 4]);
            out.push_back(hex[c & 0x0F]);
        }
    }

    return out;
}

std::string JitsiSignaling::extractAttr(const std::string& tag, const std::string& name) {
    const std::regex re1(name + "='([^']*)'");
    const std::regex re2(name + "=\"([^\"]*)\"");
    std::smatch m;
    if (std::regex_search(tag, m, re1) && m.size() > 1) return m[1].str();
    if (std::regex_search(tag, m, re2) && m.size() > 1) return m[1].str();
    return {};
}

std::string JitsiSignaling::firstTag(const std::string& xml, const std::string& tagName) {
    const std::regex re("<" + tagName + R"((?:\s|/|>)[^>]*>)");
    std::smatch m;
    if (std::regex_search(xml, m, re)) return m.str();
    return {};
}

void JitsiSignaling::parseAndStoreTurnServices(const std::string& xml) {
    std::vector<std::string> servers;
    const std::string decoded = htmlUnescape(xml);

    const std::regex objectRe(R"(\{[^{}]*\})");
    const std::regex kvRe(R"("([^"]+)"\s*:\s*"([^"]*)")");

    auto begin = std::sregex_iterator(decoded.begin(), decoded.end(), objectRe);
    auto end = std::sregex_iterator();

    for (auto it = begin; it != end; ++it) {
        const std::string object = it->str();
        std::unordered_map<std::string, std::string> kv;

        auto kb = std::sregex_iterator(object.begin(), object.end(), kvRe);
        for (auto kt = kb; kt != std::sregex_iterator(); ++kt) {
            kv[(*kt)[1].str()] = (*kt)[2].str();
        }

        const std::string type = kv["type"];
        const std::string host = kv["host"];
        const std::string port = kv["port"].empty() ? "443" : kv["port"];
        const std::string transport = kv["transport"];

        if (host.empty() || type.empty()) continue;

        if (type == "stun") {
            servers.push_back("stun:" + host + ":" + port);
            continue;
        }

        if (type == "turns") {
            Logger::warn("Jitsi TURNS service skipped because libjuice backend does not support TURN/TLS");
            continue;
        }

        if (type == "turn") {
            const std::string username = kv["username"];
            const std::string password = kv["password"];
            if (username.empty() || password.empty()) continue;

            std::string uri = "turn:" + urlEncode(username) + ":" + urlEncode(password) + "@" + host + ":" + port;
            if (!transport.empty()) uri += "?transport=" + transport;
            servers.push_back(uri);
        }
    }

    iceServers_ = servers;
    Logger::info("Jitsi TURN metadata parsed. ICE servers count=", static_cast<int>(iceServers_.size()));
    for (const auto& server : iceServers_) {
        Logger::info("Jitsi ICE server: ", server);
    }
}

std::string JitsiSignaling::websocketUrlForConnect() const {
    if (!config_.addRoomAndTokenToWebSocketUrl) return config_.websocketUrl;

    std::string url = config_.websocketUrl;
    url += (url.find('?') == std::string::npos) ? "?" : "&";
    url += "room=" + urlEncode(sanitizeRoomName(config_.room));

    if (!config_.authToken.empty()) {
        url += "&token=" + urlEncode(config_.authToken);
    }

    return url;
}

std::string JitsiSignaling::activeXmppDomain() const {
    if (config_.guestMode && !config_.guestDomain.empty()) return config_.guestDomain;
    return config_.domain;
}

std::string JitsiSignaling::roomJid() const {
    return sanitizeRoomName(config_.room) + "@" + config_.mucDomain + "/" + xmlEscape(config_.nick);
}

bool JitsiSignaling::send(const std::string& xml) {
    if (!ws_) return false;
    Logger::info("XMPP >> ", xml);
    return ws_->sendText(xml);
}

void JitsiSignaling::sendOpen() {
    send("<open to='" + xmlEscape(activeXmppDomain()) + "' version='1.0' xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>");
}

void JitsiSignaling::sendAuth() {
    std::string mode = config_.authMode;
    std::transform(mode.begin(), mode.end(), mode.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

    if (mode == "plain") {
        const std::string payload = std::string("\0", 1) + config_.authUser + std::string("\0", 1) + config_.authPassword;
        send("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>" + base64Encode(payload) + "</auth>");
        return;
    }

    if (mode == "xoauth2") {
        const std::string payload = std::string("\0", 1) + config_.authUser + std::string("\0", 1) + config_.authToken;
        send("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='X-OAUTH2'>" + base64Encode(payload) + "</auth>");
        return;
    }

    if (mode == "oauthbearer") {
        const std::string payload = std::string("n,a=") + config_.authUser + ",\x01auth=Bearer " + config_.authToken + "\x01\x01";
        send("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='OAUTHBEARER'>" + base64Encode(payload) + "</auth>");
        return;
    }

    send("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='ANONYMOUS'/>");
}

void JitsiSignaling::sendBind() {
    if (bindSent_) return;
    bindSent_ = true;
    send("<iq xmlns='jabber:client' id='bind_1' type='set'>"
         "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>"
         "<resource>jitsi-ndi-native</resource>"
         "</bind></iq>");
}

void JitsiSignaling::sendSession() {
    if (sessionSent_) return;
    sessionSent_ = true;
    send("<iq xmlns='jabber:client' id='session_1' type='set'>"
         "<session xmlns='urn:ietf:params:xml:ns:xmpp-session'/>"
         "</iq>");
}

void JitsiSignaling::sendIqResult(const std::string& to, const std::string& id) {
    if (id.empty()) {
        Logger::warn("Cannot ACK IQ: missing id");
        return;
    }

    std::ostringstream iq;
    iq << "<iq xmlns='jabber:client' type='result' id='" << xmlEscape(id) << "'";
    if (!to.empty()) iq << " to='" << xmlEscape(to) << "'";
    iq << "/>";
    send(iq.str());
}

void JitsiSignaling::sendDiscoInfoResult(const std::string& requestXml) {
    const std::string iqTag = firstTag(requestXml, "iq");
    const std::string from = extractAttr(iqTag, "from");
    const std::string id = extractAttr(iqTag, "id");
    if (id.empty()) return;

    std::ostringstream iq;
    iq << "<iq xmlns='jabber:client' type='result' id='" << xmlEscape(id) << "'";
    if (!from.empty()) iq << " to='" << xmlEscape(from) << "'";
    iq << "><query xmlns='http://jabber.org/protocol/disco#info'>"
       << "<identity category='client' type='web' name='jitsi-ndi-native'/>"
       << "<feature var='urn:xmpp:jingle:1'/>"
       << "<feature var='urn:xmpp:jingle:apps:rtp:1'/>"
       << "<feature var='urn:xmpp:jingle:apps:rtp:audio'/>"
       << "<feature var='urn:xmpp:jingle:apps:rtp:video'/>"
       << "<feature var='urn:xmpp:jingle:transports:ice-udp:1'/>"
       << "<feature var='urn:xmpp:jingle:apps:dtls:0'/>"
       << "<feature var='http://jitsi.org/protocol/source-info'/>"
       << "</query></iq>";

    send(iq.str());
    Logger::info("XMPP >> disco#info result sent id=", id);
}

void JitsiSignaling::handleJingleSessionInitiate(const std::string& xml) {
    Logger::info("MEDIA EVENT: Jingle session-initiate detected.");

    JingleSessionInitiate session = JingleSessionParser::parseSessionInitiate(xml);
    if (!session.valid) return;

    jingleSessionInitiateSeen_ = true;

    Logger::info("MEDIA EVENT: parsed Jingle session-initiate:");
    Logger::info(session.summary());

    if (session.from.find("/focus") == std::string::npos) {
        Logger::warn("MEDIA EVENT: ignoring non-focus/P2P Jingle offer from ", session.from);
        sendIqResult(session.from, session.iqId);
        Logger::info("MEDIA EVENT: ACK sent for ignored P2P Jingle offer iq id=", session.iqId);
        return;
    }

    sendIqResult(session.from, session.iqId);
    Logger::info("MEDIA EVENT: ACK sent for Jingle session-initiate iq id=", session.iqId);

    const std::string offerSdp = session.toSdpOffer();
    {
        std::ofstream out("last_jitsi_offer.sdp", std::ios::binary);
        if (out) {
            out << offerSdp;
            Logger::info("MEDIA EVENT: wrote parsed SDP-like offer to last_jitsi_offer.sdp");
        } else {
            Logger::warn("MEDIA EVENT: could not write last_jitsi_offer.sdp");
        }
    }

    webRtcAnswerer_.setIceServers(iceServers_);
    webRtcAnswerer_.setResponderJid(boundJid_);

    NativeWebRTCAnswerResult answer = webRtcAnswerer_.acceptOffer(
        session,
        offerSdp,
        [this](const std::string& candidateXml) {
            send(candidateXml);
        }
    );

    if (!answer.ok) {
        Logger::warn("MEDIA EVENT: native WebRTC answer not ready: ", answer.error);
        Logger::warn("MEDIA EVENT: NDI stays on diagnostic/test-pattern frames until session-accept/media is live.");
        return;
    }

    Logger::info("MEDIA EVENT: native WebRTC answer created.");

    if (!answer.sessionAcceptXml.empty()) {
        send(answer.sessionAcceptXml);
        Logger::info("MEDIA EVENT: experimental Jingle session-accept sent before local transport-info.");
    } else {
        Logger::warn("MEDIA EVENT: sessionAcceptXml is empty.");
    }
}

bool JitsiSignaling::connect() {
    Logger::info("Jitsi signaling connect");
    Logger::info("Room: ", config_.room);
    Logger::info("Participant filter: ", config_.participantFilter.empty() ? "<none>" : config_.participantFilter);
    Logger::info("WebSocket URL: ", config_.websocketUrl);
    Logger::info("XMPP domain: ", config_.domain);
    Logger::info("Guest mode: ", config_.guestMode ? "ON" : "OFF");
    Logger::info("Active XMPP domain: ", activeXmppDomain());
    Logger::info("MUC domain: ", config_.mucDomain);
    Logger::info("Auth mode: ", config_.authMode);
    Logger::info("WebSocket query room/token: ", config_.addRoomAndTokenToWebSocketUrl ? "ON" : "OFF");

    if (!config_.realXmpp) {
        Logger::warn("Real Jitsi XMPP is disabled. Running old stub signaling path.");
        connected_ = true;
        return true;
    }

#ifndef _WIN32
    Logger::error("Real Jitsi XMPP WebSocket mode currently supports Windows builds only");
    return false;
#else
    const std::string url = websocketUrlForConnect();
    Logger::info("WebSocket connect URL: ", url);

    ws_ = std::make_unique<XmppWebSocketClient>(url);
    ws_->onMessage([this](const std::string& xml) {
        handleXmppMessage(xml);
    });

    if (!ws_->connect()) {
        Logger::error("Could not open Jitsi XMPP WebSocket");
        return false;
    }

    connected_ = true;

    sendOpen();
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    sendAuth();

    Logger::info("Jitsi XMPP auth bootstrap sent. Watch logs for <success>, <failure>, <presence>, jingle/colibri.");
    return true;
#endif
}

bool JitsiSignaling::joinRoom() {
    if (!connected_) return false;
    if (joinSent_) return true;

    joinSent_ = true;
    const std::string to = roomJid();
    Logger::info("Joining MUC room as: ", to);

    std::ostringstream presence;
    presence << "<presence xmlns='jabber:client' to='" << to << "'>"
             << "<x xmlns='http://jabber.org/protocol/muc'/>"
             << "<nick xmlns='http://jabber.org/protocol/nick'>" << xmlEscape(config_.nick) << "</nick>";

    if (!config_.authToken.empty()) {
        presence << "<token xmlns='http://jitsi.org/jitmeet/auth-token'>" << xmlEscape(config_.authToken) << "</token>";
    }

    presence << "<c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='https://github.com/jitsi-ndi-native' ver='native'/>"
             << "</presence>";

    return send(presence.str());
}

void JitsiSignaling::handleXmppMessage(const std::string& xml) {
    const int n = ++incomingCount_;
    Logger::info("XMPP << [", n, "] ", xml);

    if (xml.find("<success") != std::string::npos) {
        authSucceeded_ = true;
        Logger::info("XMPP auth accepted by server. Re-opening stream for bind/session.");
        sendOpen();
        return;
    }

    if (xml.find("<failure") != std::string::npos ||
        xml.find("not-authorized") != std::string::npos ||
        xml.find("not-allowed") != std::string::npos) {
        Logger::warn("XMPP auth or room join failed. For meet.jit.si try guest mode, token auth, or a self-hosted Jitsi domain.");
        return;
    }

    if (authSucceeded_ && !bindSent_ && xml.find("<stream:features") != std::string::npos) {
        sendBind();
        return;
    }

    if (bindSent_ && !sessionSent_ && xml.find("id='bind_1'") != std::string::npos && xml.find("type='result'") != std::string::npos) {
        const std::regex jidRe(R"(<jid>([^<]+)</jid>)");
        std::smatch m;
        if (std::regex_search(xml, m, jidRe) && m.size() > 1) {
            boundJid_ = m[1].str();
            webRtcAnswerer_.setResponderJid(boundJid_);
            Logger::info("Bound XMPP JID: ", boundJid_);
        }
        sendSession();
        return;
    }

    if (sessionSent_ && !joinSent_ && xml.find("id='session_1'") != std::string::npos) {
        joinRoom();
        return;
    }

    if (xml.find("<presence") != std::string::npos) {
        Logger::info("Presence received. This is the first sign that MUC join is alive.");
    }

    if ((xml.find("type='get'") != std::string::npos || xml.find("type=\"get\"") != std::string::npos) &&
        xml.find("disco#info") != std::string::npos) {
        sendDiscoInfoResult(xml);
        return;
    }

    if (xml.find("room_metadata") != std::string::npos && xml.find("meet-jit-si-turnrelay.jitsi.net") != std::string::npos) {
        parseAndStoreTurnServices(xml);
        return;
    }

    if (xml.find("session-terminate") != std::string::npos) {
        const std::string iqTagTerm = firstTag(xml, "iq");
        const std::string fromTerm = extractAttr(iqTagTerm, "from");
        const std::string idTerm = extractAttr(iqTagTerm, "id");
        sendIqResult(fromTerm, idTerm);
        Logger::info("MEDIA EVENT: Jingle session-terminate ACK sent id=", idTerm);
        Logger::info("MEDIA EVENT: old WebRTC session terminated by Jitsi. Keeping answerer object alive; next session-initiate will create a fresh PeerConnection.");
        return;
    }

    if (JingleSessionParser::isSessionInitiate(xml)) {
        handleJingleSessionInitiate(xml);
        return;
    }

    if (xml.find("transport-info") != std::string::npos) {
        const std::string iqTagTransport = firstTag(xml, "iq");
        const std::string fromTransport = extractAttr(iqTagTransport, "from");
        const std::string idTransport = extractAttr(iqTagTransport, "id");
        sendIqResult(fromTransport, idTransport);
        Logger::info("MEDIA EVENT: transport-info ACK sent id=", idTransport);

        const bool added = webRtcAnswerer_.addRemoteCandidatesFromTransportInfo(xml);
        Logger::info("MEDIA EVENT: remote ICE candidates from transport-info applied=", added ? "yes" : "no");
        return;
    }

    if (xml.find("source-add") != std::string::npos || xml.find("source-remove") != std::string::npos) {
        const std::string iqTagSource = firstTag(xml, "iq");
        const std::string fromSource = extractAttr(iqTagSource, "from");
        const std::string idSource = extractAttr(iqTagSource, "id");
        sendIqResult(fromSource, idSource);
        Logger::info("MEDIA EVENT: source-add/source-remove ACK sent id=", idSource);
        Logger::info("MEDIA EVENT: Source update detected. Dynamic SSRC application is intentionally not enabled yet.");
        return;
    }

    if (xml.find("colibri") != std::string::npos || xml.find("ssrc") != std::string::npos) {
        Logger::info("MEDIA EVENT: Jingle/Colibri/source/SSRC stanza detected.");
    }
}

void JitsiSignaling::disconnect() {
    if (!connected_) return;

    Logger::info("Jitsi signaling disconnect");

    if (ws_) {
        send("<close xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>");
        ws_->close();
        ws_.reset();
    }

    connected_ = false;
}
