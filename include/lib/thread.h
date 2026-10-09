#ifndef LIB_THREAD_H_
#define LIB_THREAD_H_

#include <lib/winapp.h>
#include <lib/platform.h>
#include <memory>

struct SDL_Thread;

namespace win32
{

class Thread : public GenericResource
{
public:
    Thread();
    Thread(WinApplication* app, x86::reg32 method, x86::reg32 parameter, x86::reg32 flags);
    ~Thread();

    Thread* duplicate()
    {
        return new Thread(*this);
    }

    void resume();
    void terminate();
    x86::reg32 threadId() const;
    static void sleep(x86::reg32 milliseconds);
    static x86::reg32 currentThreadId();

private:
    Thread(const Thread& other);
    static int run(void* parameter);

private:
#ifdef NFS_IOS
    struct NativeThread;
    std::shared_ptr<NativeThread> m_native;
#else
    struct Data
    {
        Data(WinApplication* app, x86::reg32 entryPoint, x86::reg32 parameter, x86::reg32 flags);
        WinApplication* m_app;
        x86::reg32      m_entryPoint;
        x86::reg32      m_parameter;
        x86::reg32      m_flags;
        x86::reg32      m_threadId;
    };

    SDL_AtomicInt*  m_refCount;
    SDL_Semaphore*  m_semaphore;
    Data            m_data;
    SDL_Thread*     m_thread;
    x86::CPU        m_cpu;
#endif
};

}

#endif
