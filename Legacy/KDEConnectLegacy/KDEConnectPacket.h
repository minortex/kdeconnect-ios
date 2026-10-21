//
//  KDEConnectPacket.h
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const KDECPacketTypeIdentity;
extern NSString *const KDECPacketTypePair;
extern NSString *const KDECPacketTypeShare;
extern NSString *const KDECPacketTypeClipboard;
extern NSString *const KDECPacketTypeClipboardConnect;

@interface KDEConnectPacket : NSObject

@property (nonatomic, copy) NSString *type;
@property (nonatomic, strong) NSMutableDictionary *body;
@property (nonatomic, copy, nullable) NSData *payload;
@property (nonatomic, copy, nullable) NSDictionary *payloadTransferInfo;
@property (nonatomic, assign) long long payloadSize;

- (instancetype)initWithType:(NSString *)type;
- (nullable instancetype)initWithData:(NSData *)data;

- (nullable id)objectForKey:(NSString *)key;
- (nullable NSString *)stringForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;

- (NSData *)serialize;

@end

NS_ASSUME_NONNULL_END
