// WinkEngine — Objective-C facade over the Chromium Embedded Framework.
//
// Everything Swift needs from Chromium goes through these headers. They are
// pure Objective-C (no C++), so the Swift app never sees CEF types and the
// engine can later be swapped for a full Chromium fork without UI changes.

#import <WinkEngine/WinkRuntime.h>
#import <WinkEngine/WinkApplication.h>
#import <WinkEngine/WinkProfile.h>
#import <WinkEngine/WinkWebView.h>
#import <WinkEngine/WinkContentBlocker.h>
