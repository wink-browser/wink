#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Process-wide engine configuration. Set before calling +[WinkRuntime start...].
@interface WinkRuntimeConfiguration : NSObject

/// Root directory for all Chromium profile data (absolute path).
@property (nonatomic, copy) NSString *userDataPath;
/// Persistent default profile directory. Must live inside `userDataPath`.
@property (nonatomic, copy) NSString *defaultProfilePath;
/// Optional engine log file. Logging is limited to warnings unless `verboseLogging`.
@property (nonatomic, copy, nullable) NSString *logFilePath;
@property (nonatomic) BOOL verboseLogging;
/// UI locale, e.g. "en-US".
@property (nonatomic, copy, nullable) NSString *locale;
/// Comma separated Accept-Language list, e.g. "en-US,en".
@property (nonatomic, copy, nullable) NSString *acceptLanguageList;
/// Chromium features to force off / on (privacy + performance tuning).
@property (nonatomic, copy) NSArray<NSString *> *disabledFeatures;
@property (nonatomic, copy) NSArray<NSString *> *enabledFeatures;
/// Extra command-line switches (name -> value, empty string for flags).
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *switches;
/// Chromium preferences applied to every profile when it is initialized.
@property (nonatomic, copy) NSDictionary<NSString *, id> *profilePreferences;
/// Name of the Keychain item used to encrypt cookies/passwords at rest.
@property (nonatomic, copy) NSString *keychainServiceName;
@property (nonatomic, copy) NSString *keychainAccountName;

@end

typedef void (^WinkVoidBlock)(void);

/// Owns the lifetime of the Chromium engine in the browser process.
NS_SWIFT_UI_ACTOR
@interface WinkRuntime : NSObject

/// Dynamically loads the Chromium framework from the app bundle. Must be the
/// first engine call in `main`.
+ (BOOL)loadEngineLibrary;

/// Initializes Chromium. Returns NO if the process should exit early
/// (see `exitCode`). Call after `[WinkApplication sharedApplication]`.
+ (BOOL)startWithArgc:(int)argc
                 argv:(char *_Nullable *_Nonnull)argv
        configuration:(WinkRuntimeConfiguration *)configuration
    NS_SWIFT_NAME(start(argc:argv:configuration:));

@property (class, readonly) int exitCode;

/// Runs the native run loop until +quitMessageLoop.
+ (void)runMessageLoop;
+ (void)quitMessageLoop;
+ (void)shutdown;

/// YES once the global browser context is ready for browsers to be created.
@property (class, readonly) BOOL isContextReady;
/// Runs `block` once the context is ready (immediately if it already is).
+ (void)whenContextReady:(WinkVoidBlock)block;

/// Number of live browsers (tabs, popups, devtools).
@property (class, readonly) NSInteger liveBrowserCount;
/// Invoked whenever the live browser count drops to zero.
@property (class, nonatomic, copy, nullable) WinkVoidBlock allBrowsersClosedHandler;
/// Invoked when the user launches Wink again while it is already running.
@property (class, nonatomic, copy, nullable) void (^relaunchHandler)(NSArray<NSString *> *arguments);

@property (class, readonly) NSString *chromiumVersion;
@property (class, readonly) NSString *engineVersion;
@property (class, readonly) NSString *userAgent;

@end

NS_ASSUME_NONNULL_END
