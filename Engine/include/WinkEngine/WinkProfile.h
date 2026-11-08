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

@end

NS_ASSUME_NONNULL_END
