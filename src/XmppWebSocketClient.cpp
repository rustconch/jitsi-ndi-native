#include "XmppWebSocketClient.h"
#include "Logger.h"

#include <algorithm>
#include <sstream>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#include <winhttp.h>
#pragma comment(lib, "winhttp.lib")
#endif

XmppWebSocketClient::XmppWebSocketClient(std::string url)
    : url_(std::move(url)) {}

XmppWebSocketClient::~XmppWebSocketClient() {
    close();
}

void XmppWebSocketClient::onMessage(MessageCallback cb) {
    onMessage_ = std::move(cb);
}

#ifndef _WIN32
bool XmppWebSocketClient::connect() {
    Logger::error("XmppWebSocketClient uses WinHTTP and currently supports Windows only");
    return false;
}

bool XmppWebSocketClient::sendText(const std::string&) {
    return false;
}

void XmppWebSocketClient::close() {
    running_ = false;
}

void XmppWebSocketClient::receiveLoop() {}
#else

namespace {
std::wstring utf8ToWide(const std::string& s) {
    if (s.empty()) return {};
    const int len = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring out(static_cast<std::size_t>(len), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), len);
    return out;
}

std::string wideToUtf8(const std::wstring& s) {
    if (s.empty()) return {};
    const int len = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<std::size_t>(len), '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), len, nullptr, nullptr);
    return out;
}

std::string lastWinHttpError(const std::string& prefix) {
    const DWORD err = GetLastError();
    std::ostringstream oss;
    oss << prefix << " WinHTTP/Win32 error=" << err;
    return oss.str();
}
}

bool XmppWebSocketClient::connect() {
    URL_COMPONENTS uc{};
    uc.dwStructSize = sizeof(uc);

    wchar_t host[512]{};
    wchar_t path[4096]{};
    uc.lpszHostName = host;
    uc.dwHostNameLength = static_cast<DWORD>(sizeof(host)/sizeof(host[0]));
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = static_cast<DWORD>(sizeof(path)/sizeof(path[0]));
    uc.lpszExtraInfo = path + 2048;
    uc.dwExtraInfoLength = 2048;

    const std::wstring wurl = utf8ToWide(url_);
    if (!WinHttpCrackUrl(wurl.c_str(), 0, 0, &uc)) {
        Logger::error(lastWinHttpError("WinHttpCrackUrl failed."));
        return false;
    }

    const bool secure = uc.nScheme == INTERNET_SCHEME_HTTPS;
    const std::wstring hostStr(host, uc.dwHostNameLength);
    std::wstring pathStr(uc.lpszUrlPath, uc.dwUrlPathLength);
    if (uc.dwExtraInfoLength > 0 && uc.lpszExtraInfo) {
        pathStr.append(uc.lpszExtraInfo, uc.dwExtraInfoLength);
    }
    if (pathStr.empty()) pathStr = L"/";

    session_ = WinHttpOpen(L"jitsi-ndi-native/0.2",
                           WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                           WINHTTP_NO_PROXY_NAME,
                           WINHTTP_NO_PROXY_BYPASS,
                           0);
    if (!session_) {
        Logger::error(lastWinHttpError("WinHttpOpen failed."));
        return false;
    }

    connection_ = WinHttpConnect(static_cast<HINTERNET>(session_), hostStr.c_str(), uc.nPort, 0);
    if (!connection_) {
        Logger::error(lastWinHttpError("WinHttpConnect failed."));
        close();
        return false;
    }

    DWORD flags = secure ? WINHTTP_FLAG_SECURE : 0;
    request_ = WinHttpOpenRequest(static_cast<HINTERNET>(connection_), L"GET", pathStr.c_str(), nullptr,
                                  WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!request_) {
        Logger::error(lastWinHttpError("WinHttpOpenRequest failed."));
        close();
        return false;
    }

    if (!WinHttpSetOption(static_cast<HINTERNET>(request_), WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0)) {
        Logger::error(lastWinHttpError("WinHttpSetOption upgrade failed."));
        close();
        return false;
    }

    if (!WinHttpSendRequest(static_cast<HINTERNET>(request_), WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) {
        Logger::error(lastWinHttpError("WinHttpSendRequest failed."));
        close();
        return false;
    }

    if (!WinHttpReceiveResponse(static_cast<HINTERNET>(request_), nullptr)) {
        Logger::error(lastWinHttpError("WinHttpReceiveResponse failed."));
        close();
        return false;
    }

    websocket_ = WinHttpWebSocketCompleteUpgrade(static_cast<HINTERNET>(request_), 0);
    request_ = nullptr;

    if (!websocket_) {
        Logger::error(lastWinHttpError("WinHttpWebSocketCompleteUpgrade failed."));
        close();
        return false;
    }

    running_ = true;
    receiveThread_ = std::thread(&XmppWebSocketClient::receiveLoop, this);
    Logger::info("WebSocket connected: ", url_);
    return true;
}

bool XmppWebSocketClient::sendText(const std::string& text) {
    if (!websocket_ || !running_) return false;
    std::lock_guard<std::mutex> lock(sendMutex_);

    const DWORD err = WinHttpWebSocketSend(static_cast<HINTERNET>(websocket_),
                                           WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,
                                           const_cast<char*>(text.data()),
                                           static_cast<DWORD>(text.size()));
    if (err != NO_ERROR) {
        Logger::warn("WinHttpWebSocketSend failed error=", err);
        return false;
    }
    return true;
}

void XmppWebSocketClient::receiveLoop() {
    std::vector<char> buffer(1024 * 1024);

    while (running_ && websocket_) {
        DWORD bytesRead = 0;
        WINHTTP_WEB_SOCKET_BUFFER_TYPE type = WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE;

        const DWORD err = WinHttpWebSocketReceive(static_cast<HINTERNET>(websocket_),
                                                  buffer.data(),
                                                  static_cast<DWORD>(buffer.size()),
                                                  &bytesRead,
                                                  &type);
        if (err != NO_ERROR) {
            if (running_) Logger::warn("WinHttpWebSocketReceive failed error=", err);
            break;
        }

        if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
            Logger::info("WebSocket close frame received");
            break;
        }

        if ((type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE ||
             type == WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE) && bytesRead > 0) {
            std::string message(buffer.data(), buffer.data() + bytesRead);
            if (onMessage_) onMessage_(message);
        }
    }

    running_ = false;
}

void XmppWebSocketClient::close() {
    running_ = false;

    if (websocket_) {
        WinHttpWebSocketClose(static_cast<HINTERNET>(websocket_), WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS, nullptr, 0);
    }

    if (receiveThread_.joinable()) {
        receiveThread_.join();
    }

    if (websocket_) {
        WinHttpCloseHandle(static_cast<HINTERNET>(websocket_));
        websocket_ = nullptr;
    }
    if (request_) {
        WinHttpCloseHandle(static_cast<HINTERNET>(request_));
        request_ = nullptr;
    }
    if (connection_) {
        WinHttpCloseHandle(static_cast<HINTERNET>(connection_));
        connection_ = nullptr;
    }
    if (session_) {
        WinHttpCloseHandle(static_cast<HINTERNET>(session_));
        session_ = nullptr;
    }
}
#endif
