#include "XmppWebSocketClient.h"
#include "Logger.h"

#include <vector>

#if defined(_WIN32)
#include <windows.h>
#include <winhttp.h>
#pragma comment(lib, "winhttp.lib")
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

    std::wstring wurl(url.begin(), url.end());
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwSchemeLength = static_cast<DWORD>(-1);
    parts.dwHostNameLength = static_cast<DWORD>(-1);
    parts.dwUrlPathLength = static_cast<DWORD>(-1);
    parts.dwExtraInfoLength = static_cast<DWORD>(-1);

    if (!WinHttpCrackUrl(wurl.c_str(), 0, 0, &parts)) {
        Logger::error("WinHttpCrackUrl failed for ", url);
        return false;
    }

    const bool secure = parts.nScheme == INTERNET_SCHEME_HTTPS;
    std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
    if (parts.dwExtraInfoLength > 0) {
        path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    }

    hSession_ = WinHttpOpen(L"jitsi-ndi-native/1.0",
                            WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                            WINHTTP_NO_PROXY_NAME,
                            WINHTTP_NO_PROXY_BYPASS,
                            0);
    if (!hSession_) {
        Logger::error("WinHttpOpen failed: ", GetLastError());
        return false;
    }

    hConnect_ = WinHttpConnect(static_cast<HINTERNET>(hSession_), host.c_str(), parts.nPort, 0);
    if (!hConnect_) {
        Logger::error("WinHttpConnect failed: ", GetLastError());
        close();
        return false;
    }

    HINTERNET hRequest = WinHttpOpenRequest(static_cast<HINTERNET>(hConnect_),
                                            L"GET",
                                            path.c_str(),
                                            nullptr,
                                            WINHTTP_NO_REFERER,
                                            WINHTTP_DEFAULT_ACCEPT_TYPES,
                                            secure ? WINHTTP_FLAG_SECURE : 0);
    if (!hRequest) {
        Logger::error("WinHttpOpenRequest failed: ", GetLastError());
        close();
        return false;
    }

    if (!WinHttpSetOption(hRequest, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0)) {
        Logger::error("WinHttpSetOption websocket upgrade failed: ", GetLastError());
        WinHttpCloseHandle(hRequest);
        close();
        return false;
    }

    if (!WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(hRequest, nullptr)) {
        Logger::error("WinHTTP websocket handshake failed: ", GetLastError());
        WinHttpCloseHandle(hRequest);
        close();
        return false;
    }

    HINTERNET hWs = WinHttpWebSocketCompleteUpgrade(hRequest, 0);
    WinHttpCloseHandle(hRequest);
    if (!hWs) {
        Logger::error("WinHttpWebSocketCompleteUpgrade failed: ", GetLastError());
        close();
        return false;
    }

    hWebSocket_ = hWs;
    connected_ = true;
    recvThread_ = std::thread([this]() { receiveLoop(); });
    return true;
#endif
}

bool XmppWebSocketClient::sendText(const std::string& text) {
#if !defined(_WIN32)
    (void)text;
    return false;
#else
    if (!connected_ || !hWebSocket_) return false;
    std::lock_guard<std::mutex> lock(sendMutex_);
    const DWORD result = WinHttpWebSocketSend(static_cast<HINTERNET>(hWebSocket_),
                                              WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
                                              const_cast<char*>(text.data()),
                                              static_cast<DWORD>(text.size()));
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
        WinHttpWebSocketClose(static_cast<HINTERNET>(hWebSocket_), WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, nullptr, 0);
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
        const DWORD result = WinHttpWebSocketReceive(static_cast<HINTERNET>(hWebSocket_),
                                                     buffer.data(),
                                                     static_cast<DWORD>(buffer.size()),
                                                     &bytesRead,
                                                     &type);
        if (result != ERROR_SUCCESS) {
            if (!closing_) Logger::warn("WinHttpWebSocketReceive stopped: ", result);
            break;
        }

        if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
            break;
        }

        if (bytesRead > 0 && (type == WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE ||
                              type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE ||
                              type == WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE ||
                              type == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE)) {
            message.append(buffer.data(), bytesRead);
        }

        if (type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE ||
            type == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE) {
            if (onMessage_) onMessage_(message);
            message.clear();
        }
    }

    connected_ = false;
    if (!closing_ && onClosed_) onClosed_();
#endif
}
