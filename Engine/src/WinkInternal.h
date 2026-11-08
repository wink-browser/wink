// Private engine glue shared between the Objective-C++ translation units.

#ifndef WINK_ENGINE_INTERNAL_H_
#define WINK_ENGINE_INTERNAL_H_

#import <Foundation/Foundation.h>
#import <WinkEngine/WinkEngine.h>

#include <string>

#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_values.h"

namespace wink {

inline NSString* ToNS(const CefString& s) {
  std::string utf8 = s.ToString();
  NSString* out = [[NSString alloc] initWithBytes:utf8.data()
                                           length:utf8.size()
                                         encoding:NSUTF8StringEncoding];
  return out ?: @"";
}

inline CefString ToCef(NSString* s) {
  return CefString(s ? std::string([s UTF8String] ?: "") : std::string());
}

CefRefPtr<CefValue> ToCefValue(id object);
id FromCefValue(CefRefPtr<CefValue> value);

// Runtime bookkeeping (main thread).
void RuntimeBrowserCreated();
void RuntimeBrowserClosed();
WinkRuntimeConfiguration* RuntimeConfiguration();

// Request-context handler shared by all profiles: applies the configured
// preferences when a context initializes and blocks trackers for requests
// that have no browser (service workers, prefetch).
CefRefPtr<CefRequestContextHandler> SharedRequestContextHandler();

// Applies WinkRuntimeConfiguration.profilePreferences to |context|.
void ApplyProfilePreferences(CefRefPtr<CefRequestContext> context);

}  // namespace wink

@interface WinkProfile (Internal)
- (CefRefPtr<CefRequestContext>)cefRequestContext;
@end

#endif  // WINK_ENGINE_INTERNAL_H_
