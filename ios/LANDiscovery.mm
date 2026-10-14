#import <Foundation/Foundation.h>
#include "LANDiscovery.h"
#include <lib/platform.h>
#include <arpa/inet.h>
#include <atomic>
#include <map>
#include <mutex>
#include <string>

namespace
{
NSString* const serviceType = @"_nfs3-lan._udp.";
struct DiscoveryState
{
    std::mutex mutex;
    std::map<std::string, std::vector<nfsios::LANPeer>> peers;
    std::atomic<bool> stopped{false};
    nfsios::IPXAddress address{};
};
NSString* serviceKey(NSNetService* service)
{
    return [NSString stringWithFormat:@"%@|%@|%@", service.domain, service.type, service.name];
}
}
@interface NFSLANAccess : NSObject <NSNetServiceBrowserDelegate>
@property(nonatomic, strong) NSNetServiceBrowser* browser;
- (void)start;
- (void)stop;
@end

@implementation NFSLANAccess
- (void)start
{
    if (self.browser) return;
    self.browser = [NSNetServiceBrowser new];
    self.browser.delegate = self;
    [self.browser searchForServicesOfType:serviceType inDomain:@"local."];
    win32::platform::log("NFS3_LAN: Local Network access browse requested; retained until game exit");
}
- (void)stop
{
    self.browser.delegate = nil;
    [self.browser stop];
    self.browser = nil;
}
- (void)netServiceBrowserWillSearch:(NSNetServiceBrowser*)browser
{
    win32::platform::log("NFS3_LAN: Local Network access browse started");
}
- (void)netServiceBrowser:(NSNetServiceBrowser*)browser didNotSearch:(NSDictionary<NSString*, NSNumber*>*)error
{
    win32::platform::log("NFS3_LAN: Local Network access browse failed code=%ld", (long)[error[NSNetServicesErrorCode] integerValue]);
    // A later user-initiated IPX connection can retry after a Settings change.
    [self stop];
}
@end

namespace
{
// Accessed only on the main queue. A transient protocol-probe socket must not
// cancel the operation that causes iOS to show its Local Network permission.
NFSLANAccess* accessBrowse;
void startLANAccess()
{
    if (!accessBrowse) accessBrowse = [NFSLANAccess new];
    [accessBrowse start];
}
}

@interface NFSLANDiscovery : NSObject <NSNetServiceDelegate, NSNetServiceBrowserDelegate>
{
@public
    std::shared_ptr<DiscoveryState> state;
}
@property(nonatomic, strong) NSNetService* publication;
@property(nonatomic, strong) NSNetServiceBrowser* browser;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSNetService*>* services;
- (void)start:(uint16_t)port;
- (void)stop;
@end

@implementation NFSLANDiscovery
- (void)start:(uint16_t)port
{
    if (state->stopped) return;
    self.services = [NSMutableDictionary new];
    NSData* address = [NSData dataWithBytes:state->address.data() length:state->address.size()];
    self.publication = [[NSNetService alloc] initWithDomain:@"local." type:serviceType
        name:[@"NFS3-" stringByAppendingString:NSUUID.UUID.UUIDString] port:port];
    self.publication.delegate = self;
    [self.publication setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:@{
        @"version": [@"1" dataUsingEncoding:NSUTF8StringEncoding], @"ipx": address }]];
    [self.publication publish];
    self.browser = [NSNetServiceBrowser new];
    self.browser.delegate = self;
    [self.browser searchForServicesOfType:serviceType inDomain:@"local."];
    win32::platform::log("NFS3_LAN: IPX service discovery requested; UDP port=%u", port);
}
- (void)stop
{
    state->stopped = true;
    self.browser.delegate = nil;
    [self.browser stop];
    self.publication.delegate = nil;
    [self.publication stop];
    for (NSNetService* service in self.services.allValues)
    {
        service.delegate = nil;
        [service stop];
    }
    [self.services removeAllObjects];
    std::lock_guard<std::mutex> guard(state->mutex);
    state->peers.clear();
}
- (void)netServiceDidPublish:(NSNetService*)service
{
    win32::platform::log("NFS3_LAN: IPX service published; UDP port=%ld", (long)service.port);
}
- (void)netServiceBrowserWillSearch:(NSNetServiceBrowser*)browser
{
    win32::platform::log("NFS3_LAN: IPX peer browse started");
}
- (void)netServiceBrowser:(NSNetServiceBrowser*)browser didFindService:(NSNetService*)service moreComing:(BOOL)more
{
    if (state->stopped || [service.name isEqualToString:self.publication.name]) return;
    self.services[serviceKey(service)] = service;
    service.delegate = self;
    [service resolveWithTimeout:10];
}
- (void)netServiceBrowser:(NSNetServiceBrowser*)browser didRemoveService:(NSNetService*)service moreComing:(BOOL)more
{
    NSString* key = serviceKey(service);
    NSNetService* existing = self.services[key];
    existing.delegate = nil;
    [existing stop];
    [self.services removeObjectForKey:key];
    std::lock_guard<std::mutex> guard(state->mutex);
    state->peers.erase(key.UTF8String);
}
- (void)netServiceDidResolveAddress:(NSNetService*)service
{
    if (state->stopped || self.services[serviceKey(service)] != service) return;
    NSDictionary* txt = [NSNetService dictionaryFromTXTRecordData:service.TXTRecordData ?: [NSData data]];
    NSData* ipx = txt[@"ipx"];
    if (![txt[@"version"] isEqualToData:[@"1" dataUsingEncoding:NSUTF8StringEncoding]] || ipx.length != 12) return;
    nfsios::IPXAddress address;
    memcpy(address.data(), ipx.bytes, address.size());
    if (memcmp(address.data() + 4, state->address.data() + 4, 6) == 0) return;
    std::vector<nfsios::LANPeer> peers;
    for (NSData* data in service.addresses)
    {
        if (data.length < sizeof(sockaddr_in)) continue;
        const auto* endpoint = static_cast<const sockaddr_in*>(data.bytes);
        if (endpoint->sin_family != AF_INET || !endpoint->sin_port) continue;
        peers.push_back({address, endpoint->sin_addr.s_addr, endpoint->sin_port});
        // One endpoint per service avoids duplicate datagrams on multihomed devices.
        break;
    }
    if (peers.empty()) return;
    std::lock_guard<std::mutex> guard(state->mutex);
    state->peers[serviceKey(service).UTF8String] = peers;
    char host[INET_ADDRSTRLEN]{};
    inet_ntop(AF_INET, &peers.front().ipv4, host, sizeof(host));
    win32::platform::log("NFS3_LAN: peer resolved; guest port=%u UDP=%s:%u",
        (address[10] << 8) | address[11], host, ntohs(peers.front().udpPort));
}
- (void)netService:(NSNetService*)service didNotResolve:(NSDictionary<NSString*, NSNumber*>*)error
{
    win32::platform::log("NFS3_LAN: resolve failed code=%ld", (long)[error[NSNetServicesErrorCode] integerValue]);
}
- (void)netService:(NSNetService*)service didNotPublish:(NSDictionary<NSString*, NSNumber*>*)error
{
    win32::platform::log("NFS3_LAN: publish failed code=%ld; check Local Network permission", (long)[error[NSNetServicesErrorCode] integerValue]);
}
- (void)netServiceBrowser:(NSNetServiceBrowser*)browser didNotSearch:(NSDictionary<NSString*, NSNumber*>*)error
{
    win32::platform::log("NFS3_LAN: browse failed code=%ld; check Local Network permission", (long)[error[NSNetServicesErrorCode] integerValue]);
}
@end

namespace nfsios
{
void stopLANAccess()
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!accessBrowse) return;
        [accessBrowse stop];
        accessBrowse = nil;
        win32::platform::log("NFS3_LAN: Local Network access browse stopped at game exit");
    });
}
struct LANDiscovery::Impl
{
    std::shared_ptr<DiscoveryState> state = std::make_shared<DiscoveryState>();
    NFSLANDiscovery* __strong discovery;
};
LANDiscovery::LANDiscovery(const IPXAddress& address, uint16_t udpPort) : m_impl(std::make_shared<Impl>())
{
    m_impl->state->address = address;
    auto impl = m_impl;
    dispatch_async(dispatch_get_main_queue(), ^{
        startLANAccess();
        if (impl->state->stopped) return;
        impl->discovery = [NFSLANDiscovery new];
        impl->discovery->state = impl->state;
        [impl->discovery start:udpPort];
    });
}
LANDiscovery::~LANDiscovery()
{
    auto impl = m_impl;
    impl->state->stopped = true;
    dispatch_async(dispatch_get_main_queue(), ^{ [impl->discovery stop]; impl->discovery = nil; });
}
std::vector<LANPeer> LANDiscovery::peers() const
{
    std::lock_guard<std::mutex> guard(m_impl->state->mutex);
    std::vector<LANPeer> result;
    for (const auto& service : m_impl->state->peers)
        result.insert(result.end(), service.second.begin(), service.second.end());
    return result;
}
}
