#import <WinkEngine/WinkRuntime.h>

#import "WinkInternal.h"

#include <memory>
#include <vector>

#include "content_blocker.h"
#include "include/cef_app.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_command_line.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

@implementation WinkRuntimeConfiguration

- (instancetype)init {
  if ((self = [super init])) {
    _userDataPath = @"";
    _defaultProfilePath = @"";
    _disabledFeatures = @[];
    _enabledFeatures = @[];
    _switches = @{};
    _profilePreferences = @{};
    _keychainServiceName = @"Wink Safe Storage";
    _keychainAccountName = @"Wink";
  }
  return self;
}

@end

namespace {

std::unique_ptr<CefScopedLibraryLoader> g_library_loader;
WinkRuntimeConfiguration* g_configuration = nil;
BOOL g_context_ready = NO;
NSMutableArray<WinkVoidBlock>* g_ready_queue = nil;
NSInteger g_live_browsers = 0;
int g_exit_code = 0;
WinkVoidBlock g_all_closed_handler = nil;
void (^g_relaunch_handler)(NSArray<NSString*>*) = nil;

NSString* JoinFeatures(NSArray<NSString*>* features, const CefString& existing) {
  NSMutableOrderedSet<NSString*>* set = [NSMutableOrderedSet orderedSet];
  for (NSString* f in [wink::ToNS(existing) componentsSeparatedByString:@","]) {
    if (f.length) [set addObject:f];
  }
  [set addObjectsFromArray:features];
  return [set.array componentsJoinedByString:@","];
}

// Blocks tracker requests issued without a browser (service workers,
// speculative prefetch). Per-tab requests are handled in WinkWebView.mm.
class BrowserlessResourceHandler : public CefResourceRequestHandler {
 public:
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override {
    auto& blocker = wink::ContentBlocker::Get();
    std::string url = request->GetURL().ToString();
    std::string first_party = request->GetFirstPartyForCookies().ToString();
    if (blocker.ShouldBlock(url, first_party, nullptr)) return RV_CANCEL;
    if (blocker.gpc_enabled.load(std::memory_order_relaxed)) {
      request->SetHeaderByName("Sec-GPC", "1", true);
    }
    return RV_CONTINUE;
  }

 private:
  IMPLEMENT_REFCOUNTING(BrowserlessResourceHandler);
};

class WinkRequestContextHandler : public CefRequestContextHandler {
 public:
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    wink::ApplyProfilePreferences(context);
  }

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override {
    // Only used when the request has no browser; browsers supply their own.
    return browser ? nullptr : handler_;
  }

 private:
  CefRefPtr<CefResourceRequestHandler> handler_ = new BrowserlessResourceHandler();
  IMPLEMENT_REFCOUNTING(WinkRequestContextHandler);
};

class WinkBrowserApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString& process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) return;  // browser process only
    WinkRuntimeConfiguration* config = g_configuration;

    // Privacy: no background calls home, no hyperlink-auditing pings.
    command_line->AppendSwitch("disable-component-update");
    command_line->AppendSwitch("disable-domain-reliability");
    command_line->AppendSwitch("no-pings");
    command_line->AppendSwitch("disable-background-networking");
#if defined(WINK_DEV_MOCK_KEYCHAIN)
    // Ad-hoc signed dev builds change identity on every build, which would
    // trigger a Keychain prompt each launch. Release builds use the Keychain.
    command_line->AppendSwitch("use-mock-keychain");
#endif

    if (config.disabledFeatures.count) {
      command_line->AppendSwitchWithValue(
          "disable-features",
          wink::ToCef(JoinFeatures(config.disabledFeatures,
                                   command_line->GetSwitchValue("disable-features"))));
    }
    if (config.enabledFeatures.count) {
      command_line->AppendSwitchWithValue(
          "enable-features",
          wink::ToCef(JoinFeatures(config.enabledFeatures,
                                   command_line->GetSwitchValue("enable-features"))));
    }
    [config.switches enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSString* value, BOOL*) {
      if (value.length) command_line->AppendSwitchWithValue(wink::ToCef(name), wink::ToCef(value));
      else command_line->AppendSwitch(wink::ToCef(name));
    }];
  }

  void OnContextInitialized() override {
    wink::ApplyProfilePreferences(CefRequestContext::GetGlobalContext());
    g_context_ready = YES;
    NSArray<WinkVoidBlock>* queue = [g_ready_queue copy];
    [g_ready_queue removeAllObjects];
    for (WinkVoidBlock block in queue) block();
  }

  void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> command_line) override {
    if (wink::ContentBlocker::Get().gpc_enabled.load()) command_line->AppendSwitch("wink-gpc");
  }

  bool OnAlreadyRunningAppRelaunch(CefRefPtr<CefCommandLine> command_line,
                                   const CefString& current_directory) override {
    std::vector<CefString> args;
    command_line->GetArguments(args);
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    for (const auto& a : args) [out addObject:wink::ToNS(a)];
    if (g_relaunch_handler) g_relaunch_handler(out);
    return true;
  }

  CefRefPtr<CefRequestContextHandler> GetDefaultRequestContextHandler() override {
    return wink::SharedRequestContextHandler();
  }

 private:
  IMPLEMENT_REFCOUNTING(WinkBrowserApp);
};

}  // namespace

namespace wink {

void RuntimeBrowserCreated() {
  ++g_live_browsers;
}

void RuntimeBrowserClosed() {
  if (g_live_browsers > 0) --g_live_browsers;
  if (g_live_browsers == 0 && g_all_closed_handler) g_all_closed_handler();
}

WinkRuntimeConfiguration* RuntimeConfiguration() {
  return g_configuration;
}

CefRefPtr<CefRequestContextHandler> SharedRequestContextHandler() {
  static CefRefPtr<CefRequestContextHandler> handler = new WinkRequestContextHandler();
  return handler;
}

void ApplyProfilePreferences(CefRefPtr<CefRequestContext> context) {
  if (!context) return;
  NSDictionary<NSString*, id>* prefs = g_configuration.profilePreferences;
  [prefs enumerateKeysAndObjectsUsingBlock:^(NSString* name, id value, BOOL*) {
    CefString error;
    if (context->CanSetPreference(ToCef(name))) {
      if (!context->SetPreference(ToCef(name), ToCefValue(value), error)) {
        NSLog(@"[wink] preference %@ rejected: %@", name, ToNS(error));
      }
    } else {
      NSLog(@"[wink] preference %@ is not settable in this engine build", name);
    }
  }];
}

}  // namespace wink

@implementation WinkRuntime

+ (BOOL)loadEngineLibrary {
  if (g_library_loader) return YES;
  g_library_loader = std::make_unique<CefScopedLibraryLoader>();
  if (!g_library_loader->LoadInMain()) {
    g_library_loader.reset();
    return NO;
  }
  return YES;
}

+ (BOOL)startWithArgc:(int)argc
                 argv:(char* _Nullable* _Nonnull)argv
        configuration:(WinkRuntimeConfiguration*)configuration {
  g_configuration = configuration;
  g_ready_queue = [NSMutableArray array];

  CefMainArgs main_args(argc, argv);
  CefSettings settings;
  settings.no_sandbox = false;
  // Never let the command line reconfigure the engine (e.g. an attacker
  // relaunching the browser with --remote-debugging-port to steal sessions).
  settings.command_line_args_disabled = true;
  settings.remote_debugging_port = 0;
  settings.persist_session_cookies = false;
  CefString(&settings.root_cache_path) = wink::ToCef(configuration.userDataPath);
  CefString(&settings.cache_path) = wink::ToCef(configuration.defaultProfilePath);
  if (configuration.locale.length) CefString(&settings.locale) = wink::ToCef(configuration.locale);
  if (configuration.acceptLanguageList.length) {
    CefString(&settings.accept_language_list) = wink::ToCef(configuration.acceptLanguageList);
  }
  if (configuration.logFilePath.length) {
    CefString(&settings.log_file) = wink::ToCef(configuration.logFilePath);
  }
  settings.log_severity = configuration.verboseLogging ? LOGSEVERITY_INFO : LOGSEVERITY_WARNING;
  CefString(&settings.keychain_service_name) = wink::ToCef(configuration.keychainServiceName);
  CefString(&settings.keychain_account_name) = wink::ToCef(configuration.keychainAccountName);

  CefRefPtr<WinkBrowserApp> app(new WinkBrowserApp());
  if (!CefInitialize(main_args, settings, app.get(), nullptr)) {
    g_exit_code = CefGetExitCode();
    return NO;
  }
  return YES;
}

+ (int)exitCode {
  return g_exit_code;
}

+ (void)runMessageLoop {
  CefRunMessageLoop();
}

+ (void)quitMessageLoop {
  CefQuitMessageLoop();
}

+ (void)shutdown {
  CefShutdown();
}

+ (BOOL)isContextReady {
  return g_context_ready;
}

+ (void)whenContextReady:(WinkVoidBlock)block {
  if (g_context_ready) {
    block();
  } else {
    [g_ready_queue addObject:[block copy]];
  }
}

+ (NSInteger)liveBrowserCount {
  return g_live_browsers;
}

+ (WinkVoidBlock)allBrowsersClosedHandler {
  return g_all_closed_handler;
}

+ (void)setAllBrowsersClosedHandler:(WinkVoidBlock)handler {
  g_all_closed_handler = [handler copy];
}

+ (void (^)(NSArray<NSString*>*))relaunchHandler {
  return g_relaunch_handler;
}

+ (void)setRelaunchHandler:(void (^)(NSArray<NSString*>*))handler {
  g_relaunch_handler = [handler copy];
}

+ (NSString*)chromiumVersion {
  return [NSString stringWithFormat:@"%d.%d.%d.%d", CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR,
                                    CHROME_VERSION_BUILD, CHROME_VERSION_PATCH];
}

+ (NSString*)engineVersion {
  return @CEF_VERSION;
}

+ (NSString*)userAgent {
  // Chromium's reduced UA: identical to Chrome's so Wink does not stand out.
  return [NSString stringWithFormat:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                                    @"(KHTML, like Gecko) Chrome/%d.0.0.0 Safari/537.36",
                                    CHROME_VERSION_MAJOR];
}

@end
