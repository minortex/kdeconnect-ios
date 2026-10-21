//
//  KDECService.m
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import "KDECService.h"
#import "KDECCertificateManager.h"
#import "KDECDeviceInfo.h"
#import "KDECTransport.h"
#import "KDEConnectPacket.h"

#import "GCDAsyncSocket.h"
#import "GCDAsyncUdpSocket.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>

NSString *const KDECServiceDevicesDidChangeNotification = @"KDECServiceDevicesDidChangeNotification";
NSString *const KDECServicePairRequestNotification = @"KDECServicePairRequestNotification";
NSString *const KDECServiceFileReceivedNotification = @"KDECServiceFileReceivedNotification";

static const uint16_t KDECDiscoveryPort = 1716;
static const uint16_t KDECMinTcpPort = 1716;
static const uint16_t KDECMaxTcpPort = 1764;
static const NSInteger KDECProtocolVersion = 8;

@interface KDECService () <KDECTransportDelegate, GCDAsyncSocketDelegate, GCDAsyncUdpSocketDelegate>
@property (nonatomic, strong) NSMutableDictionary<NSString *, KDECDeviceInfo *> *deviceMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, KDECTransport *> *transportMap;
@property (nonatomic, strong) GCDAsyncUdpSocket *udpSocket;
@property (nonatomic, strong) GCDAsyncSocket *serverSocket;
@property (nonatomic, assign) uint16_t tcpPort;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, strong) NSMutableDictionary<NSValue *, GCDAsyncSocket *> *incomingSockets;
@property (nonatomic, copy) NSString *pendingPairDeviceId;
@property (nonatomic, copy) NSString *lastClipboardContent;
@property (nonatomic, assign) NSInteger lastClipboardTimestamp;
@property (nonatomic, assign) BOOL clipboardMonitoring;
@property (nonatomic, assign) BOOL applyingRemoteClipboard;
@end

@implementation KDECService

+ (instancetype)shared
{
    static KDECService *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[KDECService alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _deviceMap = [NSMutableDictionary dictionary];
        _transportMap = [NSMutableDictionary dictionary];
        _incomingSockets = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSArray<KDECDeviceInfo *> *)devices
{
    return [self.deviceMap.allValues sortedArrayUsingComparator:^NSComparisonResult(KDECDeviceInfo *a, KDECDeviceInfo *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}

- (void)start
{
    if (![KDECCertificateManager shared].hostIdentity) {
        return;
    }
    if (self.started) {
        [self refresh];
        return;
    }
    self.started = YES;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIPasteboardChangedNotification
                                                  object:nil];
    [self loadPairedDevices];
    [self startServer];
    if (!self.serverSocket) {
        NSLog(@"KDEC TCP server failed");
        self.started = NO;
        return;
    }
    [self startUdp];
    if (!self.udpSocket) {
        NSLog(@"KDEC UDP socket failed");
        [self.serverSocket disconnect];
        self.serverSocket = nil;
        self.started = NO;
        return;
    }
    [self broadcastIdentity];
    [self startClipboardMonitoring];
}

- (void)stop
{
    self.started = NO;
    self.pendingPairDeviceId = nil;
    self.clipboardMonitoring = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIPasteboardChangedNotification
                                                  object:nil];
    [self.udpSocket close];
    self.udpSocket = nil;
    self.serverSocket.delegate = nil;
    [self.serverSocket disconnect];
    self.serverSocket = nil;
    for (KDECTransport *transport in self.transportMap.allValues) {
        [transport disconnect];
    }
    [self.transportMap removeAllObjects];
    [self.incomingSockets removeAllObjects];
    for (KDECDeviceInfo *device in self.deviceMap.allValues) {
        device.reachable = NO;
    }
    [self notifyChanged];
}

- (void)refresh
{
    if (!self.started) {
        [self start];
        return;
    }
    [self broadcastIdentity];
    for (KDECDeviceInfo *device in self.deviceMap.allValues) {
        if (device.paired && !device.reachable && device.host.length > 0) {
            [self connectToDevice:device host:device.host port:device.tcpPort];
        }
    }
}

- (void)startServer
{
    self.serverSocket = [[GCDAsyncSocket alloc] initWithDelegate:self
                                                   delegateQueue:dispatch_get_main_queue()];
    NSError *error = nil;
    for (uint16_t port = KDECMinTcpPort; port <= KDECMaxTcpPort; port++) {
        if ([self.serverSocket acceptOnPort:port error:&error]) {
            self.tcpPort = port;
            NSLog(@"KDEC TCP listening on %u", port);
            return;
        }
    }
    self.serverSocket = nil;
}

- (void)startUdp
{
    self.udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self
                                                   delegateQueue:dispatch_get_main_queue()];
    NSError *error = nil;
    [self.udpSocket enableReusePort:YES error:&error];
    [self.udpSocket enableBroadcast:YES error:&error];
    if (![self.udpSocket bindToPort:KDECDiscoveryPort error:&error]) {
        NSLog(@"KDEC UDP bind failed: %@", error);
        self.udpSocket = nil;
        return;
    }
    if (![self.udpSocket beginReceiving:&error]) {
        NSLog(@"KDEC UDP receive failed: %@", error);
        [self.udpSocket close];
        self.udpSocket = nil;
        return;
    }
    NSLog(@"KDEC UDP listening on %d", KDECDiscoveryPort);
}

- (KDEConnectPacket *)identityPacket
{
    KDECCertificateManager *certificates = [KDECCertificateManager shared];
    KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithType:KDECPacketTypeIdentity];
    [packet setObject:certificates.deviceId forKey:@"deviceId"];
    [packet setObject:certificates.deviceName forKey:@"deviceName"];
    [packet setObject:@"phone" forKey:@"deviceType"];
    [packet setInteger:KDECProtocolVersion forKey:@"protocolVersion"];
    [packet setInteger:self.tcpPort forKey:@"tcpPort"];
    [packet setObject:@[KDECPacketTypeShare, KDECPacketTypeClipboard,
                        KDECPacketTypeClipboardConnect] forKey:@"incomingCapabilities"];
    [packet setObject:@[KDECPacketTypeShare, KDECPacketTypeClipboard,
                        KDECPacketTypeClipboardConnect] forKey:@"outgoingCapabilities"];
    return packet;
}

- (void)broadcastIdentity
{
    if (!self.udpSocket) {
        return;
    }
    NSData *data = [[self identityPacket] serialize];
    NSArray<NSString *> *addresses = [self broadcastAddresses];
    for (NSString *address in addresses) {
        NSLog(@"KDEC broadcasting to %@:%d", address, KDECDiscoveryPort);
        [self.udpSocket sendData:data
                          toHost:address
                            port:KDECDiscoveryPort
                     withTimeout:-1
                             tag:0];
    }
}

- (NSArray<NSString *> *)broadcastAddresses
{
    NSMutableArray<NSString *> *addresses = [NSMutableArray arrayWithObject:@"255.255.255.255"];
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) {
        return addresses;
    }
    for (struct ifaddrs *item = interfaces; item != NULL; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        if (!(item->ifa_flags & IFF_UP) || !(item->ifa_flags & IFF_BROADCAST)) {
            continue;
        }
        struct sockaddr_in *broadcast = (struct sockaddr_in *)item->ifa_broadaddr;
        if (!broadcast) {
            continue;
        }
        char text[INET_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET, &broadcast->sin_addr, text, sizeof(text))) {
            [addresses addObject:[NSString stringWithUTF8String:text]];
        }
    }
    freeifaddrs(interfaces);
    return addresses;
}

- (void)connectToDevice:(KDECDeviceInfo *)device host:(NSString *)host port:(uint16_t)port
{
    KDECTransport *transport = self.transportMap[device.deviceId];
    if (!transport) {
        transport = [[KDECTransport alloc] initWithDevice:device];
        transport.delegate = self;
        self.transportMap[device.deviceId] = transport;
    }
    [transport connectToHost:host port:port];
}

- (void)pairDevice:(KDECDeviceInfo *)device
{
    KDECTransport *transport = self.transportMap[device.deviceId];
    if (!transport) {
        return;
    }
    KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithType:KDECPacketTypePair];
    [packet setBool:YES forKey:@"pair"];
    [packet setInteger:(NSInteger)[NSDate date].timeIntervalSince1970 forKey:@"timestamp"];
    if (![transport sendPacket:packet]) {
        return;
    }
    self.pendingPairDeviceId = device.deviceId;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self.pendingPairDeviceId isEqualToString:device.deviceId]) {
            self.pendingPairDeviceId = nil;
        }
    });
}

- (void)acceptPairingForDevice:(KDECDeviceInfo *)device
{
    KDECTransport *transport = self.transportMap[device.deviceId];
    if (!transport) {
        return;
    }
    SecCertificateRef certificate = [transport copyPeerCertificate];
    if (!certificate ||
        ![[KDECCertificateManager shared] savePairedCertificate:certificate
                                                    forDeviceId:device.deviceId]) {
        if (certificate) {
            CFRelease(certificate);
        }
        return;
    }
    CFRelease(certificate);
    device.paired = YES;
    KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithType:KDECPacketTypePair];
    [packet setBool:YES forKey:@"pair"];
    [packet setInteger:(NSInteger)[NSDate date].timeIntervalSince1970 forKey:@"timestamp"];
    if (![transport sendPacket:packet]) {
        return;
    }
    [self savePairedDevices];
    [self notifyChanged];
    [self sendClipboardConnectToDevice:device];
}

- (void)completePairingForDevice:(KDECDeviceInfo *)device
{
    KDECTransport *transport = self.transportMap[device.deviceId];
    if (!transport) {
        return;
    }
    SecCertificateRef certificate = [transport copyPeerCertificate];
    if (!certificate ||
        ![[KDECCertificateManager shared] savePairedCertificate:certificate
                                                    forDeviceId:device.deviceId]) {
        if (certificate) {
            CFRelease(certificate);
        }
        return;
    }
    CFRelease(certificate);
    device.paired = YES;
    [self savePairedDevices];
    [self notifyChanged];
    [self sendClipboardConnectToDevice:device];
}

- (void)rejectPairingForDevice:(KDECDeviceInfo *)device
{
    KDECTransport *transport = self.transportMap[device.deviceId];
    if (!transport) {
        return;
    }
    KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithType:KDECPacketTypePair];
    [packet setBool:NO forKey:@"pair"];
    [transport sendPacket:packet];
    [transport disconnect];
    [self.transportMap removeObjectForKey:device.deviceId];
    self.pendingPairDeviceId = nil;
}

- (void)unpairDevice:(KDECDeviceInfo *)device
{
    KDECTransport *transport = self.transportMap[device.deviceId];
    KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithType:KDECPacketTypePair];
    [packet setBool:NO forKey:@"pair"];
    if (transport) {
        [transport sendPacket:packet];
        [transport disconnect];
    }
    [self.transportMap removeObjectForKey:device.deviceId];
    device.paired = NO;
    [[KDECCertificateManager shared] deletePairedCertificateForDeviceId:device.deviceId];
    [self savePairedDevices];
    [self notifyChanged];
}

- (void)sendClipboardToDevice:(KDECDeviceInfo *)device
{
    KDECTransport *transport = self.transportMap[device.deviceId];
    NSString *text = [UIPasteboard generalPasteboard].string;
    if (!transport || text.length == 0) {
        return;
    }
    KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithType:KDECPacketTypeClipboard];
    [packet setObject:text forKey:@"content"];
    [packet setInteger:(NSInteger)([NSDate date].timeIntervalSince1970 * 1000)
                forKey:@"timestamp"];
    self.lastClipboardContent = text;
    self.lastClipboardTimestamp = [packet integerForKey:@"timestamp"];
    [transport sendPacket:packet];
}

- (void)startClipboardMonitoring
{
    if (self.clipboardMonitoring) {
        return;
    }
    self.clipboardMonitoring = YES;
    self.lastClipboardContent = [UIPasteboard generalPasteboard].string;
    self.lastClipboardTimestamp = (NSInteger)([NSDate date].timeIntervalSince1970 * 1000);
    for (KDECDeviceInfo *device in self.deviceMap.allValues) {
        if (device.paired && device.reachable) {
            [self sendClipboardConnectToDevice:device];
        }
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(clipboardChanged:)
                                                 name:UIPasteboardChangedNotification
                                               object:nil];
}

- (void)clipboardChanged:(NSNotification *)notification
{
    if (self.applyingRemoteClipboard) {
        return;
    }
    NSString *content = [UIPasteboard generalPasteboard].string;
    if (content.length == 0 || [content isEqualToString:self.lastClipboardContent]) {
        return;
    }
    self.lastClipboardContent = content;
    self.lastClipboardTimestamp = (NSInteger)([NSDate date].timeIntervalSince1970 * 1000);
    for (KDECDeviceInfo *device in self.deviceMap.allValues) {
        if (device.paired && device.reachable) {
            KDECTransport *transport = self.transportMap[device.deviceId];
            KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithType:KDECPacketTypeClipboard];
            [packet setObject:content forKey:@"content"];
            [packet setInteger:self.lastClipboardTimestamp forKey:@"timestamp"];
            if (![transport sendPacket:packet]) {
                continue;
            }
        }
    }
}

- (void)sendClipboardConnectToDevice:(KDECDeviceInfo *)device
{
    KDECTransport *transport = self.transportMap[device.deviceId];
    NSString *content = [UIPasteboard generalPasteboard].string;
    if (!transport || content.length == 0) {
        return;
    }
    KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithType:KDECPacketTypeClipboardConnect];
    [packet setObject:content forKey:@"content"];
    [packet setInteger:(NSInteger)([NSDate date].timeIntervalSince1970 * 1000)
                forKey:@"timestamp"];
    [transport sendPacket:packet];
}

- (BOOL)sendFileAtPath:(NSString *)path toDevice:(KDECDeviceInfo *)device
{
    KDECTransport *transport = self.transportMap[device.deviceId];
    if (!transport) {
        return NO;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return NO;
    }
    NSString *filename = path.lastPathComponent;
    NSString *uuid = [[NSUUID UUID] UUIDString];
    if (!uuid) {
        uuid = [NSString stringWithFormat:@"%ld", (long)[NSDate date].timeIntervalSince1970];
    }
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:uuid];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *copyPath = [directory stringByAppendingPathComponent:filename];
    if (![data writeToFile:copyPath atomically:YES]) {
        return NO;
    }
    return [transport sendFileAtPath:copyPath filename:filename];
}

#pragma mark - Transport delegate

- (void)transport:(KDECTransport *)transport didReceivePacket:(KDEConnectPacket *)packet
{
    KDECDeviceInfo *device = [self deviceForTransport:transport];
    if (!device) {
        return;
    }
    if (!device.paired &&
        ![packet.type isEqualToString:KDECPacketTypePair]) {
        return;
    }
    if ([packet.type isEqualToString:KDECPacketTypePair]) {
        BOOL pair = [packet boolForKey:@"pair"];
        if (pair) {
            if ([self.pendingPairDeviceId isEqualToString:device.deviceId]) {
                self.pendingPairDeviceId = nil;
                [self completePairingForDevice:device];
                [self sendClipboardToDevice:device];
                return;
            }
            if (device.paired) {
                return;
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:KDECServicePairRequestNotification
                                                                object:device];
        } else if (!device.paired) {
            return;
        } else {
            device.paired = NO;
            [self savePairedDevices];
            [self notifyChanged];
        }
        return;
    }
    if ([packet.type isEqualToString:KDECPacketTypeClipboard] ||
        [packet.type isEqualToString:KDECPacketTypeClipboardConnect]) {
        NSString *content = [packet stringForKey:@"content"];
        NSInteger timestamp = [packet integerForKey:@"timestamp"];
        if (content &&
            (timestamp == 0 || timestamp >= self.lastClipboardTimestamp)) {
            self.lastClipboardTimestamp = timestamp;
            self.lastClipboardContent = content;
            self.applyingRemoteClipboard = YES;
            [UIPasteboard generalPasteboard].string = content;
            self.applyingRemoteClipboard = NO;
        }
        return;
    }
    if ([packet.type isEqualToString:KDECPacketTypeShare]) {
        if (packet.payload) {
            NSString *filename = [packet stringForKey:@"filename"] ?: @"received-file";
            filename = filename.lastPathComponent;
            NSString *directory = [self receivedFilesDirectory];
            NSString *path = [directory stringByAppendingPathComponent:filename];
            NSInteger suffix = 2;
            while ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                NSString *base = filename.stringByDeletingPathExtension;
                NSString *extension = filename.pathExtension;
                NSString *candidate = extension.length > 0
                    ? [NSString stringWithFormat:@"%@-%ld.%@", base, (long)suffix, extension]
                    : [NSString stringWithFormat:@"%@-%ld", base, (long)suffix];
                path = [directory stringByAppendingPathComponent:candidate];
                suffix++;
            }
            [packet.payload writeToFile:path atomically:YES];
            [[NSNotificationCenter defaultCenter] postNotificationName:KDECServiceFileReceivedNotification
                                                                object:device
                                                              userInfo:@{@"path": path}];
        }
    }
}

- (NSString *)receivedFilesDirectory
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                              NSUserDomainMask, YES).firstObject;
    NSString *directory = [documents stringByAppendingPathComponent:@"Received"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return directory;
}

- (void)notifyChanged
{
    [[NSNotificationCenter defaultCenter] postNotificationName:KDECServiceDevicesDidChangeNotification
                                                        object:self];
}

- (void)savePairedDevices
{
    NSMutableArray *items = [NSMutableArray array];
    for (KDECDeviceInfo *device in self.deviceMap.allValues) {
        if (device.paired) {
            [items addObject:[device dictionaryRepresentation]];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:items forKey:@"KDECPairedDevices"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)loadPairedDevices
{
    NSArray *items = [[NSUserDefaults standardUserDefaults] arrayForKey:@"KDECPairedDevices"];
    for (NSDictionary *item in items) {
        KDECDeviceInfo *device = [KDECDeviceInfo deviceFromDictionary:item];
        if (device) {
            device.paired = [[KDECCertificateManager shared] isDevicePaired:device.deviceId];
            self.deviceMap[device.deviceId] = device;
        }
    }
}

- (KDECDeviceInfo *)deviceForTransport:(KDECTransport *)transport
{
    for (KDECDeviceInfo *device in self.deviceMap.allValues) {
        if (self.transportMap[device.deviceId] == transport) {
            return device;
        }
    }
    return nil;
}

- (void)transport:(KDECTransport *)transport didChangeReachability:(BOOL)reachable
{
    KDECDeviceInfo *device = [self deviceForTransport:transport];
    if (!device) {
        return;
    }
    device.reachable = reachable;
    [self notifyChanged];
}

- (void)transport:(KDECTransport *)transport didCompleteHandshakeWithDeviceId:(NSString *)deviceId
{
    KDECDeviceInfo *device = self.deviceMap[deviceId];
    if (!device) {
        return;
    }
    if (!device.paired) {
        return;
    }
    [self savePairedDevices];
    [self sendClipboardConnectToDevice:device];
    [self notifyChanged];
}

#pragma mark - Socket delegates

- (void)udpSocket:(GCDAsyncUdpSocket *)sock
   didReceiveData:(NSData *)data
      fromAddress:(NSData *)address
withFilterContext:(id)filterContext
{
    KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithData:data];
    if (![packet.type isEqualToString:KDECPacketTypeIdentity]) {
        return;
    }
    NSString *deviceId = [packet stringForKey:@"deviceId"];
    if (deviceId.length == 0 ||
        [deviceId isEqualToString:[KDECCertificateManager shared].deviceId]) {
        return;
    }
    if ([packet integerForKey:@"protocolVersion"] < KDECProtocolVersion) {
        return;
    }
    NSLog(@"KDEC received discovery from %@", [packet stringForKey:@"deviceName"]);

    NSString *host = nil;
    [GCDAsyncUdpSocket getHost:&host port:nil fromAddress:address];
    if (host.length == 0) {
        return;
    }

    KDECDeviceInfo *device = self.deviceMap[deviceId];
    if (!device) {
        device = [[KDECDeviceInfo alloc] initWithIdentityPacket:packet];
        device.paired = [[KDECCertificateManager shared] isDevicePaired:deviceId];
        self.deviceMap[deviceId] = device;
    } else {
        [device updateWithIdentityPacket:packet];
    }
    device.host = host;
    uint16_t port = (uint16_t)[packet integerForKey:@"tcpPort"];
    device.tcpPort = port;
    NSLog(@"KDEC discovery host=%@ port=%u", host, port);
    if (port >= KDECMinTcpPort && port <= KDECMaxTcpPort) {
        if (device.paired) {
            [self savePairedDevices];
        }
        [self connectToDevice:device host:host port:port];
    }
    [self notifyChanged];
}

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket
{
    self.incomingSockets[[NSValue valueWithNonretainedObject:newSocket]] = newSocket;
    [newSocket readDataToData:[GCDAsyncSocket LFData]
                  withTimeout:-1
                    maxLength:8192
                        tag:1];
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
    NSValue *key = [NSValue valueWithNonretainedObject:sock];
    if (!self.incomingSockets[key]) {
        return;
    }
    KDEConnectPacket *identity = [[KDEConnectPacket alloc] initWithData:data];
    if (![identity.type isEqualToString:KDECPacketTypeIdentity]) {
        [sock disconnect];
        [self.incomingSockets removeObjectForKey:key];
        return;
    }
    NSString *deviceId = [identity stringForKey:@"deviceId"];
    if (deviceId.length == 0) {
        [sock disconnect];
        [self.incomingSockets removeObjectForKey:key];
        return;
    }
    [self.incomingSockets removeObjectForKey:key];

    KDECDeviceInfo *device = self.deviceMap[deviceId];
    if (!device) {
        device = [[KDECDeviceInfo alloc] initWithIdentityPacket:identity];
        device.paired = [[KDECCertificateManager shared] isDevicePaired:deviceId];
        self.deviceMap[deviceId] = device;
    }
    device.host = sock.connectedHost;
    if (device.paired) {
        [self savePairedDevices];
    }
    KDECTransport *transport = [[KDECTransport alloc] initWithDevice:device];
    transport.delegate = self;
    self.transportMap[deviceId] = transport;
    [transport acceptSocket:sock];
    [self notifyChanged];
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
    [self.incomingSockets removeObjectForKey:[NSValue valueWithNonretainedObject:sock]];
}

@end
