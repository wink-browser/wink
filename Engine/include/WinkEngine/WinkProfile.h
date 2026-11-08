#import <Foundation/Foundation.h>
#import <WinkEngine/WinkRuntime.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, WinkBrowsingDataTypes) {
  WinkBrowsingDataCookies = 1 << 0,
  WinkBrowsingDataCache = 1 << 1,
  WinkBrowsingDataHTTPAuth = 1 << 2,
  WinkBrowsingDataConnections = 1 << 3,
  WinkBrowsingDataAll = 0xFF,
};

/// A cookie brought in from another browser. The value is plaintext here;
/// Chromium encrypts it at rest with Wink's own key.
@interface WinkCookie : NSObject
@property (copy) NSString *name;
@property (copy) NSString *value;
/// "example.com" makes a host cookie, ".example.com" a domain cookie.
@property (copy) NSString *domain;
@property (copy) NSString *path;
@property BOOL secure;
@property BOOL httpOnly;
/// nil for a session cookie.
@property (nullable, copy) NSDate *expires;
@property (nullable, copy) NSDate *creation;
@property (nullable, copy) NSDate *lastAccess;
/// Chromium's stored values: -1 unspecified, 0 none, 1 lax, 2 strict.
@property NSInteger sameSite;
/// Chromium's stored values: 0 low, 1 medium, 2 high.
@property NSInteger priority;
@end

/// A browsing profile (cookie jar, cache, storage). Wraps a Chromium
/// request context. Ephemeral profiles keep everything in memory and vanish
/// when the last tab using them closes — used for private windows and for
/// sandboxed agent browsing.
NS_SWIFT_UI_ACTOR
@interface WinkProfile : NSObject

/// The persistent profile the user browses with.
@property (class, readonly) WinkProfile *defaultProfile;

/// A new in-memory profile isolated from every other profile.
+ (instancetype)ephemeralProfileWithName:(NSString *)name;

@property (readonly, copy) NSString *name;
@property (readonly) BOOL isEphemeral;

/// Sets a Chromium preference (NSNumber/NSString/NSArray/NSDictionary/NSNull).
- (BOOL)setPreference:(NSString *)name
                value:(nullable id)value
                error:(NSString *_Nullable *_Nullable)error;
- (nullable id)preferenceValueForName:(NSString *)name;

- (void)clearBrowsingData:(WinkBrowsingDataTypes)types
               completion:(nullable WinkVoidBlock)completion;
/// Deletes cookies for every host matching `domain` (and its subdomains).
- (void)deleteCookiesForDomain:(NSString *)domain
                    completion:(nullable void (^)(NSInteger deletedCount))completion;
/// Lists cookie domains (for the privacy report); no values are exposed.
- (void)cookieDomainsWithCompletion:(void (^)(NSArray<NSString *> *domains))completion;
/// Adds cookies to this profile (importing logins from another browser).
/// Chromium validates each one as if a site had set it. The completion runs
/// on the main thread with how many were accepted and rejected.
- (void)importCookies:(NSArray<WinkCookie *> *)cookies
           completion:(nullable void (^)(NSInteger imported, NSInteger rejected))completion
    NS_SWIFT_NAME(importCookies(_:completion:));

@end

NS_ASSUME_NONNULL_END
