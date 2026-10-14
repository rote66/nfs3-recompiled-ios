#pragma once

#include <lib/winapp.h>
#include "LANDiscovery.h"
#include <atomic>
#include <deque>
#include <memory>
#include <vector>

namespace win32
{
class Socket : public GenericResource
{
public:
    struct Packet
    {
        nfsios::IPXAddress source{};
        std::vector<uint8_t> bytes;
    };
    struct State
    {
        int descriptor = -1;
        std::atomic<bool> closed{false};
        bool bound = false;
        bool nonblocking = false;
        bool broadcast = false;
        uint8_t packetType = 0;
        int filterType = -1;
        unsigned sentPackets = 0, receivedPackets = 0;
        unsigned wirePackets = 0, lastRecipients = ~0u;
        nfsios::IPXAddress address{};
        std::unique_ptr<nfsios::LANDiscovery> discovery;
        std::deque<Packet> packets;
        ~State();
        void close();
        int bind(const nfsios::IPXAddress& requested);
        int send(const void* bytes, int length, const nfsios::IPXAddress& destination);
        int pump();
    };

    explicit Socket(WinApplication* app);
    ~Socket();
    std::shared_ptr<State> state() const { return m_state; }
    static void init(WinApplication* app);
    static bool fini(WinApplication* app);
    static void cleanup(WinApplication* app);
    static bool initialized(WinApplication* app);
    static x86::reg32 netToA(WinApplication* app, x86::reg32 address);
    static int winsockError(int nativeError);

private:
    std::shared_ptr<State> m_state;
};
}
