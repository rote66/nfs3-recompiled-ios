#pragma once

#include <chrono>
#include <cstdarg>
#include <cstdio>

#ifndef NFS_IOS
#include <SDL3/SDL.h>
#endif

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

#ifdef NFS_IOS
void showMessage(const char* title, const char* text);
uint64_t guestNanoseconds();
#endif
}
