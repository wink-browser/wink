#import <WinkEngine/WinkContentBlocker.h>

#include <string>
#include <vector>

#include "content_blocker.h"

using wink::ContentBlocker;

@implementation WinkContentBlocker

+ (void)loadRulesFromFile:(NSString*)path completion:(void (^)(NSInteger))completion {
  NSString* filePath = [path copy];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSData* data = [NSData dataWithContentsOfFile:filePath options:NSDataReadingMappedIfSafe error:nil];
    size_t count = 0;
    if (data.length) {
      count = ContentBlocker::Get().LoadRules(
          std::string_view(static_cast<const char*>(data.bytes), data.length));
    }
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{ completion((NSInteger)count); });
    }
  });
}

+ (NSInteger)ruleCount {
  return (NSInteger)ContentBlocker::Get().RuleCount();
}

+ (BOOL)blockingEnabled {
  return ContentBlocker::Get().blocking_enabled.load();
}

+ (void)setBlockingEnabled:(BOOL)enabled {
  ContentBlocker::Get().blocking_enabled.store(enabled);
}

+ (BOOL)httpsUpgradesEnabled {
  return ContentBlocker::Get().https_upgrades_enabled.load();
}

+ (void)setHttpsUpgradesEnabled:(BOOL)enabled {
  ContentBlocker::Get().https_upgrades_enabled.store(enabled);
}

+ (BOOL)globalPrivacyControlEnabled {
  return ContentBlocker::Get().gpc_enabled.load();
}

+ (void)setGlobalPrivacyControlEnabled:(BOOL)enabled {
  ContentBlocker::Get().gpc_enabled.store(enabled);
}

+ (void)setAllowlistedSites:(NSArray<NSString*>*)sites {
  std::vector<std::string> out;
  out.reserve(sites.count);
  for (NSString* site in sites) out.emplace_back(site.lowercaseString.UTF8String ?: "");
  ContentBlocker::Get().SetAllowlistedSites(out);
}

+ (void)allowInsecureHost:(NSString*)host {
  ContentBlocker::Get().AllowInsecureHost(host.lowercaseString.UTF8String ?: "");
}

+ (BOOL)isInsecureHostAllowed:(NSString*)host {
  return ContentBlocker::Get().IsInsecureHostAllowed(host.lowercaseString.UTF8String ?: "");
}

+ (NSString*)registrableDomainForHost:(NSString*)host {
  std::string h = host.lowercaseString.UTF8String ?: "";
  std::string_view d = ContentBlocker::RegistrableDomain(h);
  return [[NSString alloc] initWithBytes:d.data() length:d.size() encoding:NSUTF8StringEncoding] ?: host;
}

+ (BOOL)shouldBlockURL:(NSString*)url firstPartyURL:(NSString*)firstPartyURL {
  return ContentBlocker::Get().ShouldBlock(url.UTF8String ?: "", firstPartyURL.UTF8String ?: "", nullptr);
}

@end
