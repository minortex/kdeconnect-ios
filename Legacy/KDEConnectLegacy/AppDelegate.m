//
//  AppDelegate.m
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import "AppDelegate.h"
#import "DevicesViewController.h"
#import "KDECService.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    DevicesViewController *devices = [[DevicesViewController alloc] init];
    UINavigationController *navigation = [[UINavigationController alloc]
                                          initWithRootViewController:devices];
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    [[KDECService shared] start];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    [[KDECService shared] stop];
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    [[KDECService shared] start];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    [[KDECService shared] stop];
}

@end
