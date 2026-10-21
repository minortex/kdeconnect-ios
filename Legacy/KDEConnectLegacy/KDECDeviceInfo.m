//
//  KDECDeviceInfo.m
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import "KDECDeviceInfo.h"
#import "KDEConnectPacket.h"

@implementation KDECDeviceInfo

- (instancetype)initWithIdentityPacket:(KDEConnectPacket *)packet
{
    self = [super init];
    if (self) {
        _deviceId = [packet stringForKey:@"deviceId"];
        _name = [packet stringForKey:@"deviceName"];
        _type = [packet stringForKey:@"deviceType"] ?: @"unknown";
        _protocolVersion = [packet integerForKey:@"protocolVersion"];
        _incomingCapabilities = [packet objectForKey:@"incomingCapabilities"] ?: @[];
        _outgoingCapabilities = [packet objectForKey:@"outgoingCapabilities"] ?: @[];
        _tcpPort = (uint16_t)[packet integerForKey:@"tcpPort"];
        _reachable = NO;
        _paired = NO;
    }
    return self;
}

- (BOOL)updateWithIdentityPacket:(KDEConnectPacket *)packet
{
    NSString *deviceId = [packet stringForKey:@"deviceId"];
    if (deviceId.length == 0 || ![deviceId isEqualToString:self.deviceId]) {
        return NO;
    }
    self.name = [packet stringForKey:@"deviceName"] ?: self.name;
    self.type = [packet stringForKey:@"deviceType"] ?: self.type;
    self.protocolVersion = [packet integerForKey:@"protocolVersion"];
    self.incomingCapabilities = [packet objectForKey:@"incomingCapabilities"] ?: self.incomingCapabilities;
    self.outgoingCapabilities = [packet objectForKey:@"outgoingCapabilities"] ?: self.outgoingCapabilities;
    uint16_t tcpPort = (uint16_t)[packet integerForKey:@"tcpPort"];
    if (tcpPort > 0) {
        self.tcpPort = tcpPort;
    }
    return YES;
}

+ (KDECDeviceInfo *)deviceFromDictionary:(NSDictionary *)dictionary
{
    NSString *deviceId = dictionary[@"deviceId"];
    NSString *name = dictionary[@"name"];
    if (deviceId.length == 0 || name.length == 0) {
        return nil;
    }
    KDECDeviceInfo *info = [[KDECDeviceInfo alloc] init];
    info.deviceId = deviceId;
    info.name = name;
    info.type = dictionary[@"type"] ?: @"unknown";
    info.protocolVersion = [dictionary[@"protocolVersion"] integerValue];
    info.incomingCapabilities = dictionary[@"incomingCapabilities"] ?: @[];
    info.outgoingCapabilities = dictionary[@"outgoingCapabilities"] ?: @[];
    info.paired = [dictionary[@"paired"] boolValue];
    info.host = dictionary[@"host"];
    info.tcpPort = (uint16_t)[dictionary[@"tcpPort"] integerValue];
    return info;
}

- (NSDictionary *)dictionaryRepresentation
{
    return @{
        @"deviceId": self.deviceId,
        @"name": self.name,
        @"type": self.type,
        @"protocolVersion": @(self.protocolVersion),
        @"incomingCapabilities": self.incomingCapabilities,
        @"outgoingCapabilities": self.outgoingCapabilities,
        @"paired": @(self.paired),
        @"host": self.host ?: @"",
        @"tcpPort": @(self.tcpPort),
    };
}

@end
