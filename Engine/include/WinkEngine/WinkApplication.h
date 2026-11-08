#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// NSApplication subclass required by Chromium (implements CefAppProtocol).
/// Set as NSPrincipalClass and touch `WinkApplication.shared` before any
/// other NSApp access.
@interface WinkApplication : NSApplication

/// Called instead of the default -terminate: so open browsers can be closed
/// before the engine shuts down. The handler must eventually call
/// +[WinkRuntime quitMessageLoop].
@property (nonatomic, copy, nullable) void (^terminationHandler)(void);

@end

NS_ASSUME_NONNULL_END
