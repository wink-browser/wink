#import <WinkEngine/WinkProfile.h>

#import "WinkInternal.h"

#include <atomic>
#include <memory>

#include "include/cef_cookie.h"

namespace {

class BlockCompletion : public CefCompletionCallback {
 public:
  explicit BlockCompletion(WinkVoidBlock block) : block_([block copy]) {}
  void OnComplete() override {
    WinkVoidBlock block = block_;
    block_ = nil;
    if (block) dispatch_async(dispatch_get_main_queue(), block);
  }

 private:
  WinkVoidBlock block_;
  IMPLEMENT_REFCOUNTING(BlockCompletion);
};

// Shared countdown: the completion runs once every operation has arrived.
struct Barrier {
  Barrier(int count, WinkVoidBlock done) : remaining(count), block([done copy]) {}
  std::atomic<int> remaining;
  WinkVoidBlock block;
};

class DomainCookieDeleter : public CefCookieVisitor {
 public:
  DomainCookieDeleter(NSString* domain, void (^completion)(NSInteger))
      : domain_(domain.lowercaseString), completion_([completion copy]) {}
  ~DomainCookieDeleter() override {
    NSInteger deleted = deleted_;
    auto completion = completion_;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(deleted); });
  }
  bool Visit(const CefCookie& cookie, int count, int total, bool& deleteCookie) override {
    NSString* cookieDomain = wink::ToNS(CefString(&cookie.domain)).lowercaseString;
    if ([cookieDomain hasPrefix:@"."]) cookieDomain = [cookieDomain substringFromIndex:1];
    if ([cookieDomain isEqualToString:domain_] ||
        [cookieDomain hasSuffix:[@"." stringByAppendingString:domain_]]) {
      deleteCookie = true;
      ++deleted_;
    }
    return true;
  }

 private:
  NSString* domain_;
  void (^completion_)(NSInteger);
  NSInteger deleted_ = 0;
  IMPLEMENT_REFCOUNTING(DomainCookieDeleter);
};

class CookieDomainCollector : public CefCookieVisitor {
 public:
  explicit CookieDomainCollector(void (^completion)(NSArray<NSString*>*))
      : completion_([completion copy]), domains_([NSMutableOrderedSet orderedSet]) {}
  ~CookieDomainCollector() override {
    NSArray* domains = domains_.array;
    auto completion = completion_;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(domains); });
  }
  bool Visit(const CefCookie& cookie, int count, int total, bool& deleteCookie) override {
    NSString* domain = wink::ToNS(CefString(&cookie.domain));
    if ([domain hasPrefix:@"."]) domain = [domain substringFromIndex:1];
    [domains_ addObject:domain];
    return true;
  }

 private:
  void (^completion_)(NSArray<NSString*>*);
  NSMutableOrderedSet<NSString*>* domains_;
  IMPLEMENT_REFCOUNTING(CookieDomainCollector);
};

// Counts SetCookie results; reports once every cookie has an answer.
struct ImportTally {
  ImportTally(NSInteger total, void (^done)(NSInteger, NSInteger))
      : remaining(total), done([done copy]) {}
  void Arrive(bool accepted) {
    (accepted ? imported : rejected)++;
    if (--remaining == 0 && done) {
      NSInteger acceptedCount = imported, rejectedCount = rejected;
      auto block = done;
      dispatch_async(dispatch_get_main_queue(), ^{ block(acceptedCount, rejectedCount); });
    }
  }
  std::atomic<NSInteger> remaining;
  std::atomic<NSInteger> imported{0};
  std::atomic<NSInteger> rejected{0};
  void (^done)(NSInteger, NSInteger);
};

class ImportCookieCallback : public CefSetCookieCallback {
 public:
  explicit ImportCookieCallback(std::shared_ptr<ImportTally> tally) : tally_(std::move(tally)) {}
  void OnComplete(bool success) override { tally_->Arrive(success); }

 private:
  std::shared_ptr<ImportTally> tally_;
  IMPLEMENT_REFCOUNTING(ImportCookieCallback);
};

// Chromium time: microseconds since 1601-01-01 UTC.
cef_basetime_t ToBaseTime(NSDate* date) {
  cef_basetime_t time;
  time.val = (int64_t)((date.timeIntervalSince1970 + 11644473600.0) * 1000000.0);
  return time;
}

}  // namespace

@implementation WinkCookie

- (instancetype)init {
  if ((self = [super init])) {
    _name = @"";
    _value = @"";
    _domain = @"";
    _path = @"/";
    _sameSite = -1;
    _priority = 1;
  }
  return self;
}

@end

@implementation WinkProfile {
  CefRefPtr<CefRequestContext> _context;
}

+ (WinkProfile*)defaultProfile {
  static WinkProfile* profile = nil;
  if (!profile) profile = [[WinkProfile alloc] initWithName:@"Default" ephemeral:NO];
  return profile;
}

+ (instancetype)ephemeralProfileWithName:(NSString*)name {
  return [[WinkProfile alloc] initWithName:name ephemeral:YES];
}

- (instancetype)initWithName:(NSString*)name ephemeral:(BOOL)ephemeral {
  if ((self = [super init])) {
    _name = [name copy];
    _isEphemeral = ephemeral;
  }
  return self;
}

- (CefRefPtr<CefRequestContext>)cefRequestContext {
  if (!_context) {
    if (_isEphemeral) {
      CefRequestContextSettings settings;  // empty cache_path => in-memory
      settings.persist_session_cookies = false;
      _context = CefRequestContext::CreateContext(settings, wink::SharedRequestContextHandler());
    } else {
      _context = CefRequestContext::GetGlobalContext();
    }
  }
  return _context;
}

- (BOOL)setPreference:(NSString*)name value:(id)value error:(NSString**)error {
  CefRefPtr<CefRequestContext> context = [self cefRequestContext];
  CefString cefError;
  if (!context || !context->CanSetPreference(wink::ToCef(name))) {
    if (error) *error = @"Preference is not settable";
    return NO;
  }
  bool ok = context->SetPreference(wink::ToCef(name), wink::ToCefValue(value), cefError);
  if (!ok && error) *error = wink::ToNS(cefError);
  return ok;
}

- (id)preferenceValueForName:(NSString*)name {
  CefRefPtr<CefRequestContext> context = [self cefRequestContext];
  if (!context || !context->HasPreference(wink::ToCef(name))) return nil;
  return wink::FromCefValue(context->GetPreference(wink::ToCef(name)));
}

- (void)clearBrowsingData:(WinkBrowsingDataTypes)types completion:(WinkVoidBlock)completion {
  CefRefPtr<CefRequestContext> context = [self cefRequestContext];
  int count = 0;
  if (types & WinkBrowsingDataCookies) ++count;
  if (types & WinkBrowsingDataCache) ++count;
  if (types & WinkBrowsingDataHTTPAuth) ++count;
  if (types & WinkBrowsingDataConnections) ++count;
  if (!context || count == 0) {
    if (completion) completion();
    return;
  }
  auto barrier = std::make_shared<Barrier>(count, completion ?: ^{});
  // The block captures the shared_ptr by value, keeping the barrier alive.
  WinkVoidBlock arrive = ^{
    if (--barrier->remaining == 0 && barrier->block) barrier->block();
  };
  if (types & WinkBrowsingDataCookies) {
    context->GetCookieManager(nullptr)->DeleteCookies("", "", nullptr);
    arrive();
  }
  if (types & WinkBrowsingDataCache) context->ClearHttpCache(new BlockCompletion(arrive));
  if (types & WinkBrowsingDataHTTPAuth) context->ClearHttpAuthCredentials(new BlockCompletion(arrive));
  if (types & WinkBrowsingDataConnections) context->CloseAllConnections(new BlockCompletion(arrive));
}

- (void)deleteCookiesForDomain:(NSString*)domain completion:(void (^)(NSInteger))completion {
  CefRefPtr<CefRequestContext> context = [self cefRequestContext];
  CefRefPtr<CefCookieManager> manager = context ? context->GetCookieManager(nullptr) : nullptr;
  if (!manager || !manager->VisitAllCookies(new DomainCookieDeleter(domain, completion))) {
    if (completion) completion(0);
  }
}

- (void)cookieDomainsWithCompletion:(void (^)(NSArray<NSString*>*))completion {
  CefRefPtr<CefRequestContext> context = [self cefRequestContext];
  CefRefPtr<CefCookieManager> manager = context ? context->GetCookieManager(nullptr) : nullptr;
  if (!manager || !manager->VisitAllCookies(new CookieDomainCollector(completion))) {
    completion(@[]);
  }
}

- (void)importCookies:(NSArray<WinkCookie*>*)cookies completion:(void (^)(NSInteger, NSInteger))completion {
  CefRefPtr<CefRequestContext> context = [self cefRequestContext];
  CefRefPtr<CefCookieManager> manager = context ? context->GetCookieManager(nullptr) : nullptr;
  if (!manager || cookies.count == 0) {
    NSInteger count = (NSInteger)cookies.count;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(0, count); });
    return;
  }
  auto tally = std::make_shared<ImportTally>((NSInteger)cookies.count, completion);
  NSDate* now = [NSDate date];
  for (WinkCookie* source in cookies) {
    BOOL domainCookie = [source.domain hasPrefix:@"."];
    NSString* host = domainCookie ? [source.domain substringFromIndex:1] : source.domain;
    NSString* path = [source.path hasPrefix:@"/"] ? source.path : @"/";
    // The URL a site would have set it from: its scheme decides whether a
    // Secure cookie is allowed, its host whether the domain matches.
    NSString* url = [NSString stringWithFormat:@"%@://%@%@", source.secure ? @"https" : @"http", host, path];

    CefCookie cookie;
    CefString(&cookie.name) = wink::ToCef(source.name);
    CefString(&cookie.value) = wink::ToCef(source.value);
    if (domainCookie) CefString(&cookie.domain) = wink::ToCef(source.domain);  // empty = host cookie
    CefString(&cookie.path) = wink::ToCef(path);
    cookie.secure = source.secure;
    cookie.httponly = source.httpOnly;
    cookie.creation = ToBaseTime(source.creation ?: now);
    cookie.last_access = ToBaseTime(source.lastAccess ?: source.creation ?: now);
    cookie.has_expires = source.expires != nil;
    if (source.expires) cookie.expires = ToBaseTime(source.expires);
    cookie.same_site = (cef_cookie_same_site_t)MAX(0, MIN(3, source.sameSite + 1));
    cookie.priority = (cef_cookie_priority_t)MAX(-1, MIN(1, source.priority - 1));
    if (!manager->SetCookie(wink::ToCef(url), cookie, new ImportCookieCallback(tally))) {
      tally->Arrive(false);  // invalid URL: the callback never runs
    }
  }
}

@end
