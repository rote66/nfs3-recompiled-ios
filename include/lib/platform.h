#pragma once

#include <chrono>
#include <cstdarg>
#include <cstdio>


namespace win32::platform
{
inline void log(const char* format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    vfprintf(stderr, format, arguments);
    fputc('\n', stderr);
    va_end(arguments);
}

inline uint64_t nanoseconds()
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

void showMessage(const char* title, const char* text);
uint64_t guestNanoseconds();
}
