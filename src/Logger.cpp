#include "Logger.h"

#include <chrono>
#include <ctime>
#include <iomanip>

std::mutex& Logger::mutex() {
    static std::mutex m;
    return m;
}

void Logger::writeLine(const char* level, const std::string& text) {
    using namespace std::chrono;
    const auto now = system_clock::now();
    const auto tt = system_clock::to_time_t(now);
    const auto ms = duration_cast<milliseconds>(now.time_since_epoch()) % 1000;

    std::tm tm{};
#if defined(_WIN32)
    localtime_s(&tm, &tt);
#else
    localtime_r(&tt, &tm);
#endif

    std::lock_guard<std::mutex> lock(mutex());
    std::cout << std::put_time(&tm, "%H:%M:%S")
              << '.' << std::setw(3) << std::setfill('0') << ms.count()
              << " [" << level << "] " << text << std::endl;
}
