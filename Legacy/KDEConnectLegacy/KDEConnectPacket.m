//
//  KDEConnectPacket.m
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import "KDEConnectPacket.h"

NSString *const KDECPacketTypeIdentity = @"kdeconnect.identity";
NSString *const KDECPacketTypePair = @"kdeconnect.pair";
NSString *const KDECPacketTypeShare = @"kdeconnect.share.request";
NSString *const KDECPacketTypeClipboard = @"kdeconnect.clipboard";
NSString *const KDECPacketTypeClipboardConnect = @"kdeconnect.clipboard.connect";

@implementation KDEConnectPacket

- (instancetype)initWithType:(NSString *)type
{
    self = [super init];
    if (self) {
        _type = [type copy];
        _body = [NSMutableDictionary dictionary];
        _payloadSize = -1;
    }
    return self;
}

- (instancetype)initWithData:(NSData *)data
{
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *type = json[@"type"];
    NSDictionary *body = json[@"body"];
    if (![type isKindOfClass:[NSString class]] || ![body isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    self = [self initWithType:type];
    if (self) {
        _body = [body mutableCopy];
        NSNumber *payloadSize = json[@"payloadSize"];
        if ([payloadSize isKindOfClass:[NSNumber class]]) {
            _payloadSize = payloadSize.longLongValue;
        }
        NSDictionary *transferInfo = json[@"payloadTransferInfo"];
        if ([transferInfo isKindOfClass:[NSDictionary class]]) {
            _payloadTransferInfo = [transferInfo copy];
        }
    }
    return self;
}

- (id)objectForKey:(NSString *)key
{
    return self.body[key];
}

- (NSString *)stringForKey:(NSString *)key
{
    id value = [self objectForKey:key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

- (NSInteger)integerForKey:(NSString *)key
{
    return [[self objectForKey:key] integerValue];
}

- (BOOL)boolForKey:(NSString *)key
{
    return [[self objectForKey:key] boolValue];
}

- (void)setObject:(id)value forKey:(NSString *)key
{
    self.body[key] = value;
}

- (void)setInteger:(NSInteger)value forKey:(NSString *)key
{
    [self setObject:@(value) forKey:key];
}

- (void)setBool:(BOOL)value forKey:(NSString *)key
{
    [self setObject:@(value) forKey:key];
}

- (NSData *)serialize
{
    NSMutableDictionary *json = [@{
        @"id": @((long long)[NSDate date].timeIntervalSince1970),
        @"type": self.type,
        @"body": self.body,
    } mutableCopy];
    if (self.payload) {
        json[@"payloadSize"] = @(self.payloadSize);
        json[@"payloadTransferInfo"] = self.payloadTransferInfo ?: @{};
    }

    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:json options:0 error:nil] mutableCopy];
    if (!data) {
        return nil;
    }
    [data appendBytes:"\n" length:1];
    return data;
}

@end
