#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

class XmppWebSocketClient {
public:
    using MessageCallback = std::function<void(const std::string&)>;

    explicit XmppWebSocketClient(std::string url);
    ~XmppWebSocketClient();

    void onMessage(MessageCallback cb);
    bool connect();
    bool sendText(const std::string& text);
    void close();

private:
    void receiveLoop();

    std::string url_;
    MessageCallback onMessage_;
    std::atomic<bool> running_{false};
    std::thread receiveThread_;
    std::mutex sendMutex_;

#ifdef _WIN32
    void* session_ = nullptr;
    void* connection_ = nullptr;
    void* request_ = nullptr;
    void* websocket_ = nullptr;
#endif
};
