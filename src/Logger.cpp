#include "Logger.h"

#include <chrono>
#include <ctime>
#include <iomanip>
#include <iostream>

std::mutex& Logger::mutex() {
    static std::mutex m;
    return m;
}

void Logger::writeLine(const char* level, const std::string& message) {
    using namespace std::chrono;

    const auto now = system_clock::now();
    const auto nowTime = system_clock::to_time_t(now);

    std::tm tm{};
#ifdef _WIN32
    localtime_s(&tm, &nowTime);
#else
    localtime_r(&nowTime, &tm);
#endif

    std::lock_guard<std::mutex> lock(mutex());
    std::cout << std::put_time(&tm, "%H:%M:%S")
              << " [" << level << "] "
              << message << std::endl;
}
