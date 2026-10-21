//
//  KDECTransport.m
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import "KDECTransport.h"
#import "KDECCertificateManager.h"
#import "KDECDeviceInfo.h"
#import "KDEConnectPacket.h"
#import "KDECPayloadConnection.h"

#import "GCDAsyncSocket.h"

static const long KDECTransportTagPacket = 1;
static const uint16_t KDECPayloadPort = 1739;
static const NSUInteger KDECMaxPacketSize = 32 * 1024 * 1024;

@interface KDECTransport () <GCDAsyncSocketDelegate>
@property (nonatomic, strong) KDECDeviceInfo *device;
@property (nonatomic, strong) GCDAsyncSocket *socket;
@property (nonatomic, strong) GCDAsyncSocket *payloadServer;
@property (nonatomic, strong) NSMutableData *readBuffer;
@property (nonatomic, strong) NSData *pendingPayload;
@property (nonatomic, strong) NSString *pendingFilename;
@property (nonatomic, strong) GCDAsyncSocket *pendingPayloadSocket;
@property (nonatomic, assign) uint16_t payloadPort;
@property (nonatomic, assign) BOOL reachable;
@property (nonatomic, strong) NSMutableArray<KDECPayloadConnection *> *payloadConnections;
@property (nonatomic, assign) SecCertificateRef peerCertificate;
@property (nonatomic, assign) BOOL handshakeComplete;
@end

@implementation KDECTransport

- (instancetype)initWithDevice:(KDECDeviceInfo *)device
{
    self = [super init];
    if (self) {
        _device = device;
        _readBuffer = [NSMutableData data];
        _payloadPort = KDECPayloadPort;
        _payloadConnections = [NSMutableArray array];
    }
    return self;
}

- (void)connectToHost:(NSString *)host port:(uint16_t)port
{
    [self disconnect];
    self.device.host = host;
    self.device.tcpPort = port;
    self.handshakeComplete = NO;
    self.socket = [[GCDAsyncSocket alloc] initWithDelegate:self
                                             delegateQueue:dispatch_get_main_queue()];
    NSError *error = nil;
    if (![self.socket connectToHost:host onPort:port error:&error]) {
        [self setReachable:NO];
    }
}

- (void)acceptSocket:(GCDAsyncSocket *)socket
{
    [self disconnect];
    self.handshakeComplete = NO;
    self.socket = socket;
    self.socket.delegate = self;
    NSDictionary *settings = @{
        (id)GCDAsyncSocketSSLIsServer: @NO,
        (id)GCDAsyncSocketSSLCertificates: @[(__bridge id)[KDECCertificateManager shared].hostIdentity],
        (id)GCDAsyncSocketSSLPeerName: self.device.deviceId,
        (id)GCDAsyncSocketManuallyEvaluateTrust: @YES,
    };
    [self.socket startTLS:settings];
}

- (BOOL)sendPacket:(KDEConnectPacket *)packet
{
    if (!self.socket.isConnected) {
        return NO;
    }
    NSData *data = [packet serialize];
    if (!data) {
        return NO;
    }
    if (!self.handshakeComplete &&
        ![packet.type isEqualToString:KDECPacketTypeIdentity]) {
        return NO;
    }
    [self.socket writeData:data withTimeout:-1 tag:KDECTransportTagPacket];
    return YES;
}

- (BOOL)sendFileAtPath:(NSString *)path filename:(NSString *)filename
{
    if (!self.socket.isConnected) {
        return NO;
    }

    if (!self.payloadServer) {
        self.payloadServer = [[GCDAsyncSocket alloc] initWithDelegate:self
                                                       delegateQueue:dispatch_get_main_queue()];
        NSError *error = nil;
        uint16_t port = KDECPayloadPort;
        while (port < KDECPayloadPort + 100 &&
               ![self.payloadServer acceptOnPort:port error:&error]) {
            port++;
        }
        if (port >= KDECPayloadPort + 100) {
            self.payloadServer = nil;
            return NO;
        }
        self.payloadPort = port;
    }

    KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithType:KDECPacketTypeShare];
    [packet setObject:filename forKey:@"filename"];
    self.pendingPayload = [NSData dataWithContentsOfFile:path];
    if (!self.pendingPayload) {
        return NO;
    }
    packet.payloadSize = (long long)self.pendingPayload.length;
    packet.payloadTransferInfo = @{@"port": @(self.payloadPort)};
    self.pendingFilename = filename;
    return [self sendPacket:packet];
}

- (void)sendIdentity
{
    if (!self.socket.isSecure) {
        return;
    }
    KDECCertificateManager *certificates = [KDECCertificateManager shared];
    KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithType:KDECPacketTypeIdentity];
    [packet setObject:certificates.deviceId forKey:@"deviceId"];
    [packet setObject:certificates.deviceName forKey:@"deviceName"];
    [packet setObject:@"phone" forKey:@"deviceType"];
    [packet setInteger:8 forKey:@"protocolVersion"];
    [packet setObject:@[KDECPacketTypeShare, KDECPacketTypeClipboard,
                        KDECPacketTypeClipboardConnect] forKey:@"incomingCapabilities"];
    [packet setObject:@[KDECPacketTypeShare, KDECPacketTypeClipboard,
                        KDECPacketTypeClipboardConnect] forKey:@"outgoingCapabilities"];
    [self sendPacket:packet];
}

- (void)disconnect
{
    self.socket.delegate = nil;
    [self.socket disconnect];
    self.socket = nil;
    self.payloadServer.delegate = nil;
    [self.payloadServer disconnect];
    self.payloadServer = nil;
    self.pendingPayloadSocket = nil;
    [self.readBuffer setLength:0];
    self.pendingPayload = nil;
    self.pendingFilename = nil;
    for (KDECPayloadConnection *connection in self.payloadConnections) {
        connection.socket.delegate = nil;
        [connection.socket disconnect];
    }
    [self.payloadConnections removeAllObjects];
    self.handshakeComplete = NO;
    if (self.peerCertificate) {
        CFRelease(self.peerCertificate);
        self.peerCertificate = NULL;
    }
    [self setReachable:NO];
}

- (SecCertificateRef)copyPeerCertificate
{
    return self.peerCertificate ? (SecCertificateRef)CFRetain(self.peerCertificate) : NULL;
}

- (void)setReachable:(BOOL)reachable
{
    if (_reachable == reachable) {
        return;
    }
    _reachable = reachable;
    self.device.reachable = reachable;
    [self.delegate transport:self didChangeReachability:reachable];
}

- (void)dealloc
{
    if (_peerCertificate) {
        CFRelease(_peerCertificate);
    }
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port
{
    if (sock == self.payloadServer) {
        return;
    }
    NSDictionary *settings = @{
        (id)GCDAsyncSocketSSLIsServer: @YES,
        (id)GCDAsyncSocketSSLCertificates: @[(__bridge id)[KDECCertificateManager shared].hostIdentity],
        (id)GCDAsyncSocketManuallyEvaluateTrust: @YES,
    };
    [sock startTLS:settings];
}

- (void)socket:(GCDAsyncSocket *)sock
didReceiveTrust:(SecTrustRef)trust
completionHandler:(void (^)(BOOL))completionHandler
{
    if (sock != self.socket) {
        completionHandler(YES);
        return;
    }
    SecCertificateRef certificate = [[KDECCertificateManager shared]
                                     copyRemoteCertificateFromTrust:trust];
    BOOL trusted = [[KDECCertificateManager shared]
                    shouldTrustCertificateFromTrust:trust
                    forDeviceId:self.device.deviceId];
    if (trusted && certificate) {
        if (self.peerCertificate) {
            CFRelease(self.peerCertificate);
        }
        self.peerCertificate = certificate;
    } else if (certificate) {
        CFRelease(certificate);
    }
    completionHandler(trusted);
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
    if (sock != self.socket) {
        return;
    }
    if (!sock.isSecure) {
        [self disconnect];
        return;
    }
    [self.readBuffer appendData:data];
    [self processReadBuffer];
    if (!self.socket) {
        return;
    }
    [sock readDataToData:[GCDAsyncSocket LFData]
             withTimeout:-1
               maxLength:KDECMaxPacketSize
                     tag:KDECTransportTagPacket];
}

- (void)processReadBuffer
{
    const uint8_t *bytes = self.readBuffer.bytes;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < self.readBuffer.length; i++) {
        if (bytes[i] != '\n') {
            continue;
        }
        NSData *line = [self.readBuffer subdataWithRange:NSMakeRange(start, i - start)];
        start = i + 1;
        KDEConnectPacket *packet = [[KDEConnectPacket alloc] initWithData:line];
        if (packet) {
            if (!self.handshakeComplete) {
                NSString *deviceId = [packet stringForKey:@"deviceId"];
                if (![packet.type isEqualToString:KDECPacketTypeIdentity] ||
                    ![deviceId isEqualToString:self.device.deviceId]) {
                    [self disconnect];
                    return;
                }
                self.handshakeComplete = YES;
                [self.delegate transport:self didCompleteHandshakeWithDeviceId:deviceId];
                [self setReachable:YES];
            } else {
                [self handlePacket:packet];
            }
        }
    }
    if (start > 0) {
        [self.readBuffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    }
}

- (void)handlePacket:(KDEConnectPacket *)packet
{
    NSNumber *port = packet.payloadTransferInfo[@"port"];
    if (packet.payloadSize > 0 && port) {
        __weak typeof(self) weakSelf = self;
        KDECPayloadConnection *connection = [[KDECPayloadConnection alloc] init];
        connection.length = (NSUInteger)packet.payloadSize;
        connection.certificate = [KDECCertificateManager shared].hostIdentity;
        connection.socket = [[GCDAsyncSocket alloc] initWithDelegate:connection
                                                      delegateQueue:dispatch_get_main_queue()];
        connection.completion = ^(NSData *data, NSError *error) {
            if (!data) {
                return;
            }
            packet.payload = data;
            [weakSelf.delegate transport:weakSelf didReceivePacket:packet];
            [weakSelf.payloadConnections removeObject:connection];
        };
        [self.payloadConnections addObject:connection];
        NSError *connectError = nil;
        if (![connection.socket connectToHost:self.device.host
                                      onPort:port.unsignedShortValue
                                       error:&connectError]) {
            [self.payloadConnections removeObject:connection];
        }
        return;
    }
    [self.delegate transport:self didReceivePacket:packet];
}

- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket
{
    if (sock != self.payloadServer || !self.pendingPayload) {
        [newSocket disconnect];
        return;
    }
    NSDictionary *settings = @{
        (id)GCDAsyncSocketSSLIsServer: @NO,
        (id)GCDAsyncSocketSSLCertificates: @[(__bridge id)[KDECCertificateManager shared].hostIdentity],
        (id)GCDAsyncSocketManuallyEvaluateTrust: @YES,
    };
    self.pendingPayloadSocket = newSocket;
    objc_setAssociatedObject(newSocket, @selector(tag), self.pendingPayload,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [newSocket startTLS:settings];
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock
{
    if (sock == self.socket) {
        [self setReachable:YES];
        [self sendIdentity];
        [sock readDataToData:[GCDAsyncSocket LFData]
                 withTimeout:-1
                   maxLength:KDECMaxPacketSize
                         tag:KDECTransportTagPacket];
    } else {
        NSData *payload = objc_getAssociatedObject(sock, @selector(tag));
        if (payload) {
            [sock writeData:payload withTimeout:-1 tag:KDECTransportTagPacket];
        }
    }
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
    if (sock == self.pendingPayloadSocket) {
        [sock disconnect];
        self.pendingPayloadSocket = nil;
        self.pendingPayload = nil;
        self.pendingFilename = nil;
        return;
    }
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
    if (sock == self.pendingPayloadSocket) {
        self.pendingPayloadSocket = nil;
        self.pendingPayload = nil;
        self.pendingFilename = nil;
        return;
    }
    if (sock == self.socket) {
        [self setReachable:NO];
    }
}

@end
