#pragma once

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

class XmppWebSocketClient {
public:
    using MessageCallback = std::function<void(const std::string&)>;
    using ClosedCallback = std::function<void()>;

    XmppWebSocketClient();
    ~XmppWebSocketClient();

    XmppWebSocketClient(const XmppWebSocketClient&) = delete;
    XmppWebSocketClient& operator=(const XmppWebSocketClient&) = delete;

    void setOnMessage(MessageCallback cb);
    void setOnClosed(ClosedCallback cb);

    bool connect(const std::string& url);
    bool sendText(const std::string& text);
    void close();
    bool connected() const { return connected_; }

private:
    void receiveLoop();

    MessageCallback onMessage_;
    ClosedCallback onClosed_;
    std::atomic<bool> connected_{false};
    std::atomic<bool> closing_{false};
    std::thread recvThread_;
    std::mutex sendMutex_;

#if defined(_WIN32)
    void* hSession_ = nullptr;
    void* hConnect_ = nullptr;
    void* hWebSocket_ = nullptr;
#endif
};
