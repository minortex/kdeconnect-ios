//
//  KDECPayloadConnection.m
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import "KDECPayloadConnection.h"
#import "GCDAsyncSocket.h"

static const long KDECPayloadTag = 1;

@interface KDECPayloadConnection () <GCDAsyncSocketDelegate>
@end

@implementation KDECPayloadConnection

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port
{
    NSDictionary *settings = @{
        (id)GCDAsyncSocketSSLIsServer: @NO,
        (id)GCDAsyncSocketSSLCertificates: @[(__bridge id)self.certificate],
        (id)GCDAsyncSocketManuallyEvaluateTrust: @YES,
    };
    [sock startTLS:settings];
}

- (void)socket:(GCDAsyncSocket *)sock
didReceiveTrust:(SecTrustRef)trust
completionHandler:(void (^)(BOOL))completionHandler
{
    completionHandler(YES);
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock
{
    [sock readDataToLength:self.length withTimeout:-1 tag:KDECPayloadTag];
}

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
    void (^completion)(NSData *, NSError *) = self.completion;
    self.completion = nil;
    [sock disconnect];
    if (completion) {
        completion(data, nil);
    }
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
    void (^completion)(NSData *, NSError *) = self.completion;
    self.completion = nil;
    if (completion) {
        completion(nil, err);
    }
}

- (void)dealloc
{
    self.socket.delegate = nil;
    [self.socket disconnect];
}

@end
