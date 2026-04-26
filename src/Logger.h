#pragma once

#include <mutex>
#include <sstream>
#include <string>

class Logger {
public:
    template <typename... Args>
    static void info(Args&&... args) { write("INFO", std::forward<Args>(args)...); }

    template <typename... Args>
    static void warn(Args&&... args) { write("WARN", std::forward<Args>(args)...); }

    template <typename... Args>
    static void error(Args&&... args) { write("ERROR", std::forward<Args>(args)...); }

private:
    template <typename... Args>
    static void write(const char* level, Args&&... args) {
        std::ostringstream oss;
        (oss << ... << std::forward<Args>(args));
        writeLine(level, oss.str());
    }

    static void writeLine(const char* level, const std::string& message);
    static std::mutex& mutex();
};
