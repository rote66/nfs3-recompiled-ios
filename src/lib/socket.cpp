#include <lib/socket.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstdlib>
#include <algorithm>
#include <map>

namespace win32
{
namespace
{
struct Session
{
    unsigned references = 0;
    std::unique_ptr<MemMap> text;
    std::vector<std::weak_ptr<Socket::State>> sockets;
};
std::map<WinApplication*, Session> sessions;
// A locally administered virtual node identifies this process and all its sockets.
const std::array<uint8_t, 6>& localNode()
{
    static const auto node = [] {
        std::array<uint8_t, 6> value;
        arc4random_buf(value.data(), value.size());
        value[0] = (value[0] | 2) & ~1;
        return value;
    }();
    return node;
}
bool broadcastNode(const nfsios::IPXAddress& address)
{
    return std::all_of(address.begin() + 4, address.begin() + 10, [](uint8_t byte) { return byte == 255; });
}
bool matchesNetwork(const nfsios::IPXAddress& destination, const nfsios::IPXAddress& local)
{
    // The original lobby sends discovery to FFFFFFFF:FFFFFFFFFFFF:0452.
    // Its all-FF network is a wildcard on our single virtual LAN.
    return std::all_of(destination.begin(), destination.begin() + 4, [](uint8_t byte) { return byte == 0; }) ||
        (broadcastNode(destination) &&
         std::all_of(destination.begin(), destination.begin() + 4, [](uint8_t byte) { return byte == 255; })) ||
        std::equal(destination.begin(), destination.begin() + 4, local.begin());
}
constexpr size_t headerSize = 32;
constexpr int maxPayload = 1600;
}
Socket::Socket(WinApplication* app) : m_state(std::make_shared<State>())
{
    m_state->descriptor = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (m_state->descriptor >= 0)
    {
        if (::fcntl(m_state->descriptor, F_SETFL, O_NONBLOCK) < 0)
        {
            int error = errno;
            ::close(m_state->descriptor);
            m_state->descriptor = -1;
            errno = error;
        }
        else
        {
            int buffer = 256 * 1024;
            ::setsockopt(m_state->descriptor, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer));
        }
    }
    auto& sockets = sessions[app].sockets;
    sockets.erase(std::remove_if(sockets.begin(), sockets.end(), [](const auto& item) { return item.expired(); }), sockets.end());
    sockets.push_back(m_state);
}
Socket::~Socket() { m_state->close(); }
Socket::State::~State() { if (descriptor >= 0) ::close(descriptor); }
void Socket::State::close()
{
    if (closed.exchange(true)) return;
    if (bound) platform::log("NFS3_LAN: IPX socket closed; guest port=%u sent=%u received=%u",
        (address[10] << 8) | address[11], sentPackets, receivedPackets);
    discovery.reset();
    packets.clear();
}
int Socket::State::bind(const nfsios::IPXAddress& requested)
{
    if (bound) return 10022;
    if (std::any_of(requested.begin(), requested.begin() + 4, [](uint8_t byte) { return byte != 0; }) ||
        (!std::all_of(requested.begin() + 4, requested.begin() + 10, [](uint8_t byte) { return byte == 0; }) &&
         !std::equal(localNode().begin(), localNode().end(), requested.begin() + 4))) return 10049;
    sockaddr_in native{};
    native.sin_len = sizeof(native);
    native.sin_family = AF_INET;
    if (::bind(descriptor, reinterpret_cast<::sockaddr*>(&native), sizeof(native)) < 0) return winsockError(errno);
    socklen_t size = sizeof(native);
    if (::getsockname(descriptor, reinterpret_cast<::sockaddr*>(&native), &size) < 0) return winsockError(errno);
    address = requested;
    std::copy(localNode().begin(), localNode().end(), address.begin() + 4);
    if (!address[10] && !address[11]) memcpy(address.data() + 10, &native.sin_port, 2);
    discovery = std::make_unique<nfsios::LANDiscovery>(address, ntohs(native.sin_port));
    bound = true;
    platform::log("NFS3_LAN: bound IPX guest port=%u over UDP port=%u", (address[10] << 8) | address[11], ntohs(native.sin_port));
    return 0;
}
int Socket::State::send(const void* bytes, int length, const nfsios::IPXAddress& destination)
{
    if (length > maxPayload) return 10040;
    if (!bound) return 10022;
    bool all = broadcastNode(destination);
    if (all && !broadcast) return 10013;
    std::vector<uint8_t> wire(headerSize + length);
    memcpy(wire.data(), "N3LX", 4);
    wire[4] = 1;
    wire[5] = packetType;
    wire[6] = uint8_t(length >> 8);
    wire[7] = uint8_t(length);
    memcpy(wire.data() + 8, destination.data(), 12);
    memcpy(wire.data() + 20, address.data(), 12);
    if (length) memcpy(wire.data() + headerSize, bytes, length);
    int error = 0;
    unsigned recipients = 0;
    const auto peers = discovery->peers();
    for (const auto& peer : peers)
    {
        if (!std::equal(destination.begin() + 10, destination.end(), peer.address.begin() + 10)) continue;
        if (!all && !std::equal(destination.begin() + 4, destination.begin() + 10, peer.address.begin() + 4)) continue;
        if (!matchesNetwork(destination, peer.address)) continue;
        sockaddr_in endpoint{};
        endpoint.sin_len = sizeof(endpoint);
        endpoint.sin_family = AF_INET;
        endpoint.sin_addr.s_addr = peer.ipv4;
        endpoint.sin_port = peer.udpPort;
        ++recipients;
        if (::sendto(descriptor, wire.data(), wire.size(), 0, reinterpret_cast<::sockaddr*>(&endpoint), sizeof(endpoint)) < 0)
            error = winsockError(errno);
    }
    if (sentPackets++ < 8 || recipients != lastRecipients)
        platform::log("NFS3_LAN: send guest=%u destination=%u broadcast=%d bytes=%d peers=%zu recipients=%u error=%d type=%u network=%02x%02x%02x%02x",
            (address[10] << 8) | address[11], (destination[10] << 8) | destination[11],
            int(all), length, peers.size(), recipients, error, packetType,
            destination[0], destination[1], destination[2], destination[3]);
    lastRecipients = recipients;
    return error;
}
int Socket::State::pump()
{
    if (closed) return 10038;
    std::array<uint8_t, 65536> wire;
    for (unsigned iteration = 0; iteration < 256; ++iteration)
    {
        ssize_t count = ::recvfrom(descriptor, wire.data(), wire.size(), 0, nullptr, nullptr);
        if (count < 0) return errno == EAGAIN || errno == EWOULDBLOCK ? 0 : winsockError(errno);
        if (wirePackets++ < 8)
            platform::log("NFS3_LAN: UDP received guest=%u bytes=%zd type=%u filter=%d",
                (address[10] << 8) | address[11], count, count > 5 ? wire[5] : 0, filterType);
        if (count < ssize_t(headerSize) || memcmp(wire.data(), "N3LX", 4) || wire[4] != 1) continue;
        unsigned length = (wire[6] << 8) | wire[7];
        if (length > maxPayload || count != ssize_t(headerSize + length)) continue;
        nfsios::IPXAddress destination, source;
        memcpy(destination.data(), wire.data() + 8, 12);
        memcpy(source.data(), wire.data() + 20, 12);
        if (memcmp(source.data() + 4, address.data() + 4, 6) == 0) continue;
        if (memcmp(destination.data() + 10, address.data() + 10, 2)) continue;
        if (!broadcastNode(destination) && memcmp(destination.data() + 4, address.data() + 4, 6)) continue;
        if (!matchesNetwork(destination, address)) continue;
        if (filterType >= 0 && wire[5] != filterType) continue;
        if (packets.size() < 256)
        {
            packets.push_back({source, std::vector<uint8_t>(wire.begin() + headerSize, wire.begin() + count)});
            if (receivedPackets++ < 8)
                platform::log("NFS3_LAN: receive guest=%u source=%u bytes=%u",
                    (address[10] << 8) | address[11], (source[10] << 8) | source[11], length);
        }
    }
    return 0;
}
void Socket::init(WinApplication* app)
{
    auto& session = sessions[app];
    if (!session.references++) session.text = std::make_unique<MemMap>(4096);
}
bool Socket::initialized(WinApplication* app)
{
    auto found = sessions.find(app);
    return found != sessions.end() && found->second.references;
}
bool Socket::fini(WinApplication* app)
{
    if (!initialized(app)) return false;
    if (!--sessions[app].references) cleanup(app);
    return true;
}
void Socket::cleanup(WinApplication* app)
{
    auto found = sessions.find(app);
    if (found == sessions.end()) return;
    for (auto& weak : found->second.sockets) if (auto socket = weak.lock()) socket->close();
    sessions.erase(found);
}
x86::reg32 Socket::netToA(WinApplication* app, x86::reg32 value)
{
    auto& text = sessions.at(app).text;
    char* buffer = &app->getMemory<char>(text->getBlockStart());
    snprintf(buffer, 16, "%u.%u.%u.%u", value & 255, (value >> 8) & 255, (value >> 16) & 255, value >> 24);
    return text->getBlockStart();
}
int Socket::winsockError(int error)
{
    switch (error)
    {
    case 0: return 0;
    case EINTR: return 10004;
    case EACCES: case EPERM: return 10013;
    case EFAULT: return 10014;
    case EINVAL: return 10022;
    case EMFILE: case ENFILE: return 10024;
    case EAGAIN: return 10035;
    case EBADF: case ENOTSOCK: return 10038;
    case EMSGSIZE: return 10040;
    case EOPNOTSUPP: return 10045;
    case EAFNOSUPPORT: return 10047;
    case EADDRINUSE: return 10048;
    case EADDRNOTAVAIL: return 10049;
    case ENETDOWN: return 10050;
    case ENETUNREACH: return 10051;
    case ENOBUFS: case ENOMEM: return 10055;
    case ETIMEDOUT: return 10060;
    case ECONNREFUSED: return 10061;
    case EHOSTUNREACH: return 10065;
    default: return 10022;
    }
}
}
