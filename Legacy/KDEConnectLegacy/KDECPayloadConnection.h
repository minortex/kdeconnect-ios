//
//  KDECPayloadConnection.h
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>

@class GCDAsyncSocket;

NS_ASSUME_NONNULL_BEGIN

@interface KDECPayloadConnection : NSObject

@property (nonatomic, strong) GCDAsyncSocket *socket;
@property (nonatomic, copy, nullable) void (^completion)(NSData * _Nullable data, NSError * _Nullable error);
@property (nonatomic, assign) NSUInteger length;
@property (nonatomic, assign) SecIdentityRef certificate;

@end

NS_ASSUME_NONNULL_END
