//
//  KDECCertificateManager.m
//  KDE Connect Legacy
//
//  SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
//

#import "KDECCertificateManager.h"

#import <UIKit/UIKit.h>

#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>

static NSString *const KDECDeviceIdDefaultsKey = @"KDECDeviceId";
static NSString *const KDECDeviceNameDefaultsKey = @"KDECDeviceName";
static NSString *const KDECCertificateLabelPrefix = @"org.kde.kdeconnect.legacy.cert.";

@interface KDECCertificateManager () {
    SecIdentityRef _hostIdentity;
    SecCertificateRef _hostCertificate;
}
@end

@implementation KDECCertificateManager

+ (instancetype)shared
{
    static KDECCertificateManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[KDECCertificateManager alloc] init];
    });
    return shared;
}

- (void)dealloc
{
    if (_hostIdentity) {
        CFRelease(_hostIdentity);
    }
    if (_hostCertificate) {
        CFRelease(_hostCertificate);
    }
}

- (NSString *)deviceId
{
    NSString *deviceId = [[NSUserDefaults standardUserDefaults] stringForKey:KDECDeviceIdDefaultsKey];
    if (deviceId.length > 0) {
        return deviceId;
    }

    NSString *vendorId = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    if (vendorId.length == 0) {
        vendorId = [[NSUUID UUID] UUIDString];
    }
    deviceId = [[vendorId stringByReplacingOccurrencesOfString:@"-" withString:@""]
                stringByReplacingOccurrencesOfString:@"_" withString:@""];
    [[NSUserDefaults standardUserDefaults] setObject:deviceId forKey:KDECDeviceIdDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return deviceId;
}

- (NSString *)deviceName
{
    NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:KDECDeviceNameDefaultsKey];
    if (name.length == 0) {
        name = [[UIDevice currentDevice] name];
    }
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"\"',;:.!?()[]<>"];
    NSArray *parts = [name componentsSeparatedByCharactersInSet:invalid];
    name = [[parts componentsJoinedByString:@""] stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) {
        name = @"iPhone";
    }
    if (name.length > 32) {
        name = [name substringToIndex:32];
    }
    return name;
}

- (SecIdentityRef)hostIdentity
{
    if (_hostIdentity) {
        return _hostIdentity;
    }

    NSString *path = [self identityPath];
    NSData *p12Data = [NSData dataWithContentsOfFile:path];
    if (p12Data.length == 0) {
        if (![self generateIdentityAtPath:path]) {
            return NULL;
        }
        p12Data = [NSData dataWithContentsOfFile:path];
    }

    NSDictionary *options = @{(__bridge id)kSecImportExportPassphrase: @""};
    CFArrayRef items = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)p12Data,
                                      (__bridge CFDictionaryRef)options,
                                      &items);
    if (status != errSecSuccess || items == NULL || CFArrayGetCount(items) == 0) {
        if (items) {
            CFRelease(items);
        }
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return NULL;
    }

    CFDictionaryRef item = CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef identity = (SecIdentityRef)CFDictionaryGetValue(item, kSecImportItemIdentity);
    if (identity) {
        _hostIdentity = (SecIdentityRef)CFRetain(identity);
    }
    CFRelease(items);
    return _hostIdentity;
}

- (SecCertificateRef)hostCertificate
{
    if (_hostCertificate) {
        return _hostCertificate;
    }
    SecIdentityRef identity = [self hostIdentity];
    if (!identity) {
        return NULL;
    }
    SecCertificateRef certificate = NULL;
    if (SecIdentityCopyCertificate(identity, &certificate) != errSecSuccess) {
        return NULL;
    }
    _hostCertificate = certificate;
    return _hostCertificate;
}

- (NSString *)identityPath
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                        NSUserDomainMask, YES);
    NSString *directory = paths.firstObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [directory stringByAppendingPathComponent:@"identity.p12"];
}

- (BOOL)generateIdentityAtPath:(NSString *)path
{
    EVP_PKEY *pkey = EVP_PKEY_new();
    RSA *rsa = RSA_generate_key(2048, RSA_F4, NULL, NULL);
    if (!pkey || !rsa) {
        if (pkey) EVP_PKEY_free(pkey);
        if (rsa) RSA_free(rsa);
        return NO;
    }
    EVP_PKEY_assign_RSA(pkey, rsa);

    X509 *certificate = X509_new();
    if (!certificate) {
        EVP_PKEY_free(pkey);
        return NO;
    }
    X509_set_version(certificate, 2);
    ASN1_INTEGER_set(X509_get_serialNumber(certificate), (long)time(NULL));
    X509_gmtime_adj(X509_get_notBefore(certificate), -60 * 60);
    X509_gmtime_adj(X509_get_notAfter(certificate), 10L * 365 * 24 * 60 * 60);
    X509_set_pubkey(certificate, pkey);

    X509_NAME *name = X509_get_subject_name(certificate);
    X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC, (const unsigned char *)"KDE", -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "OU", MBSTRING_ASC, (const unsigned char *)"KDE Connect", -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                               (const unsigned char *)[self.deviceId UTF8String], -1, -1, 0);
    X509_set_issuer_name(certificate, name);

    BOOL success = X509_sign(certificate, pkey, EVP_sha256()) != 0;
    if (success) {
        PKCS12 *p12 = PKCS12_create("", "KDE Connect", pkey, certificate,
                                    NULL, 0, 0, 0, PKCS12_DEFAULT_ITER, 0);
        if (p12) {
            FILE *file = fopen([path fileSystemRepresentation], "wb");
            success = file != NULL && i2d_PKCS12_fp(file, p12) > 0;
            if (file) {
                fclose(file);
            }
            PKCS12_free(p12);
        } else {
            success = NO;
        }
    }

    X509_free(certificate);
    EVP_PKEY_free(pkey);
    return success;
}

- (SecCertificateRef)copyRemoteCertificateFromTrust:(SecTrustRef)trust
{
    if (SecTrustGetCertificateCount(trust) == 0) {
        return NULL;
    }
    SecCertificateRef certificate = SecTrustGetCertificateAtIndex(trust, 0);
    return certificate ? (SecCertificateRef)CFRetain(certificate) : NULL;
}

- (BOOL)isCertificate:(SecCertificateRef)certificate validForId:(NSString *)deviceId
{
    if (!certificate || deviceId.length == 0) {
        return NO;
    }
    CFStringRef summary = SecCertificateCopySubjectSummary(certificate);
    BOOL valid = summary != NULL && [(__bridge NSString *)summary isEqualToString:deviceId];
    if (summary) {
        CFRelease(summary);
    }
    return valid;
}

- (BOOL)shouldTrustCertificateFromTrust:(SecTrustRef)trust
                           forDeviceId:(NSString *)deviceId
{
    SecCertificateRef certificate = [self copyRemoteCertificateFromTrust:trust];
    if (!certificate) {
        return NO;
    }

    BOOL shouldTrust = [self isCertificate:certificate validForId:deviceId];
    SecCertificateRef saved = [self copyPairedCertificateForDeviceId:deviceId];
    if (shouldTrust && saved) {
        NSData *incoming = (__bridge_transfer NSData *)SecCertificateCopyData(certificate);
        NSData *known = (__bridge_transfer NSData *)SecCertificateCopyData(saved);
        shouldTrust = [incoming isEqualToData:known];
    }
    if (saved) {
        CFRelease(saved);
    }
    CFRelease(certificate);
    return shouldTrust;
}

- (BOOL)savePairedCertificate:(SecCertificateRef)certificate
                  forDeviceId:(NSString *)deviceId
{
    if (!certificate || deviceId.length == 0) {
        return NO;
    }
    NSString *label = [KDECCertificateLabelPrefix stringByAppendingString:deviceId];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassCertificate,
        (__bridge id)kSecAttrLabel: label,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);

    NSDictionary *item = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassCertificate,
        (__bridge id)kSecAttrLabel: label,
        (__bridge id)kSecValueRef: (__bridge id)certificate,
    };
    return SecItemAdd((__bridge CFDictionaryRef)item, NULL) == errSecSuccess;
}

- (SecCertificateRef)copyPairedCertificateForDeviceId:(NSString *)deviceId
{
    NSString *label = [KDECCertificateLabelPrefix stringByAppendingString:deviceId];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassCertificate,
        (__bridge id)kSecAttrLabel: label,
        (__bridge id)kSecReturnRef: @YES,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) {
        return NULL;
    }
    return (SecCertificateRef)result;
}

- (BOOL)deletePairedCertificateForDeviceId:(NSString *)deviceId
{
    NSString *label = [KDECCertificateLabelPrefix stringByAppendingString:deviceId];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassCertificate,
        (__bridge id)kSecAttrLabel: label,
    };
    return SecItemDelete((__bridge CFDictionaryRef)query) == errSecSuccess;
}

- (BOOL)isDevicePaired:(NSString *)deviceId
{
    SecCertificateRef certificate = [self copyPairedCertificateForDeviceId:deviceId];
    if (certificate) {
        CFRelease(certificate);
        return YES;
    }
    return NO;
}

@end
