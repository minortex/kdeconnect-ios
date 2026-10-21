//
//  KDECTransport.h
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>

@class KDECDeviceInfo;
@class KDEConnectPacket;
@class KDECTransport;

NS_ASSUME_NONNULL_BEGIN

@protocol KDECTransportDelegate <NSObject>
- (void)transport:(KDECTransport *)transport didReceivePacket:(KDEConnectPacket *)packet;
- (void)transport:(KDECTransport *)transport didChangeReachability:(BOOL)reachable;
- (void)transport:(KDECTransport *)transport didCompleteHandshakeWithDeviceId:(NSString *)deviceId;
@end

@interface KDECTransport : NSObject

@property (nonatomic, weak) id<KDECTransportDelegate> delegate;
@property (nonatomic, readonly, getter=isReachable) BOOL reachable;

- (instancetype)initWithDevice:(KDECDeviceInfo *)device;
- (void)connectToHost:(NSString *)host port:(uint16_t)port;
- (void)acceptSocket:(id)socket;
- (void)sendIdentity;
- (SecCertificateRef)copyPeerCertificate;
- (BOOL)sendPacket:(KDEConnectPacket *)packet;
- (BOOL)sendFileAtPath:(NSString *)path filename:(NSString *)filename;
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
