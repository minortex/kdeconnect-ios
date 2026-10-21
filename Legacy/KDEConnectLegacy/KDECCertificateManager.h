//
//  KDECCertificateManager.h
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

@interface KDECCertificateManager : NSObject

+ (instancetype)shared;

- (NSString *)deviceId;
- (NSString *)deviceName;
- (SecIdentityRef)hostIdentity;
- (SecCertificateRef)hostCertificate;

- (nullable SecCertificateRef)copyRemoteCertificateFromTrust:(SecTrustRef)trust;
- (BOOL)shouldTrustCertificateFromTrust:(SecTrustRef)trust
                           forDeviceId:(NSString *)deviceId;
- (BOOL)isCertificate:(SecCertificateRef)certificate
          validForId:(NSString *)deviceId;
- (BOOL)savePairedCertificate:(SecCertificateRef)certificate
                  forDeviceId:(NSString *)deviceId;
- (BOOL)deletePairedCertificateForDeviceId:(NSString *)deviceId;
- (nullable SecCertificateRef)copyPairedCertificateForDeviceId:(NSString *)deviceId;
- (BOOL)isDevicePaired:(NSString *)deviceId;

@end

NS_ASSUME_NONNULL_END
