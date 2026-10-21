//
//  KDECService.h
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class KDECDeviceInfo;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const KDECServiceDevicesDidChangeNotification;
extern NSString *const KDECServicePairRequestNotification;
extern NSString *const KDECServiceFileReceivedNotification;

@interface KDECService : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSArray<KDECDeviceInfo *> *devices;

- (void)start;
- (void)stop;
- (void)refresh;
- (void)pairDevice:(KDECDeviceInfo *)device;
- (void)unpairDevice:(KDECDeviceInfo *)device;
- (void)sendClipboardToDevice:(KDECDeviceInfo *)device;
- (BOOL)sendFileAtPath:(NSString *)path toDevice:(KDECDeviceInfo *)device;
- (void)acceptPairingForDevice:(KDECDeviceInfo *)device;
- (void)rejectPairingForDevice:(KDECDeviceInfo *)device;

@end

NS_ASSUME_NONNULL_END
