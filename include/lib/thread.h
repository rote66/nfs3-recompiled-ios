#ifndef LIB_THREAD_H_
#define LIB_THREAD_H_

#include <lib/winapp.h>
#include <lib/platform.h>
#include <memory>


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
    struct NativeThread;
    std::shared_ptr<NativeThread> m_native;
};

}

#endif
