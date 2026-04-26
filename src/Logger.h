#pragma once

#include <iostream>
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
        std::ostringstream ss;
        (ss << ... << std::forward<Args>(args));
        writeLine(level, ss.str());
    }

    static void writeLine(const char* level, const std::string& text);
    static std::mutex& mutex();
};
