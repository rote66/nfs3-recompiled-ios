#ifndef LIB_TIMER_H_
#define LIB_TIMER_H_

#include <lib/winapp.h>
#include <winapi/types.h>
#include <lib/platform.h>

namespace win32
{

void getSystemTime(SYSTEMTIME* systemTime);
x86::reg32 timeGetTickCount();

class Timer : public GenericResource
{
public:
    Timer(x86::reg32 delay, WinApplication* app, x86::reg32 proc, x86::reg32 param);
    ~Timer();

    void cancel();
#ifdef NFS_IOS
    bool start();
    static void cancelEvent(WinApplication* app, x86::CPU& cpu, x86::reg32 handle);
#endif
private:
#ifndef NFS_IOS
    static Uint32 timerCallback(void* data, SDL_TimerID timerID, Uint32 interval);
#endif

private:
    WinApplication* m_app;
    x86::reg32      m_callback;
    x86::reg32      m_parameter;
#ifdef NFS_IOS
    void* m_id;
#else
    SDL_TimerID     m_id;
#endif
};

}

#endif
