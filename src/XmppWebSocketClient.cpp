#include "XmppWebSocketClient.h"

#include "Logger.h"

#include <string>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#include <winhttp.h>
#pragma comment(lib, "winhttp.lib")
#endif

#if defined(_WIN32)
namespace {

std::wstring widenAscii(const std::string& text) {
    return std::wstring(text.begin(), text.end());
}

std::string narrowForLog(const std::wstring& text) {
    std::string out;
    out.reserve(text.size());

    for (wchar_t ch : text) {
        if (ch == L'\0') {
            continue;
        }

        if (ch >= 0 && ch <= 0x7F) {
            out.push_back(static_cast<char>(ch));
        } else {
            out.push_back('?');
        }
    }

    return out;
}

std::string queryRawHeadersForLog(HINTERNET request) {
    DWORD sizeBytes = 0;

    WinHttpQueryHeaders(
        request,
        WINHTTP_QUERY_RAW_HEADERS_CRLF,
        WINHTTP_HEADER_NAME_BY_INDEX,
        nullptr,
        &sizeBytes,
        WINHTTP_NO_HEADER_INDEX
    );

    const DWORD firstError = GetLastError();
    if (firstError != ERROR_INSUFFICIENT_BUFFER || sizeBytes == 0) {
        return {};
    }

    std::wstring headers;
    headers.resize(sizeBytes / sizeof(wchar_t));

    if (!WinHttpQueryHeaders(
            request,
            WINHTTP_QUERY_RAW_HEADERS_CRLF,
            WINHTTP_HEADER_NAME_BY_INDEX,
            headers.data(),
            &sizeBytes,
            WINHTTP_NO_HEADER_INDEX)) {
        return {};
    }

    headers.resize(sizeBytes / sizeof(wchar_t));
    return narrowForLog(headers);
}

std::string readHttpResponseBodyForLog(HINTERNET request) {
    std::string body;

    for (;;) {
        DWORD available = 0;
        if (!WinHttpQueryDataAvailable(request, &available) || available == 0) {
            break;
        }

        if (body.size() > 8192) {
            body += "\n...[body truncated]...";
            break;
        }

        std::vector<char> buffer(available + 1, '\0');
        DWORD read = 0;

        if (!WinHttpReadData(request, buffer.data(), available, &read) || read == 0) {
            break;
        }

        body.append(buffer.data(), read);
    }

    return body;
}

bool queryHttpStatusCode(HINTERNET request, DWORD& statusCode) {
    DWORD size = sizeof(statusCode);

    return WinHttpQueryHeaders(
        request,
        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX,
        &statusCode,
        &size,
        WINHTTP_NO_HEADER_INDEX
    ) == TRUE;
}

std::wstring buildWebSocketExtraHeaders(const std::wstring& host, INTERNET_PORT port, bool secure) {
    std::wstring origin = secure ? L"https://" : L"http://";
    origin += host;

    const bool defaultPort =
        (secure && port == INTERNET_DEFAULT_HTTPS_PORT) ||
        (!secure && port == INTERNET_DEFAULT_HTTP_PORT);

    if (!defaultPort) {
        origin += L":";
        origin += std::to_wstring(static_cast<unsigned int>(port));
    }

    std::wstring headers;
    headers += L"Origin: ";
    headers += origin;
    headers += L"\r\n";

    // RFC 7395: XMPP over WebSocket must negotiate the "xmpp" subprotocol.
    headers += L"Sec-WebSocket-Protocol: xmpp\r\n";

    return headers;
}

} // namespace
#endif

XmppWebSocketClient::XmppWebSocketClient() = default;

XmppWebSocketClient::~XmppWebSocketClient() {
    close();
}

void XmppWebSocketClient::setOnMessage(MessageCallback cb) {
    onMessage_ = std::move(cb);
}

void XmppWebSocketClient::setOnClosed(ClosedCallback cb) {
    onClosed_ = std::move(cb);
}

bool XmppWebSocketClient::connect(const std::string& url) {
#if !defined(_WIN32)
    (void)url;
    Logger::error("Real XMPP websocket is implemented for Windows/WinHTTP in this package");
    return false;
#else
    close();

    closing_ = false;
    connected_ = false;

    const std::wstring wurl = widenAscii(url);

    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwSchemeLength = static_cast<DWORD>(-1);
    parts.dwHostNameLength = static_cast<DWORD>(-1);
    parts.dwUrlPathLength = static_cast<DWORD>(-1);
    parts.dwExtraInfoLength = static_cast<DWORD>(-1);

    if (!WinHttpCrackUrl(wurl.c_str(), 0, 0, &parts)) {
        Logger::error("WinHttpCrackUrl failed for ", url, ": ", GetLastError());
        return false;
    }

    const bool secure = parts.nScheme == INTERNET_SCHEME_HTTPS;

    std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);

    if (parts.dwExtraInfoLength > 0) {
        path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    }

    Logger::info("WinHTTP websocket host: ", narrowForLog(host));
    Logger::info("WinHTTP websocket path: ", narrowForLog(path));

    hSession_ = WinHttpOpen(
        L"jitsi-ndi-native/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS,
        0
    );

    if (!hSession_) {
        Logger::error("WinHttpOpen failed: ", GetLastError());
        return false;
    }

    hConnect_ = WinHttpConnect(
        static_cast<HINTERNET>(hSession_),
        host.c_str(),
        parts.nPort,
        0
    );

    if (!hConnect_) {
        Logger::error("WinHttpConnect failed: ", GetLastError());
        close();
        return false;
    }

    HINTERNET hRequest = WinHttpOpenRequest(
        static_cast<HINTERNET>(hConnect_),
        L"GET",
        path.c_str(),
        nullptr,
        WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES,
        secure ? WINHTTP_FLAG_SECURE : 0
    );

    if (!hRequest) {
        Logger::error("WinHttpOpenRequest failed: ", GetLastError());
        close();
        return false;
    }

    if (!WinHttpSetOption(
            hRequest,
            WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET,
            nullptr,
            0)) {
        Logger::error("WinHttpSetOption WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET failed: ", GetLastError());
        WinHttpCloseHandle(hRequest);
        close();
        return false;
    }

    const std::wstring extraHeaders = buildWebSocketExtraHeaders(host, parts.nPort, secure);

    if (!WinHttpAddRequestHeaders(
            hRequest,
            extraHeaders.c_str(),
            static_cast<DWORD>(-1),
            WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE)) {
        Logger::error("WinHttpAddRequestHeaders failed: ", GetLastError());
        Logger::error("Headers attempted:\n", narrowForLog(extraHeaders));
        WinHttpCloseHandle(hRequest);
        close();
        return false;
    }

    Logger::info("WebSocket extra headers added: Sec-WebSocket-Protocol=xmpp, Origin set");

    if (!WinHttpSendRequest(
            hRequest,
            WINHTTP_NO_ADDITIONAL_HEADERS,
            0,
            WINHTTP_NO_REQUEST_DATA,
            0,
            0,
            0)) {
        Logger::error("WinHttpSendRequest websocket handshake failed: ", GetLastError());
        WinHttpCloseHandle(hRequest);
        close();
        return false;
    }

    if (!WinHttpReceiveResponse(hRequest, nullptr)) {
        Logger::error("WinHttpReceiveResponse websocket handshake failed: ", GetLastError());
        WinHttpCloseHandle(hRequest);
        close();
        return false;
    }

    DWORD statusCode = 0;
    if (!queryHttpStatusCode(hRequest, statusCode)) {
        Logger::error("WinHttpQueryHeaders HTTP status failed: ", GetLastError());

        const std::string rawHeaders = queryRawHeadersForLog(hRequest);
        if (!rawHeaders.empty()) {
            Logger::error("Handshake response headers:\n", rawHeaders);
        }

        WinHttpCloseHandle(hRequest);
        close();
        return false;
    }

    Logger::info("WebSocket handshake HTTP status: ", statusCode);

    if (statusCode != 101) {
        Logger::error("WebSocket upgrade rejected. Expected HTTP 101 Switching Protocols, got: ", statusCode);

        const std::string rawHeaders = queryRawHeadersForLog(hRequest);
        if (!rawHeaders.empty()) {
            Logger::error("Handshake response headers:\n", rawHeaders);
        }

        const std::string body = readHttpResponseBodyForLog(hRequest);
        if (!body.empty()) {
            Logger::error("Handshake response body:\n", body);
        }

        WinHttpCloseHandle(hRequest);
        close();
        return false;
    }

    HINTERNET hWs = WinHttpWebSocketCompleteUpgrade(hRequest, 0);
    const DWORD upgradeError = GetLastError();

    WinHttpCloseHandle(hRequest);

    if (!hWs) {
        Logger::error("WinHttpWebSocketCompleteUpgrade failed: ", upgradeError);
        close();
        return false;
    }

    hWebSocket_ = hWs;
    connected_ = true;

    Logger::info("WinHTTP websocket upgraded successfully");

    recvThread_ = std::thread([this]() {
        receiveLoop();
    });

    return true;
#endif
}

bool XmppWebSocketClient::sendText(const std::string& text) {
#if !defined(_WIN32)
    (void)text;
    return false;
#else
    if (!connected_ || !hWebSocket_) {
        return false;
    }

    std::lock_guard<std::mutex> lock(sendMutex_);

    const DWORD result = WinHttpWebSocketSend(
        static_cast<HINTERNET>(hWebSocket_),
        WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
        const_cast<char*>(text.data()),
        static_cast<DWORD>(text.size())
    );

    if (result != ERROR_SUCCESS) {
        Logger::error("WinHttpWebSocketSend failed: ", result);
        return false;
    }

    return true;
#endif
}

void XmppWebSocketClient::close() {
#if defined(_WIN32)
    closing_ = true;
    connected_ = false;

    if (hWebSocket_) {
        WinHttpWebSocketClose(
            static_cast<HINTERNET>(hWebSocket_),
            WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS,
            nullptr,
            0
        );
    }

    if (recvThread_.joinable()) {
        recvThread_.join();
    }

    if (hWebSocket_) {
        WinHttpCloseHandle(static_cast<HINTERNET>(hWebSocket_));
        hWebSocket_ = nullptr;
    }

    if (hConnect_) {
        WinHttpCloseHandle(static_cast<HINTERNET>(hConnect_));
        hConnect_ = nullptr;
    }

    if (hSession_) {
        WinHttpCloseHandle(static_cast<HINTERNET>(hSession_));
        hSession_ = nullptr;
    }
#else
    connected_ = false;
#endif
}

void XmppWebSocketClient::receiveLoop() {
#if defined(_WIN32)
    std::string message;
    std::vector<char> buffer(64 * 1024);

    while (!closing_ && hWebSocket_) {
        DWORD bytesRead = 0;
        WINHTTP_WEB_SOCKET_BUFFER_TYPE type{};

        const DWORD result = WinHttpWebSocketReceive(
            static_cast<HINTERNET>(hWebSocket_),
            buffer.data(),
            static_cast<DWORD>(buffer.size()),
            &bytesRead,
            &type
        );

        if (result != ERROR_SUCCESS) {
            if (!closing_) {
                Logger::warn("WinHttpWebSocketReceive stopped: ", result);
            }
            break;
        }

        if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
            Logger::info("WinHTTP websocket close frame received");
            break;
        }

        if (bytesRead > 0 &&
            (type == WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE ||
             type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE ||
             type == WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE ||
             type == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE)) {
            message.append(buffer.data(), bytesRead);
        }

        if (type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE ||
            type == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE) {
            if (onMessage_) {
                onMessage_(message);
            }

            message.clear();
        }
    }

    connected_ = false;

    if (!closing_ && onClosed_) {
        onClosed_();
    }
#endif
}