#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <vector>

namespace nfsios
{
// Network, node and socket, in the original IPX wire byte order.
using IPXAddress = std::array<uint8_t, 12>;
struct LANPeer
{
    IPXAddress address{};
    uint32_t ipv4 = 0;
    uint16_t udpPort = 0; // network byte order
};
// Keep the privacy-triggering browse alive beyond the game's short IPX probe.
// Call when the game (or a diagnostic session) finishes.
void stopLANAccess();
class LANDiscovery
{
public:
    LANDiscovery(const IPXAddress& address, uint16_t udpPort);
    ~LANDiscovery();
    std::vector<LANPeer> peers() const;
private:
    struct Impl;
    std::shared_ptr<Impl> m_impl;
};
}
