//
//  DeviceViewController.h
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import <UIKit/UIKit.h>

@class KDECDeviceInfo;

@interface DeviceViewController : UIViewController

- (instancetype)initWithDevice:(KDECDeviceInfo *)device;

@end
