//
//  KDECDeviceInfo.h
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>

@class KDEConnectPacket;

NS_ASSUME_NONNULL_BEGIN

@interface KDECDeviceInfo : NSObject

@property (nonatomic, copy) NSString *deviceId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, assign) NSInteger protocolVersion;
@property (nonatomic, copy) NSArray<NSString *> *incomingCapabilities;
@property (nonatomic, copy) NSArray<NSString *> *outgoingCapabilities;
@property (nonatomic, copy, nullable) NSString *host;
@property (nonatomic, assign) uint16_t tcpPort;
@property (nonatomic, assign) BOOL paired;
@property (nonatomic, assign) BOOL reachable;

- (instancetype)initWithIdentityPacket:(KDEConnectPacket *)packet;
- (BOOL)updateWithIdentityPacket:(KDEConnectPacket *)packet;

+ (nullable KDECDeviceInfo *)deviceFromDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)dictionaryRepresentation;

@end

NS_ASSUME_NONNULL_END
