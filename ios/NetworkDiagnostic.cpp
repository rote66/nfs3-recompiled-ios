#include "Native.h"
#include "LANDiscovery.h"
#include <nfs3hp.h>
#include <lib/mutex.h>
#include <lib/file.h>
#include <lib/socket.h>
#include <lib/thread.h>
#include <winapi/wsock32.h>
#include <winapi/kernel32.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <bitset>
#include <chrono>
#include <condition_variable>
#include <initializer_list>
#include <mutex>
#include <thread>

namespace
{
namespace wsa = win32::wsock32;
struct GuestCalls
{
    nfs3hp::Application& game;
    win32::MemMap memory{64 * 1024};
    x86::CPU& cpu;
    uint32_t savedStack;
    GuestCalls(nfs3hp::Application& app, x86::CPU& context) : game(app), cpu(context), savedStack(cpu.esp) {}
    ~GuestCalls() { cpu.esp = savedStack + 4; }
    uint32_t call(uint32_t address, std::initializer_list<uint32_t> arguments = {})
    {
        uint32_t top = memory.getBlockStart() + memory.getBlockSize() - 256;
        cpu.esp = top - 4 * (arguments.size() + 1);
        game.getMemory<uint32_t>(cpu.esp) = 0;
        unsigned index = 0;
        for (uint32_t argument : arguments) game.getMemory<uint32_t>(cpu.esp + 4 * ++index) = argument;
        game.dynamic_call(address, cpu);
        if (cpu.terminate || cpu.esp != top) win32::platform::log("NFS3_NETWORK_CALL_ERROR: address=%08x terminate=%d esp=%08x expected=%08x", address, int(cpu.terminate), cpu.esp, top);
        NFS2_ASSERT(!cpu.terminate && cpu.esp == top);
        return cpu.eax;
    }
    void yield(unsigned milliseconds)
    {
        game.unlockContext(cpu);
        std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
        game.lockContext(cpu);
    }
};
struct PairState
{
    nfsios::IPXAddress peer{};
    bool found = false;
    bool unicast = false;
    bool complete = false;
    std::bitset<120> frames;
};
PairState* pairState = nullptr;
struct BlockingState
{
    std::atomic<bool> waiting{false}, finished{false};
    uint32_t guestThread = 0, nativeThread = 0;
};
BlockingState* blockingState = nullptr;
}

namespace nfsios
{
void networkDiagnosticRun(win32::WinApplication* app, x86::CPU& cpu)
{
    auto& game = *static_cast<nfs3hp::Application*>(app);
    GuestCalls guest(game, cpu);
    guest.call(0x4f1c70); // Use the same CPU / MMX memory-copy setup as game startup.
    cpu.eax = 0; // The original IPX vtable enters here without clearing its object.
    NFS2_ASSERT(guest.call(0x4f5fd0) == 1);
    win32::platform::log("NFS3_NETWORK_PASS: original IPX ready callback entry");
    uint32_t filename = guest.memory.getBlockStart() + 4096;
    uint32_t versionBuffer = filename + 512, query = filename + 4096;
    uint32_t resultPointer = query + 512, resultLength = query + 516;
    strcpy(&game.getMemory<char>(filename), "nfs3.exe");
    uint32_t versionSize = guest.call(0x400a81, {filename, resultLength});
    NFS2_ASSERT(versionSize > 52 && versionSize < 3000);
    NFS2_ASSERT(guest.call(0x400a80, {filename, 0, versionSize - 1, versionBuffer}) == 0);
    NFS2_ASSERT(guest.call(0x400a80, {filename, 0, versionSize, versionBuffer}) == 1);
    strcpy(&game.getMemory<char>(query), "\\StringFileInfo\\040904b0\\FileVersion");
    NFS2_ASSERT(guest.call(0x400a82, {versionBuffer, query, resultPointer, resultLength}) == 1);
    uint32_t versionString = game.getMemory<uint32_t>(resultPointer);
    NFS2_ASSERT(strcmp(&game.getMemory<char>(versionString), "27, 2.0") == 0);
    NFS2_ASSERT(game.getMemory<uint32_t>(resultLength) == 8);
    strcpy(&game.getMemory<char>(query), "\\");
    NFS2_ASSERT(guest.call(0x400a82, {versionBuffer, query, resultPointer, resultLength}) == 1);
    NFS2_ASSERT(game.getMemory<uint32_t>(game.getMemory<uint32_t>(resultPointer)) == 0xfeef04bd);
    NFS2_ASSERT(game.getMemory<uint32_t>(resultLength) == 52);
    strcpy(&game.getMemory<char>(query), "\\VarFileInfo\\Translation");
    NFS2_ASSERT(guest.call(0x400a82, {versionBuffer, query, resultPointer, resultLength}) == 1);
    NFS2_ASSERT(game.getMemory<uint32_t>(game.getMemory<uint32_t>(resultPointer)) == 0x04b00409);
    NFS2_ASSERT(game.getMemory<uint32_t>(resultLength) == 4);
    strcpy(&game.getMemory<char>(query), "\\StringFileInfo\\040904b0\\MissingValue");
    NFS2_ASSERT(guest.call(0x400a82, {versionBuffer, query, resultPointer, resultLength}) == 0);
    win32::platform::log("NFS3_NETWORK_PASS: real EXE FileVersion, fixed version, translation and invalid query");
    wsa::WSADATA data;
    NFS2_ASSERT(wsa::socket(&game, cpu, 6, 2, 1000) == uint32_t(-1));
    NFS2_ASSERT(wsa::WSAGetLastError(&game, cpu) == 10093);
    for (unsigned session = 0; session < 3; ++session)
    {
        NFS2_ASSERT(wsa::WSAStartup(&game, cpu, 0x0101, &data) == 0);
        NFS2_ASSERT(data.wVersion == 0x0101 && data.iMaxUdpDg == 1600);
        NFS2_ASSERT(wsa::WSAStartup(&game, cpu, 0x0101, &data) == 0);
        NFS2_ASSERT(wsa::WSACleanup(&game, cpu) == 0);
        NFS2_ASSERT(wsa::socket(&game, cpu, 2, 1, 0) == uint32_t(-1));
        NFS2_ASSERT(wsa::WSAGetLastError(&game, cpu) == 10047);
        uint32_t handle = wsa::socket(&game, cpu, 6, 2, 1000);
        NFS2_ASSERT(handle != uint32_t(-1));
        wsa::sockaddr local{}; local.sa_family = 6;
        local.sa_data[10] = char(0x96); local.sa_data[11] = char(0xff);
        NFS2_ASSERT(wsa::bind(&game, cpu, handle, &local, 14) == 0);
        int size = 14;
        local.sa_data[12] = 0x55; local.sa_data[13] = 0x66;
        NFS2_ASSERT(wsa::getsockname(&game, cpu, handle, &local, &size) == 0 && size == 14 && local.sa_family == 6);
        NFS2_ASSERT(local.sa_data[12] == 0x55 && local.sa_data[13] == 0x66);
        uint32_t enabled = 1;
        NFS2_ASSERT(wsa::ioctlsocket(&game, cpu, handle, int32_t(0x8004667e), &enabled) == 0);
        uint32_t text = guest.memory.getBlockStart() + 512;
        strcpy(&game.getMemory<char>(text), "192.168.1.255");
        uint32_t ip = guest.call(0x400a87, {text});
        NFS2_ASSERT(ip == 0xff01a8c0);
        uint32_t formatted = guest.call(0x400a85, {ip});
        NFS2_ASSERT(strcmp(&game.getMemory<char>(formatted), "192.168.1.255") == 0);
        uint32_t argument = guest.memory.getBlockStart() + 1024;
        game.getMemory<uint32_t>(argument) = 1;
        NFS2_ASSERT(guest.call(0x533e50, {handle, 0x8004667e, argument}) == 0);
        char buffer[32]{};
        NFS2_ASSERT(wsa::recvfrom(&game, cpu, handle, buffer, sizeof(buffer), 0, nullptr, nullptr) == -1);
        NFS2_ASSERT(wsa::WSAGetLastError(&game, cpu) == 10035);
        NFS2_ASSERT(wsa::recvfrom(&game, cpu, 0xabcdef, buffer, sizeof(buffer), 0, nullptr, nullptr) == -1);
        NFS2_ASSERT(wsa::WSAGetLastError(&game, cpu) == 10038);
        auto state = dynamic_cast<win32::Socket*>(game.getResource(handle))->state();
        sockaddr_in target{}; target.sin_len = sizeof(target); target.sin_family = AF_INET;
        target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        socklen_t nativeSize = sizeof(target);
        NFS2_ASSERT(::getsockname(state->descriptor, reinterpret_cast<::sockaddr*>(&target), &nativeSize) == 0);
        target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        int sender = ::socket(AF_INET, SOCK_DGRAM, 0);
        NFS2_ASSERT(sender >= 0);
        std::array<uint8_t, 48> packet{};
        memcpy(packet.data(), "N3LX", 4); packet[4] = 1; packet[7] = 16;
        memcpy(packet.data() + 8, state->address.data(), 12);
        packet[24] = 0x82; packet[29] = 0xff; packet[30] = 0xff; packet[31] = 0x96;
        for (unsigned i = 0; i < 16; ++i) packet[32 + i] = uint8_t(0x80 + i);
        auto inject = [&](size_t length) {
            NFS2_ASSERT(::sendto(sender, packet.data(), length, 0, reinterpret_cast<::sockaddr*>(&target), sizeof(target)) == ssize_t(length));
        };
        inject(12); // malformed envelope
        packet[19] ^= 1; inject(packet.size()); packet[19] ^= 1; // wrong socket
        packet[8] = 1; inject(packet.size()); packet[8] = 0; // unrelated network
        std::fill(packet.begin() + 8, packet.begin() + 12, 255);
        inject(packet.size()); // all-FF is a wildcard only for broadcast nodes
        std::fill(packet.begin() + 8, packet.begin() + 12, 0);
        wsa::fd_set reads{}; reads.fd_count = 1; reads.fd_array[0] = handle;
        wsa::timeval timeout{0, 20000};
        NFS2_ASSERT(wsa::select(&game, cpu, 0, &reads, nullptr, nullptr, &timeout) == 0 && reads.fd_count == 0);
        inject(packet.size());
        reads.fd_count = 1; reads.fd_array[0] = handle;
        NFS2_ASSERT(wsa::select(&game, cpu, 0, &reads, nullptr, nullptr, &timeout) == 1);
        NFS2_ASSERT(wsa::__WSAFDIsSet(&game, cpu, handle, &reads) == 1);
        uint32_t pending = 0;
        NFS2_ASSERT(wsa::ioctlsocket(&game, cpu, handle, int32_t(0x4004667f), &pending) == 0 && pending == 16);
        wsa::sockaddr source{}; size = 14;
        NFS2_ASSERT(wsa::recvfrom(&game, cpu, handle, buffer, 8, 2, &source, &size) == -1);
        NFS2_ASSERT(wsa::WSAGetLastError(&game, cpu) == 10040);
        NFS2_ASSERT(wsa::recvfrom(&game, cpu, handle, buffer, sizeof(buffer), 0, &source, &size) == 16);
        NFS2_ASSERT(size == 14 && source.sa_family == 6 && memcmp(source.sa_data, packet.data() + 20, 12) == 0);
        NFS2_ASSERT(memcmp(buffer, packet.data() + 32, 16) == 0);
        NFS2_ASSERT(wsa::ioctlsocket(&game, cpu, handle, int32_t(0x4004667f), &pending) == 0 && pending == 0);
        std::fill(packet.begin() + 8, packet.begin() + 18, 255);
        inject(packet.size()); // The exact network/node wildcard used by room searches.
        reads.fd_count = 1; reads.fd_array[0] = handle;
        NFS2_ASSERT(wsa::select(&game, cpu, 0, &reads, nullptr, nullptr, &timeout) == 1);
        NFS2_ASSERT(wsa::recvfrom(&game, cpu, handle, buffer, sizeof(buffer), 0, &source, &size) == 16);
        NFS2_ASSERT(memcmp(buffer, packet.data() + 32, 16) == 0);
        NFS2_ASSERT(memcmp(source.sa_data, packet.data() + 20, 12) == 0);
        wsa::sockaddr broadcast = local;
        memset(broadcast.sa_data + 4, 255, 6);
        NFS2_ASSERT(wsa::sendto(&game, cpu, handle, buffer, 16, 0, &broadcast, 14) == -1);
        NFS2_ASSERT(wsa::WSAGetLastError(&game, cpu) == 10013);
        NFS2_ASSERT(wsa::setsockopt(&game, cpu, handle, 0xffff, 0x20, reinterpret_cast<const char*>(&enabled), 4) == 0);
        NFS2_ASSERT(wsa::sendto(&game, cpu, handle, buffer, 16, 0, &broadcast, 14) == 16);
        ::close(sender);
        NFS2_ASSERT(wsa::closesocket(&game, cpu, handle) == 0);
        NFS2_ASSERT(state->closed && !state->discovery);
        NFS2_ASSERT(wsa::closesocket(&game, cpu, handle) == -1);
        NFS2_ASSERT(wsa::WSACleanup(&game, cpu) == 0 && !win32::Socket::initialized(&game));
        NFS2_ASSERT(wsa::WSACleanup(&game, cpu) == -1);
    }
    BlockingState blocking;
    blockingState = &blocking;
    game.registerMethod(0x400ff1, {"NetworkBlockingReceiveDiagnostic", [](win32::WinApplication* app, x86::CPU& context) {
        uint32_t handle = app->getMemory<uint32_t>(context.esp + 4);
        blockingState->guestThread = win32::kernel32::GetCurrentThreadId(app, context);
        blockingState->nativeThread = win32::Thread::currentThreadId();
        blockingState->waiting = true;
        char buffer[16];
        NFS2_ASSERT(wsa::recvfrom(app, context, handle, buffer, sizeof(buffer), 0, nullptr, nullptr) == -1);
        NFS2_ASSERT(wsa::WSAGetLastError(app, context) == 10038);
        blockingState->finished = true;
        context.esp += 4;
    }});
    NFS2_ASSERT(wsa::WSAStartup(&game, cpu, 0x0101, &data) == 0);
    uint32_t blocked = wsa::socket(&game, cpu, 6, 2, 1000);
    wsa::sockaddr any{}; any.sa_family = 6;
    NFS2_ASSERT(wsa::bind(&game, cpu, blocked, &any, 14) == 0);
    win32::Thread receiver(&game, 0x400ff1, blocked, 4);
    uint32_t receiverID = receiver.threadId();
    receiver.resume();
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (!blocking.waiting && std::chrono::steady_clock::now() < deadline) guest.yield(1);
    NFS2_ASSERT(blocking.waiting && !blocking.finished);
    NFS2_ASSERT(blocking.guestThread == receiverID && blocking.nativeThread == receiverID);
    NFS2_ASSERT(blocking.guestThread != win32::kernel32::GetCurrentThreadId(&game, cpu));
    NFS2_ASSERT(wsa::closesocket(&game, cpu, blocked) == 0);
    while (!blocking.finished && std::chrono::steady_clock::now() < deadline) guest.yield(1);
    NFS2_ASSERT(blocking.finished);
    game.unlockContext(cpu);
    receiver.terminate();
    game.lockContext(cpu);
    blockingState = nullptr;
    NFS2_ASSERT(wsa::WSACleanup(&game, cpu) == 0);
    win32::MemMap pool(2 * 1024 * 1024);
    guest.call(0x4df740);
    guest.call(0x4e1100);
    cpu.eax = pool.getBlockStart(); cpu.edx = pool.getBlockSize();
    guest.call(0x4f9270);
    uint32_t menu = guest.memory.getBlockStart() + 640;
    memset(&game.getMemory<uint8_t>(0x604ee0), 0, 8 * 188);
    memset(&game.getMemory<uint8_t>(menu), 0, 188);
    for (unsigned index = 0; index < 2; ++index)
    {
        uint32_t item = 0x604ee0 + index * 188;
        game.getMemory<uint32_t>(item) = 5;
        game.getMemory<uint32_t>(item + 16) = index ? 0x537900 : 0x5378f8;
    }
    for (unsigned iteration = 0; iteration < 3; ++iteration)
    {
        win32::platform::log("NFS3_CONNECT_DIAGNOSTIC: enter menu iteration=%u", iteration);
        cpu.eax = menu;
        NFS2_ASSERT(guest.call(0x4405c0) == 0);
        NFS2_ASSERT(game.getMemory<uint32_t>(0x55e718) >= 1 && game.getMemory<uint32_t>(0x566e84) == 1);
        NFS2_ASSERT(game.getMemory<uint32_t>(0x9f3650) == 0);
        NFS2_ASSERT((game.getMemory<uint8_t>(0x604ee0 + 4) & 1) != 0);
        NFS2_ASSERT((game.getMemory<uint8_t>(0x604ee0 + 188 + 4) & 1) == 0);
    }
    cpu.eax = 100;
    guest.call(0x48eff0); // Start the real guest clock, including its event and timer workers.
    NFS2_ASSERT(game.getMemory<uint32_t>(0x79c19c) == 100);
    uint32_t pollTicks = game.getMemory<uint32_t>(0x79c1a4);
    for (unsigned iteration = 0; iteration < 100; ++iteration)
        guest.call(0x4a65b0); // The same polling helper used by join / race handshakes.
    NFS2_ASSERT(game.getMemory<uint32_t>(0x79c1a4) > pollTicks);
    win32::platform::log("NFS3_NETWORK_PASS: original connection polling advances the guest clock");
    game.registerMethod(0x400ff4, {"NetworkBarrierDiagnostic", [](win32::WinApplication* app, x86::CPU& context) {
        uint32_t arguments = app->getMemory<uint32_t>(context.esp + 4);
        app->unlockContext(context);
        win32::Thread::sleep(5);
        app->lockContext(context);
        uint32_t destination = app->getMemory<uint32_t>(arguments);
        app->getMemory<uint16_t>(destination) = 5;
        context.esp += 4;
    }});
    uint32_t barrierPeer = guest.memory.getBlockStart() + 16384, barrierArguments = barrierPeer + 128;
    game.getMemory<uint32_t>(0x7a22e0) = 3;
    game.getMemory<uint16_t>(0x7a22dc) = 0;
    game.getMemory<uint16_t>(0x7a2276) = 2;
    game.getMemory<uint32_t>(0x7a21f4) = barrierPeer;
    game.getMemory<uint32_t>(barrierPeer + 36) = 1;
    game.getMemory<uint16_t>(0x7a22cc) = 0;
    for (unsigned host : {0u, 1u})
    {
        uint32_t phase = host ? 0x7a22bc : 0x7a229c;
        game.getMemory<uint16_t>(phase) = 0;
        game.getMemory<uint16_t>(0x7a22da) = host;
        game.getMemory<uint32_t>(barrierArguments) = phase;
        win32::Thread acknowledgement(&game, 0x400ff4, barrierArguments, 4);
        acknowledgement.resume();
        cpu.eax = 1; cpu.edx = 5;
        guest.call(0x4a6a10);
        game.unlockContext(cpu);
        acknowledgement.terminate();
        game.lockContext(cpu);
    }
    game.getMemory<uint32_t>(0x7a22e0) = 0;
    game.getMemory<uint16_t>(0x7a22da) = 0;
    win32::platform::log("NFS3_NETWORK_PASS: original host/client race barriers receive worker acknowledgements");
    game.registerMethod(0x400ff3, {"NetworkSearchProgressDiagnostic", [](win32::WinApplication*, x86::CPU& context) {
        context.eax = 0;
        context.esp += 4;
    }});
    std::mutex watchdogMutex;
    std::condition_variable watchdogCondition;
    bool searchFinished = false;
    std::thread watchdog([&] {
        std::unique_lock<std::mutex> guard(watchdogMutex);
        if (!watchdogCondition.wait_for(guard, std::chrono::seconds(12), [&] { return searchFinished; }))
        {
            win32::platform::log("NFS3_ROOM_SEARCH_DIAGNOSTIC: FAIL original room search blocked the guest clock");
            cpu.terminate = true;
        }
    });
    for (unsigned iteration = 0; iteration < 2; ++iteration)
    {
        win32::platform::log("NFS3_ROOM_SEARCH_DIAGNOSTIC: begin iteration=%u", iteration);
        uint32_t ticks = game.getMemory<uint32_t>(0x79c1a4);
        cpu.eax = 0x180; cpu.ebx = 1; cpu.edx = 0x6fd2fc; cpu.ecx = 0x400ff3;
        NFS2_ASSERT(guest.call(0x49e3d0) == 0x55e858);
        NFS2_ASSERT(game.getMemory<uint16_t>(0x55e858) == 0);
        NFS2_ASSERT(game.getMemory<uint32_t>(0x79c1a4) > ticks);
    }
    cpu.eax = 0x7a0390;
    guest.call(0x4f4e60);
    guest.call(0x48ef50);
    {
        std::lock_guard<std::mutex> guard(watchdogMutex);
        searchFinished = true;
    }
    watchdogCondition.notify_all();
    watchdog.join();
    win32::platform::log("NFS3_ROOM_SEARCH_DIAGNOSTIC: PASS two original IPX room searches return an empty list on timeout while the real guest clock advances; session and clock workers close");
    NFS2_ASSERT(wsa::WSAStartup(&game, cpu, 0x0101, &data) == 0);
    for (unsigned iteration = 0; iteration < 50; ++iteration)
    {
        cpu.eax = iteration % 2 ? 9600 : 0; cpu.edx = 0; cpu.ebx = 0;
        uint32_t transport = guest.call(0x4f5c10);
        NFS2_ASSERT(transport && game.getMemory<uint32_t>(0x9f3650) == 0);
        cpu.eax = transport;
        NFS2_ASSERT(guest.call(0x4f5ea0) == 1);
    }
    NFS2_ASSERT(wsa::WSACleanup(&game, cpu) == 0);
    win32::platform::log("NFS3_CONNECT_DIAGNOSTIC: PASS original Connect Players enters directly and repeatedly, enables IPX, retains unavailable RaceNet, and completes 50 transport open/close cycles");
    win32::platform::log("NFS3_NETWORK_DIAGNOSTIC: PASS Winsock ABI, startup reference counts/restart, high-bit IPX addresses, nonblocking receive, select, FIONREAD, peek/truncation, malformed/wrong-port/network filtering, original lobby broadcast wildcard, original Winsock 1 import bindings, broadcast permission, invalid handles, real guest thread IDs, blocked receive cancellation and cleanup");
}

void networkPeerDiagnosticRun(win32::WinApplication* app, x86::CPU& cpu)
{
    auto& game = *static_cast<nfs3hp::Application*>(app);
    GuestCalls guest(game, cpu);
    guest.call(0x4f1c70); // Networking is normally entered after CPU initialization.
    NFS2_ASSERT(game.getMemory<uint32_t>(0x5643b4) == 1);
    win32::MemMap pool(2 * 1024 * 1024);
    guest.call(0x4df740);
    guest.call(0x4e1100);
    guest.cpu.eax = pool.getBlockStart(); guest.cpu.edx = pool.getBlockSize();
    guest.call(0x4f9270);
    game.getMemory<uint32_t>(0x564480) = guest.call(0x4eb2e0);
    NFS2_ASSERT(guest.call(0x4f5ba0) >= 1600);
    PairState state;
    pairState = &state;
    game.registerMethod(0x400ff8, {"LANPeerDiagnostic", [](win32::WinApplication* app, x86::CPU& cpu) {
        uint32_t record = cpu.edx - 12;
        uint32_t length = app->getMemory<uint32_t>(record + 8);
        uint32_t type = app->getMemory<uint32_t>(record + 0x20);
        NFS2_ASSERT(length == 284);
        auto bytes = &app->getMemory<uint8_t>(record + 0x28);
        NFS2_ASSERT(memcmp(bytes, "NFS3LAN1", 8) == 0);
        uint32_t sequence; memcpy(&sequence, bytes + 8, 4);
        for (unsigned i = 12; i < 280; ++i) NFS2_ASSERT(bytes[i] == uint8_t(i ^ sequence));
        memcpy(pairState->peer.data(), &app->getMemory<uint8_t>(record + 12), 12);
        pairState->found = true;
        if (type == 2) pairState->unicast = true;
        if (type == 3) { NFS2_ASSERT(sequence < 120); pairState->frames.set(sequence); }
        if (type == 4) pairState->complete = true;
        // Consume the original receive queue and return its packet to the free
        // pool, as the game's packet polling does after handling a callback.
        uint32_t transport = cpu.ebx, savedECX = cpu.ecx, savedEDX = cpu.edx;
        cpu.eax = transport + 0x8c;
        cpu.esp -= 4; app->dynamic_call(0x50df60, cpu);
        NFS2_ASSERT(cpu.eax == record);
        cpu.eax = transport + 0x70; cpu.edx = record;
        cpu.esp -= 4; app->dynamic_call(0x50de50, cpu);
        cpu.ecx = savedECX; cpu.edx = savedEDX;
        cpu.esp += 4;
        cpu.eax = 1;
    }});
    for (unsigned session = 0; session < 2; ++session)
    {
        state = {};
        // A nonzero callback context enables the original transport callback.
        guest.cpu.eax = 9600; guest.cpu.edx = 1; guest.cpu.ebx = 0x400ff8;
        uint32_t transport = guest.call(0x4f5c10);
        NFS2_ASSERT(transport && game.getMemory<uint32_t>(0x9f3650) == 0);
        uint32_t payload = guest.memory.getBlockStart() + 1024;
        uint32_t destination = guest.memory.getBlockStart() + 1536;
        auto sendPacket = [&](uint32_t type, uint32_t sequence, bool broadcast) {
            auto bytes = &game.getMemory<uint8_t>(payload);
            memcpy(bytes, "NFS3LAN1", 8); memcpy(bytes + 8, &sequence, 4);
            for (unsigned i = 12; i < 280; ++i) bytes[i] = uint8_t(i ^ sequence);
            NFS2_ASSERT(bytes[0] == 'N');
            memcpy(&game.getMemory<uint8_t>(destination), state.peer.data(), 12);
            if (broadcast && session == 0)
            {
                // Exercise the lobby's explicit all-FF network/node address.
                auto address = &game.getMemory<uint8_t>(destination);
                memset(address, 255, 10);
                address[10] = uint8_t(9600 >> 8); address[11] = uint8_t(9600);
            }
            guest.cpu.eax = transport;
            guest.cpu.edx = broadcast && session != 0 ? 0 : destination;
            guest.cpu.ebx = type; guest.cpu.ecx = payload;
            NFS2_ASSERT(guest.call(0x4f60b0, {280}) == 1);
            NFS2_ASSERT(bytes[0] == 'N');
        };
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
        while (!state.found && std::chrono::steady_clock::now() < deadline) { sendPacket(1, 0, true); guest.yield(100); }
        NFS2_ASSERT(state.found);
        for (unsigned sequence = 0; sequence < 120; ++sequence)
        {
            sendPacket(2, 0, false);
            sendPacket(3, sequence, false);
            guest.yield(10);
        }
        deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
        while ((!state.frames.all() || !state.unicast || !state.complete) && std::chrono::steady_clock::now() < deadline)
        {
            // Repeat the burst to tolerate UDP loss, recording unique frame sequence numbers.
            for (unsigned sequence = 0; sequence < 120; ++sequence) sendPacket(3, sequence, false);
            if (state.frames.all() && state.unicast) sendPacket(4, 0, false);
            guest.yield(100);
        }
        if (!state.frames.all() || !state.unicast || !state.complete)
            win32::platform::log("NFS3_LAN_PEER_DIAGNOSTIC: FAIL frames=%zu unicast=%d complete=%d peerport=%02x%02x", state.frames.count(), int(state.unicast), int(state.complete), state.peer[10], state.peer[11]);
        NFS2_ASSERT(state.frames.all() && state.unicast && state.complete);
        for (unsigned ack = 0; ack < 5; ++ack) { sendPacket(4, 0, false); guest.yield(100); }
        guest.cpu.eax = transport;
        NFS2_ASSERT(guest.call(0x4f5ea0) == 1);
        win32::platform::log("NFS3_LAN_PEER_DIAGNOSTIC: session=%u PASS Bonjour discovery, original IPX broadcast/unicast, 120 unique 280-byte payloads each direction, receive worker close/reopen", session + 1);
        guest.yield(1000);
    }
    NFS2_ASSERT(guest.call(0x4f5bf0) == 1);
    pairState = nullptr;
    win32::platform::log("NFS3_LAN_PEER_DIAGNOSTIC: PASS two original transport sessions and full Winsock cleanup");
}
void networkDiagnostic(const char* directory)
{
    win32::File::setDataDirectory(directory);
    win32::File::setCdDirectory(directory);
    {
        nfs3hp::Application game("nfs3.exe");
        game.registerMethod(0x400ff0, {"NetworkDiagnostic", &networkDiagnosticRun});
        x86::CPU cpu{};
        game.runThread(cpu, 0x400ff0);
    }
    stopLANAccess();
}
void networkPeerDiagnostic()
{
    {
        nfs3hp::Application game("nfs3.exe");
        game.registerMethod(0x400ff0, {"NetworkPeerDiagnostic", &networkPeerDiagnosticRun});
        x86::CPU cpu{};
        game.runThread(cpu, 0x400ff0);
    }
    stopLANAccess();
}
}
