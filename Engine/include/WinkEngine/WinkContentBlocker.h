#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Network-level privacy protections enforced inside the engine's IO thread:
/// tracker/ad blocking, HTTPS upgrades and Global Privacy Control. All class
/// methods are thread-safe.
@interface WinkContentBlocker : NSObject

/// Loads a rules file: one domain per line. Lines starting with `#` are
/// comments; a `$third-party` suffix restricts the rule to third-party
/// requests. Parsing happens off the main thread; rules swap in atomically.
+ (void)loadRulesFromFile:(NSString *)path
               completion:(nullable void (^)(NSInteger ruleCount))completion;

@property (class, readonly) NSInteger ruleCount;

/// Global switch for tracker/ad blocking (default YES).
@property (class, nonatomic) BOOL blockingEnabled;
/// Upgrade top-level http:// navigations to https:// (default YES).
@property (class, nonatomic) BOOL httpsUpgradesEnabled;
/// Send `Sec-GPC: 1` and expose navigator.globalPrivacyControl (default YES).
@property (class, nonatomic) BOOL globalPrivacyControlEnabled;

/// Sites (registrable domains) where the user has turned protections off.
+ (void)setAllowlistedSites:(NSArray<NSString *> *)sites;

/// Hosts that failed after an HTTPS upgrade; navigations stay on http.
+ (void)allowInsecureHost:(NSString *)host;
+ (BOOL)isInsecureHostAllowed:(NSString *)host;

/// Returns the registrable domain ("eTLD+1") for a host, e.g. news.bbc.co.uk -> bbc.co.uk.
+ (NSString *)registrableDomainForHost:(NSString *)host;

/// Pure lookup used by tests and the privacy report.
+ (BOOL)shouldBlockURL:(NSString *)url firstPartyURL:(nullable NSString *)firstPartyURL;

@end

NS_ASSUME_NONNULL_END
