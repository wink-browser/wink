#import <WinkEngine/WinkWebView.h>

#import "WinkInternal.h"

#include <algorithm>
#include <atomic>
#include <deque>
#include <mutex>
#include <string>
#include <unordered_set>

#include "content_blocker.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"

using wink::ToCef;
using wink::ToNS;

@implementation WinkDownloadInfo
@end
@implementation WinkContextMenuInfo
@end
@implementation WinkNetworkEntry
@end

@interface WinkWebView ()
- (instancetype)initWithFrame:(NSRect)frame
                      profile:(WinkProfile*)profile
                   initialURL:(NSString*)url
                    popupHost:(BOOL)popupHost;
- (CefRefPtr<CefClient>)wink_client;
- (void)wink_attachBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)wink_browserWillClose;
- (void)wink_browserDidClose;
- (void)wink_popupAborted;
- (void)wink_setURL:(NSString*)url;
- (void)wink_setTitle:(NSString*)title;
- (void)wink_setLoading:(BOOL)loading back:(BOOL)back forward:(BOOL)forward;
- (void)wink_notifyBlocked:(NSInteger)total lastHost:(NSString*)host;
@end

namespace {

enum ContextCommand : int {
  kCmdOpenLinkNewTab = MENU_ID_USER_FIRST,
  kCmdOpenLinkBackground,
  kCmdCopyLink,
  kCmdOpenImage,
  kCmdCopyImageAddress,
  kCmdSearchSelection,
  kCmdAskAgent,
  kCmdAskAgentPage,
  kCmdInspect,
  kCmdViewSource,
};

WinkOpenDisposition MapDisposition(cef_window_open_disposition_t d) {
  switch (d) {
    case CEF_WOD_NEW_BACKGROUND_TAB: return WinkOpenDispositionBackgroundTab;
    case CEF_WOD_NEW_WINDOW:
    case CEF_WOD_OFF_THE_RECORD: return WinkOpenDispositionNewWindow;
    case CEF_WOD_NEW_POPUP: return WinkOpenDispositionPopup;
    case CEF_WOD_CURRENT_TAB:
    case CEF_WOD_SINGLETON_TAB:
    case CEF_WOD_SWITCH_TO_TAB: return WinkOpenDispositionCurrentTab;
    default: return WinkOpenDispositionForegroundTab;
  }
}

const char* ResourceTypeName(cef_resource_type_t type) {
  switch (type) {
    case RT_MAIN_FRAME: return "document";
    case RT_SUB_FRAME: return "subdocument";
    case RT_STYLESHEET: return "stylesheet";
    case RT_SCRIPT: return "script";
    case RT_IMAGE: return "image";
    case RT_FONT_RESOURCE: return "font";
    case RT_MEDIA: return "media";
    case RT_WORKER:
    case RT_SHARED_WORKER:
    case RT_SERVICE_WORKER: return "worker";
    case RT_PREFETCH: return "prefetch";
    case RT_FAVICON: return "favicon";
    case RT_XHR: return "fetch";
    case RT_PING: return "ping";
    case RT_CSP_REPORT: return "csp-report";
    default: return "other";
  }
}

WinkDownloadInfo* MakeDownloadInfo(CefRefPtr<CefDownloadItem> item, const CefString& suggested) {
  WinkDownloadInfo* info = [WinkDownloadInfo new];
  info.identifier = item->GetId();
  info.url = ToNS(item->GetURL());
  info.suggestedFileName = suggested.empty() ? ToNS(item->GetSuggestedFileName()) : ToNS(suggested);
  info.fullPath = ToNS(item->GetFullPath());
  info.mimeType = ToNS(item->GetMimeType());
  info.receivedBytes = item->GetReceivedBytes();
  info.totalBytes = item->GetTotalBytes();
  info.currentSpeed = item->GetCurrentSpeed();
  info.percentComplete = item->GetPercentComplete();
  info.inProgress = item->IsInProgress();
  info.complete = item->IsComplete();
  info.canceled = item->IsCanceled();
  info.interrupted = item->IsInterrupted();
  return info;
}

WinkPermissionKinds MapMediaPermissions(uint32_t mask) {
  WinkPermissionKinds kinds = 0;
  if (mask & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) kinds |= WinkPermissionMicrophone;
  if (mask & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) kinds |= WinkPermissionCamera;
  if (mask & (CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE)) {
    kinds |= WinkPermissionScreenCapture;
  }
  return kinds;
}

// Only these prompt-style permissions are ever surfaced to the user; anything
// else is denied without asking (privacy by default).
WinkPermissionKinds MapPromptPermissions(uint32_t mask, bool* unsupported) {
  WinkPermissionKinds kinds = 0;
  uint32_t known = 0;
  auto map = [&](uint32_t bit, WinkPermissionKinds kind) {
    if (mask & bit) {
      kinds |= kind;
      known |= bit;
    }
  };
  map(CEF_PERMISSION_TYPE_CAMERA_STREAM, WinkPermissionCamera);
  map(CEF_PERMISSION_TYPE_MIC_STREAM, WinkPermissionMicrophone);
  map(CEF_PERMISSION_TYPE_GEOLOCATION, WinkPermissionGeolocation);
  map(CEF_PERMISSION_TYPE_NOTIFICATIONS, WinkPermissionNotifications);
  map(CEF_PERMISSION_TYPE_CLIPBOARD, WinkPermissionClipboard);
  map(CEF_PERMISSION_TYPE_MIDI_SYSEX, WinkPermissionMIDI);
  map(CEF_PERMISSION_TYPE_STORAGE_ACCESS, WinkPermissionStorageAccess);
  map(CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, WinkPermissionStorageAccess);
  map(CEF_PERMISSION_TYPE_LOCAL_NETWORK, WinkPermissionLocalNetwork);
  map(CEF_PERMISSION_TYPE_LOOPBACK_NETWORK, WinkPermissionLocalNetwork);
  *unsupported = (mask & ~known) != 0;
  return kinds;
}

bool IsHttpsFallbackError(cef_errorcode_t code) {
  return code != ERR_ABORTED && code != ERR_BLOCKED_BY_CLIENT && code != ERR_BLOCKED_BY_RESPONSE;
}

// ---------------------------------------------------------------------------
// IO-thread request filtering: tracker blocking, HTTPS upgrades, GPC header,
// plus a bounded log of requests for agents and developers.
// ---------------------------------------------------------------------------
class WinkResourceHandler : public CefResourceRequestHandler {
 public:
  explicit WinkResourceHandler(WinkWebView* view) : view_(view) {}

  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override {
    auto& blocker = wink::ContentBlocker::Get();
    const cef_resource_type_t type = request->GetResourceType();
    std::string url = request->GetURL().ToString();
    if (type == RT_MAIN_FRAME) {
      if (url.rfind("http://", 0) == 0) {
        std::string host(wink::ContentBlocker::HostOf(url));
        if (blocker.ShouldUpgradeToHttps(host)) {
          blocker.NoteUpgraded(host);
          request->SetURL("https://" + url.substr(7));
        }
      }
    } else {
      std::string matched;
      if (blocker.ShouldBlock(url, request->GetFirstPartyForCookies().ToString(), &matched)) {
        blocked_.fetch_add(1, std::memory_order_relaxed);
        Record(url, request->GetMethod().ToString(), type, 0, 0, true, false);
        {
          std::lock_guard<std::mutex> lock(mutex_);
          blocked_ids_.insert(request->GetIdentifier());
          last_blocked_host_ = matched;
        }
        NotifyBlocked();
        return RV_CANCEL;
      }
    }
    if (blocker.gpc_enabled.load(std::memory_order_relaxed)) {
      request->SetHeaderByName("Sec-GPC", "1", true);
    }
    return RV_CONTINUE;
  }

  void OnResourceLoadComplete(CefRefPtr<CefBrowser> browser,
                              CefRefPtr<CefFrame> frame,
                              CefRefPtr<CefRequest> request,
                              CefRefPtr<CefResponse> response,
                              URLRequestStatus status,
                              int64_t received_content_length) override {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = blocked_ids_.find(request->GetIdentifier());
      if (it != blocked_ids_.end()) {
        blocked_ids_.erase(it);
        return;  // already recorded as blocked
      }
    }
    Record(request->GetURL().ToString(), request->GetMethod().ToString(),
           request->GetResourceType(), response ? response->GetStatus() : 0,
           received_content_length, false, status != UR_SUCCESS);
  }

  void OnProtocolExecution(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefRequest> request,
                           bool& allow_os_execution) override {
    static const std::string_view kAllowed[] = {
        "mailto", "tel", "sms", "facetime", "facetime-audio", "maps", "zoommtg", "zoomus",
        "msteams", "slack", "spotify", "vscode", "cursor", "claude", "itms-apps", "x-apple.systempreferences",
    };
    std::string url = request->GetURL().ToString();
    std::string_view scheme = wink::ContentBlocker::SchemeOf(url);
    allow_os_execution =
        std::find(std::begin(kAllowed), std::end(kAllowed), scheme) != std::end(kAllowed);
  }

  int BlockedCount() const { return blocked_.load(); }
  void ResetBlocked() { blocked_.store(0); }

  NSArray<WinkNetworkEntry*>* Entries() {
    std::lock_guard<std::mutex> lock(mutex_);
    NSMutableArray* out = [NSMutableArray arrayWithCapacity:entries_.size()];
    for (const auto& e : entries_) {
      WinkNetworkEntry* entry = [WinkNetworkEntry new];
      entry.url = [NSString stringWithUTF8String:e.url.c_str()] ?: @"";
      entry.method = [NSString stringWithUTF8String:e.method.c_str()] ?: @"GET";
      entry.resourceType = [NSString stringWithUTF8String:e.type] ?: @"other";
      entry.statusCode = e.status;
      entry.bytes = e.bytes;
      entry.blocked = e.blocked;
      entry.failed = e.failed;
      entry.timestamp = e.timestamp;
      [out addObject:entry];
    }
    return out;
  }

  void ClearEntries() {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.clear();
  }

 private:
  struct Entry {
    std::string url;
    std::string method;
    const char* type;
    int status;
    int64_t bytes;
    bool blocked;
    bool failed;
    double timestamp;
  };

  void Record(std::string url, std::string method, cef_resource_type_t type, int status,
              int64_t bytes, bool blocked, bool failed) {
    if (url.size() > 2048) url.resize(2048);
    std::lock_guard<std::mutex> lock(mutex_);
    entries_.push_back(Entry{std::move(url), std::move(method), ResourceTypeName(type), status, bytes,
                             blocked, failed, [NSDate date].timeIntervalSince1970});
    while (entries_.size() > kMaxEntries) entries_.pop_front();
  }

  // Coalesces "N requests blocked" UI updates to at most ~5 per second.
  void NotifyBlocked() {
    if (notify_pending_.exchange(true)) return;
    __weak WinkWebView* weak_view = view_;
    CefRefPtr<WinkResourceHandler> handler(this);  // keep alive until delivered
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      handler->notify_pending_.store(false);
      std::string host;
      {
        std::lock_guard<std::mutex> lock(handler->mutex_);
        host = handler->last_blocked_host_;
      }
      [weak_view wink_notifyBlocked:handler->blocked_.load() lastHost:ToNS(host)];
    });
  }

  static constexpr size_t kMaxEntries = 400;
  __weak WinkWebView* view_;
  std::atomic<int> blocked_{0};
  std::atomic<bool> notify_pending_{false};
  std::mutex mutex_;
  std::string last_blocked_host_;
  std::unordered_set<uint64_t> blocked_ids_;
  std::deque<Entry> entries_;
  IMPLEMENT_REFCOUNTING(WinkResourceHandler);
};

class WinkDevToolsObserver : public CefDevToolsMessageObserver {
 public:
  explicit WinkDevToolsObserver(WinkWebView* view) : view_(view) {}

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void* result,
                              size_t result_size) override {
    WinkWebView* view = view_;
    if (view.devToolsResultHandler) {
      view.devToolsResultHandler(message_id, success, [NSData dataWithBytes:result length:result_size]);
    }
  }

  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                       const CefString& method,
                       const void* params,
                       size_t params_size) override {
    WinkWebView* view = view_;
    if (!view.devToolsEventsEnabled) return;
    id<WinkWebViewDelegate> delegate = view.delegate;
    if ([delegate respondsToSelector:@selector(webView:didReceiveDevToolsEvent:params:)]) {
      [delegate webView:view
          didReceiveDevToolsEvent:ToNS(method)
                           params:[NSData dataWithBytes:params length:params_size]];
    }
  }

 private:
  __weak WinkWebView* view_;
  IMPLEMENT_REFCOUNTING(WinkDevToolsObserver);
};

// Tracks DevTools browser lifetimes so shutdown waits for them.
class DevToolsClient : public CefClient, public CefLifeSpanHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { wink::RuntimeBrowserCreated(); }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override { wink::RuntimeBrowserClosed(); }

 private:
  IMPLEMENT_REFCOUNTING(DevToolsClient);
};

class ImageCallback : public CefDownloadImageCallback {
 public:
  explicit ImageCallback(void (^completion)(NSImage*)) : completion_([completion copy]) {}
  void OnDownloadImageFinished(const CefString& image_url,
                               int http_status_code,
                               CefRefPtr<CefImage> image) override {
    NSImage* result = nil;
    if (image && !image->IsEmpty()) {
      int width = 0, height = 0;
      CefRefPtr<CefBinaryValue> png = image->GetAsPNG(2.0f, true, width, height);
      if (png && png->GetSize() > 0) {
        NSMutableData* data = [NSMutableData dataWithLength:png->GetSize()];
        png->GetData(data.mutableBytes, png->GetSize(), 0);
        result = [[NSImage alloc] initWithData:data];
      }
    }
    if (completion_) completion_(result);
    completion_ = nil;
  }

 private:
  void (^completion_)(NSImage*);
  IMPLEMENT_REFCOUNTING(ImageCallback);
};

// ---------------------------------------------------------------------------
// Per-tab CEF client. All handler methods except the resource handler run on
// the browser process UI thread (= macOS main thread).
// ---------------------------------------------------------------------------
class WinkClient : public CefClient,
                   public CefLifeSpanHandler,
                   public CefDisplayHandler,
                   public CefLoadHandler,
                   public CefRequestHandler,
                   public CefContextMenuHandler,
                   public CefDownloadHandler,
                   public CefFindHandler,
                   public CefFocusHandler,
                   public CefJSDialogHandler,
                   public CefPermissionHandler {
 public:
  explicit WinkClient(WinkWebView* view)
      : view_(view),
        resources_(new WinkResourceHandler(view)),
        pending_popups_([NSMapTable strongToWeakObjectsMapTable]) {}

  WinkResourceHandler* resources() { return resources_.get(); }

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }

  // --- CefLifeSpanHandler ---------------------------------------------------

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    WinkWebView* view = view_;
    // Popup blocker: only user-initiated popups are allowed.
    if (!view || !user_gesture) return true;
    id<WinkWebViewDelegate> delegate = view.delegate;
    if (![delegate respondsToSelector:@selector(webView:createWebViewForPopupWithURL:disposition:userGesture:)]) {
      return true;
    }
    WinkWebView* popup = [delegate webView:view
              createWebViewForPopupWithURL:ToNS(target_url)
                               disposition:MapDisposition(target_disposition)
                               userGesture:user_gesture];
    if (!popup) return true;
    NSRect bounds = popup.bounds;
    windowInfo.SetAsChild((__bridge CefWindowHandle)popup,
                          CefRect(0, 0, std::max(1, (int)NSWidth(bounds)), std::max(1, (int)NSHeight(bounds))));
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    client = [popup wink_client];
    [pending_popups_ setObject:popup forKey:@(popup_id)];
    return false;
  }

  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override {
    WinkWebView* popup = [pending_popups_ objectForKey:@(popup_id)];
    [pending_popups_ removeObjectForKey:@(popup_id)];
    [popup wink_popupAborted];
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    wink::RuntimeBrowserCreated();
    [view_ wink_attachBrowser:browser];
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // Wink owns its windows: never let CEF send performClose: to them. We
    // complete the close by tearing down the browser's view instead.
    [view_ wink_browserWillClose];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    [view_ wink_browserDidClose];
    wink::RuntimeBrowserClosed();
  }

  // --- CefDisplayHandler ----------------------------------------------------

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (frame->IsMain()) [view_ wink_setURL:ToNS(url)];
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    [view_ wink_setTitle:ToNS(title)];
  }

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& icon_urls) override {
    WinkWebView* view = view_;
    if (![view.delegate respondsToSelector:@selector(webView:didChangeFaviconURLs:)]) return;
    NSMutableArray* urls = [NSMutableArray arrayWithCapacity:icon_urls.size()];
    for (const auto& u : icon_urls) [urls addObject:ToNS(u)];
    [view.delegate webView:view didChangeFaviconURLs:urls];
  }

  void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override {
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webView:didChangeFullscreen:)]) {
      [view.delegate webView:view didChangeFullscreen:fullscreen];
    }
  }

  void OnStatusMessage(CefRefPtr<CefBrowser> browser, const CefString& value) override {
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webView:didChangeStatusText:)]) {
      [view.delegate webView:view didChangeStatusText:ToNS(value)];
    }
  }

  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString& message,
                        const CefString& source,
                        int line) override {
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webView:didLogConsoleMessage:level:source:line:)]) {
      WinkConsoleLevel mapped = WinkConsoleLevelInfo;
      if (level >= LOGSEVERITY_ERROR) mapped = WinkConsoleLevelError;
      else if (level == LOGSEVERITY_WARNING) mapped = WinkConsoleLevelWarning;
      else if (level <= LOGSEVERITY_VERBOSE && level != LOGSEVERITY_DEFAULT) mapped = WinkConsoleLevelDebug;
      [view.delegate webView:view
          didLogConsoleMessage:ToNS(message)
                         level:mapped
                        source:ToNS(source)
                          line:line];
    }
    return true;  // keep page console output out of the engine log
  }

  void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webView:didChangeProgress:)]) {
      [view.delegate webView:view didChangeProgress:progress];
    }
  }

  void OnMediaAccessChange(CefRefPtr<CefBrowser> browser,
                           bool has_video_access,
                           bool has_audio_access) override {
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webView:mediaAccessChangedVideo:audio:)]) {
      [view.delegate webView:view mediaAccessChangedVideo:has_video_access audio:has_audio_access];
    }
  }

  // --- CefLoadHandler -------------------------------------------------------

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    [view_ wink_setLoading:isLoading back:canGoBack forward:canGoForward];
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override {
    if (!frame->IsMain()) return;
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webViewDidStartMainFrameLoad:)]) {
      [view.delegate webViewDidStartMainFrameLoad:view];
    }
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override {
    if (!frame->IsMain()) return;
    std::string url = frame->GetURL().ToString();
    if (url.rfind("https://", 0) == 0) {
      wink::ContentBlocker::Get().ClearUpgraded(wink::ContentBlocker::HostOf(url));
    }
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webView:didFinishMainFrameLoadWithStatus:)]) {
      [view.delegate webView:view didFinishMainFrameLoadWithStatus:httpStatusCode];
    }
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override {
    if (!frame->IsMain() || errorCode == ERR_ABORTED) return;
    std::string url = failedUrl.ToString();
    auto& blocker = wink::ContentBlocker::Get();
    if (url.rfind("https://", 0) == 0 && IsHttpsFallbackError(errorCode)) {
      std::string host(wink::ContentBlocker::HostOf(url));
      if (blocker.WasUpgraded(host)) {
        // Our automatic HTTPS upgrade failed: remember and fall back to http.
        blocker.ClearUpgraded(host);
        blocker.AllowInsecureHost(host);
        frame->LoadURL("http://" + url.substr(8));
        return;
      }
    }
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webView:didFailLoadWithError:description:url:)]) {
      [view.delegate webView:view
          didFailLoadWithError:errorCode
                   description:ToNS(errorText)
                           url:ToNS(failedUrl)];
    }
  }

  // --- CefRequestHandler ----------------------------------------------------

  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        const CefString& target_url,
                        WindowOpenDisposition target_disposition,
                        bool user_gesture) override {
    WinkOpenDisposition disposition = MapDisposition(target_disposition);
    if (disposition == WinkOpenDispositionCurrentTab) return false;
    WinkWebView* view = view_;
    if (![view.delegate respondsToSelector:@selector(webView:openURL:disposition:)]) return false;
    [view.delegate webView:view openURL:ToNS(target_url) disposition:disposition];
    return true;
  }

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override {
    return resources_;
  }

  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString& error_string) override {
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webView:renderProcessDidTerminateWithStatus:)]) {
      [view.delegate webView:view renderProcessDidTerminateWithStatus:status];
    }
  }

  // --- CefContextMenuHandler ------------------------------------------------

  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    const int flags = params->GetTypeFlags();
    if (flags & CM_TYPEFLAG_EDITABLE) {
      // Keep Chromium's editing menu (spelling, cut/copy/paste) intact.
      model->AddSeparator();
      model->AddItem(kCmdInspect, "Inspect");
      return;
    }
    model->Clear();
    bool section = false;
    auto separate = [&] {
      if (section) model->AddSeparator();
      section = true;
    };
    if (flags & CM_TYPEFLAG_LINK) {
      separate();
      model->AddItem(kCmdOpenLinkNewTab, "Open Link in New Tab");
      model->AddItem(kCmdOpenLinkBackground, "Open Link in Background");
      model->AddItem(kCmdCopyLink, "Copy Link");
    }
    if (params->GetMediaType() == CM_MEDIATYPE_IMAGE && !params->GetSourceUrl().empty()) {
      separate();
      model->AddItem(kCmdOpenImage, "Open Image in New Tab");
      model->AddItem(kCmdCopyImageAddress, "Copy Image Address");
    }
    if (flags & CM_TYPEFLAG_SELECTION) {
      separate();
      model->AddItem(MENU_ID_COPY, "Copy");
      model->AddItem(kCmdSearchSelection, "Search the Web");
      model->AddItem(kCmdAskAgent, "Ask Wink About Selection");
    }
    if (!(flags & (CM_TYPEFLAG_LINK | CM_TYPEFLAG_SELECTION | CM_TYPEFLAG_MEDIA))) {
      separate();
      model->AddItem(MENU_ID_BACK, "Back");
      model->AddItem(MENU_ID_FORWARD, "Forward");
      model->AddItem(MENU_ID_RELOAD, "Reload");
      model->SetEnabled(MENU_ID_BACK, browser->CanGoBack());
      model->SetEnabled(MENU_ID_FORWARD, browser->CanGoForward());
      model->AddSeparator();
      model->AddItem(kCmdAskAgentPage, "Ask Wink About This Page");
    }
    separate();
    model->AddItem(kCmdViewSource, "View Page Source");
    model->AddItem(kCmdInspect, "Inspect");
  }

  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params,
                            int command_id,
                            EventFlags event_flags) override {
    WinkWebView* view = view_;
    if (!view) return false;
    if (command_id == kCmdInspect) {
      [view inspectElementAtPoint:NSMakePoint(params->GetXCoord(), params->GetYCoord())];
      return true;
    }
    WinkContextAction action;
    switch (command_id) {
      case kCmdOpenLinkNewTab: action = WinkContextActionOpenLinkInNewTab; break;
      case kCmdOpenLinkBackground: action = WinkContextActionOpenLinkInBackground; break;
      case kCmdCopyLink: action = WinkContextActionCopyLink; break;
      case kCmdOpenImage: action = WinkContextActionOpenImageInNewTab; break;
      case kCmdCopyImageAddress: action = WinkContextActionCopyImageAddress; break;
      case kCmdSearchSelection: action = WinkContextActionSearchSelection; break;
      case kCmdAskAgent:
      case kCmdAskAgentPage: action = WinkContextActionAskAgent; break;
      case kCmdViewSource: action = WinkContextActionViewSource; break;
      default: return false;  // built-in commands (back, copy, ...)
    }
    WinkContextMenuInfo* info = [WinkContextMenuInfo new];
    info.pageURL = ToNS(params->GetPageUrl());
    info.linkURL = ToNS(params->GetLinkUrl());
    info.sourceURL = ToNS(params->GetSourceUrl());
    info.selectionText = command_id == kCmdAskAgentPage ? @"" : ToNS(params->GetSelectionText());
    info.location = NSMakePoint(params->GetXCoord(), params->GetYCoord());
    if (action == WinkContextActionCopyLink || action == WinkContextActionCopyImageAddress) {
      NSString* value = action == WinkContextActionCopyLink ? info.linkURL : info.sourceURL;
      [NSPasteboard.generalPasteboard clearContents];
      [NSPasteboard.generalPasteboard setString:value forType:NSPasteboardTypeString];
      return true;
    }
    if ([view.delegate respondsToSelector:@selector(webView:performContextAction:info:)]) {
      [view.delegate webView:view performContextAction:action info:info];
    }
    return true;
  }

  // --- CefDownloadHandler ---------------------------------------------------

  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    WinkWebView* view = view_;
    if (![view.delegate respondsToSelector:@selector(webView:destinationPathForDownload:)]) return false;
    NSString* path = [view.delegate webView:view
                 destinationPathForDownload:MakeDownloadInfo(download_item, suggested_name)];
    if (!path.length) return false;
    callback->Continue(ToCef(path), false);
    return true;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webView:downloadDidUpdate:)]) {
      [view.delegate webView:view downloadDidUpdate:MakeDownloadInfo(download_item, CefString())];
    }
  }

  // --- CefFindHandler -------------------------------------------------------

  void OnFindResult(CefRefPtr<CefBrowser> browser,
                    int identifier,
                    int count,
                    const CefRect& selectionRect,
                    int activeMatchOrdinal,
                    bool finalUpdate) override {
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webView:didFindMatches:activeMatch:finalUpdate:)]) {
      [view.delegate webView:view didFindMatches:count activeMatch:activeMatchOrdinal finalUpdate:finalUpdate];
    }
  }

  // --- CefFocusHandler ------------------------------------------------------

  void OnGotFocus(CefRefPtr<CefBrowser> browser) override {
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webViewDidReceiveFocus:)]) {
      [view.delegate webViewDidReceiveFocus:view];
    }
  }

  // --- CefJSDialogHandler ---------------------------------------------------
  // While an agent controls the tab, alert/confirm/prompt/beforeunload are
  // held for the agent to answer (handle_dialog) instead of showing a native
  // alert the agent can't see and the user didn't ask for. Otherwise
  // Chromium shows its usual dialog.

  bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                  const CefString& origin_url,
                  JSDialogType dialog_type,
                  const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& suppress_message) override {
    WinkWebView* view = view_;
    if (!view.agentHandlesDialogs) return false;
    NSString* type = dialog_type == JSDIALOGTYPE_CONFIRM ? @"confirm"
                   : dialog_type == JSDIALOGTYPE_PROMPT ? @"prompt" : @"alert";
    return HoldDialog(view, callback, type, ToNS(message_text), ToNS(default_prompt_text));
  }

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString& message_text,
                            bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    WinkWebView* view = view_;
    if (!view.agentHandlesDialogs) return false;
    return HoldDialog(view, callback, @"beforeunload", ToNS(message_text), @"");
  }

  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override { DialogGone(); }
  void OnDialogClosed(CefRefPtr<CefBrowser> browser) override { DialogGone(); }

  /// Answers the held dialog. NO if none is open.
  bool AnswerDialog(bool accept, NSString* text) {
    if (!dialog_callback_) return false;
    CefRefPtr<CefJSDialogCallback> callback = dialog_callback_;
    dialog_callback_ = nullptr;
    callback->Continue(accept, ToCef(text ?: @""));
    return true;
  }

  // --- CefPermissionHandler -------------------------------------------------

  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser,
                                      CefRefPtr<CefFrame> frame,
                                      const CefString& requesting_origin,
                                      uint32_t requested_permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override {
    WinkWebView* view = view_;
    WinkPermissionKinds kinds = MapMediaPermissions(requested_permissions);
    if (!kinds || ![view.delegate respondsToSelector:@selector(webView:requestPermissions:origin:decision:)]) {
      callback->Cancel();
      return true;
    }
    [view.delegate webView:view
        requestPermissions:kinds
                    origin:ToNS(requesting_origin)
                  decision:^(BOOL allow) {
                    if (allow) callback->Continue(requested_permissions);
                    else callback->Cancel();
                  }];
    return true;
  }

  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser,
                              uint64_t prompt_id,
                              const CefString& requesting_origin,
                              uint32_t requested_permissions,
                              CefRefPtr<CefPermissionPromptCallback> callback) override {
    WinkWebView* view = view_;
    bool unsupported = false;
    WinkPermissionKinds kinds = MapPromptPermissions(requested_permissions, &unsupported);
    if (!kinds || unsupported ||
        ![view.delegate respondsToSelector:@selector(webView:requestPermissions:origin:decision:)]) {
      callback->Continue(CEF_PERMISSION_RESULT_DENY);
      return true;
    }
    [view.delegate webView:view
        requestPermissions:kinds
                    origin:ToNS(requesting_origin)
                  decision:^(BOOL allow) {
                    callback->Continue(allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
                  }];
    return true;
  }

 private:
  bool HoldDialog(WinkWebView* view, CefRefPtr<CefJSDialogCallback> callback, NSString* type,
                  NSString* message, NSString* defaultPrompt) {
    if (![view.delegate respondsToSelector:@selector(webView:javaScriptDialogOpened:message:defaultPrompt:)]) return false;
    if (dialog_callback_) dialog_callback_->Continue(false, CefString());  // one at a time
    dialog_callback_ = callback;
    [view.delegate webView:view javaScriptDialogOpened:type message:message defaultPrompt:defaultPrompt];
    return true;
  }

  void DialogGone() {
    dialog_callback_ = nullptr;
    WinkWebView* view = view_;
    if ([view.delegate respondsToSelector:@selector(webViewJavaScriptDialogClosed:)]) {
      [view.delegate webViewJavaScriptDialogClosed:view];
    }
  }

  __weak WinkWebView* view_;
  CefRefPtr<WinkResourceHandler> resources_;
  NSMapTable<NSNumber*, WinkWebView*>* pending_popups_;
  CefRefPtr<CefJSDialogCallback> dialog_callback_;
  IMPLEMENT_REFCOUNTING(WinkClient);
};

}  // namespace

// ---------------------------------------------------------------------------
// WinkWebView
// ---------------------------------------------------------------------------

@implementation WinkWebView {
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<WinkClient> _client;
  CefRefPtr<WinkDevToolsObserver> _devToolsObserver;
  CefRefPtr<CefRegistration> _devToolsRegistration;
  NSString* _pendingURL;
  BOOL _popupHost;
  BOOL _creationStarted;
  BOOL _closeRequested;
  BOOL _forceClose;
  BOOL _closed;
  BOOL _pendingMute;
  NSString* _currentURL;
  NSString* _title;
}

@synthesize profile = _profile;
@synthesize isClosing = _isClosing;
@synthesize isLoading = _isLoading;
@synthesize canGoBack = _canGoBack;
@synthesize canGoForward = _canGoForward;

- (instancetype)initWithFrame:(NSRect)frame profile:(WinkProfile*)profile initialURL:(NSString*)url {
  return [self initWithFrame:frame profile:profile initialURL:url popupHost:NO];
}

- (instancetype)initWithFrame:(NSRect)frame
                      profile:(WinkProfile*)profile
                   initialURL:(NSString*)url
                    popupHost:(BOOL)popupHost {
  if ((self = [super initWithFrame:frame])) {
    _profile = profile;
    _pendingURL = [url copy];
    _popupHost = popupHost;
    _currentURL = [url copy] ?: @"";
    _title = @"";
    _client = new WinkClient(self);
    self.autoresizesSubviews = YES;
    if (!popupHost) {
      __weak WinkWebView* weakSelf = self;
      [WinkRuntime whenContextReady:^{
        [weakSelf wink_createBrowserIfNeeded];
      }];
    }
  }
  return self;
}

+ (instancetype)webViewForPopupFromOpener:(WinkWebView*)opener {
  return [[WinkWebView alloc] initWithFrame:opener.bounds profile:opener.profile initialURL:nil popupHost:YES];
}

- (void)dealloc {
  _devToolsRegistration = nullptr;
  _devToolsObserver = nullptr;
}

- (CefRefPtr<CefClient>)wink_client {
  return _client.get();
}

- (BOOL)answerJavaScriptDialog:(BOOL)accept text:(NSString*)text {
  return _client && _client->AnswerDialog(accept, text);
}

- (void)setAgentHandlesDialogs:(BOOL)value {
  _agentHandlesDialogs = value;
  // An agent left with a dialog open: dismiss it rather than leave the page stuck.
  if (!value && _client) _client->AnswerDialog(false, nil);
}

- (BOOL)isFlipped {
  return YES;
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  for (NSView* subview in self.subviews) subview.frame = self.bounds;
}

#pragma mark - Browser lifecycle

- (void)wink_createBrowserIfNeeded {
  if (_browser || _creationStarted || _popupHost) return;
  if (_closeRequested) {
    [self wink_finishCloseWithoutBrowser];
    return;
  }
  _creationStarted = YES;
  CefWindowInfo info;
  NSRect bounds = self.bounds;
  info.SetAsChild((__bridge CefWindowHandle)self,
                  CefRect(0, 0, std::max(1, (int)NSWidth(bounds)), std::max(1, (int)NSHeight(bounds))));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  NSString* url = _pendingURL ?: @"";
  _pendingURL = nil;
  CefRefPtr<CefBrowser> browser = CefBrowserHost::CreateBrowserSync(
      info, _client.get(), ToCef(url), settings, nullptr, [_profile cefRequestContext]);
  if (browser && !_browser) [self wink_attachBrowser:browser];
}

- (void)wink_attachBrowser:(CefRefPtr<CefBrowser>)browser {
  if (_browser) return;
  _browser = browser;
  _creationStarted = YES;
  for (NSView* subview in self.subviews) {
    subview.frame = self.bounds;
    subview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
  if (_pendingURL.length) {
    _browser->GetMainFrame()->LoadURL(ToCef(_pendingURL));
    _pendingURL = nil;
  }
  if (_pendingMute) _browser->GetHost()->SetAudioMuted(true);
  if (_closeRequested) {
    _browser->GetHost()->CloseBrowser(_forceClose);
    return;
  }
  if ([self.delegate respondsToSelector:@selector(webViewDidCreateBrowser:)]) {
    [self.delegate webViewDidCreateBrowser:self];
  }
}

- (void)wink_browserWillClose {
  if (_isClosing) return;
  _isClosing = YES;
  if ([self.delegate respondsToSelector:@selector(webViewWillClose:)]) [self.delegate webViewWillClose:self];
  // Finish the close by tearing down Chromium's view on the next turn.
  dispatch_async(dispatch_get_main_queue(), ^{
    for (NSView* subview in [self.subviews copy]) [subview removeFromSuperview];
  });
}

- (void)wink_browserDidClose {
  _devToolsRegistration = nullptr;
  _devToolsObserver = nullptr;
  _browser = nullptr;
  _closed = YES;
  _isClosing = YES;
  if ([self.delegate respondsToSelector:@selector(webViewDidClose:)]) [self.delegate webViewDidClose:self];
}

- (void)wink_popupAborted {
  [self wink_finishCloseWithoutBrowser];
}

- (void)wink_finishCloseWithoutBrowser {
  if (_closed) return;
  _closed = YES;
  _isClosing = YES;
  if ([self.delegate respondsToSelector:@selector(webViewWillClose:)]) [self.delegate webViewWillClose:self];
  if ([self.delegate respondsToSelector:@selector(webViewDidClose:)]) [self.delegate webViewDidClose:self];
}

- (void)closeBrowserForce:(BOOL)force {
  if (_closed) return;
  _closeRequested = YES;
  _forceClose = _forceClose || force;
  if (_browser) {
    _browser->GetHost()->CloseBrowser(force);
  } else if (!_creationStarted && !_popupHost) {
    [self wink_finishCloseWithoutBrowser];
  }
}

- (BOOL)hasBrowser {
  return _browser != nullptr;
}

- (NSInteger)browserIdentifier {
  return _browser ? _browser->GetIdentifier() : 0;
}

#pragma mark - State

- (NSString*)currentURL {
  return _currentURL ?: @"";
}

- (NSString*)title {
  return _title ?: @"";
}

- (void)wink_setURL:(NSString*)url {
  _currentURL = [url copy];
  if ([self.delegate respondsToSelector:@selector(webView:didChangeURL:)]) {
    [self.delegate webView:self didChangeURL:url];
  }
}

- (void)wink_setTitle:(NSString*)title {
  _title = [title copy];
  if ([self.delegate respondsToSelector:@selector(webView:didChangeTitle:)]) {
    [self.delegate webView:self didChangeTitle:title];
  }
}

- (void)wink_setLoading:(BOOL)loading back:(BOOL)back forward:(BOOL)forward {
  _isLoading = loading;
  _canGoBack = back;
  _canGoForward = forward;
  if ([self.delegate respondsToSelector:@selector(webView:didChangeLoading:canGoBack:canGoForward:)]) {
    [self.delegate webView:self didChangeLoading:loading canGoBack:back canGoForward:forward];
  }
}

- (void)wink_notifyBlocked:(NSInteger)total lastHost:(NSString*)host {
  if ([self.delegate respondsToSelector:@selector(webView:didBlockRequestsTotal:lastHost:)]) {
    [self.delegate webView:self didBlockRequestsTotal:total lastHost:host];
  }
}

#pragma mark - Navigation

- (void)loadURL:(NSString*)url {
  if (_browser) {
    _browser->GetMainFrame()->LoadURL(ToCef(url));
  } else {
    _pendingURL = [url copy];
    _currentURL = [url copy];
  }
}

- (void)goBack {
  if (_browser) _browser->GoBack();
}

- (void)goForward {
  if (_browser) _browser->GoForward();
}

- (void)reload {
  if (_browser) _browser->Reload();
}

- (void)reloadIgnoringCache {
  if (_browser) _browser->ReloadIgnoreCache();
}

- (void)stopLoading {
  if (_browser) _browser->StopLoad();
}

#pragma mark - Zoom, find, tools

- (void)zoomIn {
  if (_browser) _browser->GetHost()->Zoom(CEF_ZOOM_COMMAND_IN);
}

- (void)zoomOut {
  if (_browser) _browser->GetHost()->Zoom(CEF_ZOOM_COMMAND_OUT);
}

- (void)resetZoom {
  if (_browser) _browser->GetHost()->Zoom(CEF_ZOOM_COMMAND_RESET);
}

- (double)zoomLevel {
  return _browser ? _browser->GetHost()->GetZoomLevel() : 0;
}

- (void)setZoomLevel:(double)zoomLevel {
  if (_browser) _browser->GetHost()->SetZoomLevel(zoomLevel);
}

- (void)findString:(NSString*)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext {
  if (_browser) _browser->GetHost()->Find(ToCef(text), forward, matchCase, findNext);
}

- (void)stopFindingAndClearSelection:(BOOL)clearSelection {
  if (_browser) _browser->GetHost()->StopFinding(clearSelection);
}

- (void)showDevTools {
  [self inspectElementAtPoint:NSZeroPoint];
}

- (void)inspectElementAtPoint:(NSPoint)point {
  if (!_browser) return;
  CefWindowInfo info;
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  _browser->GetHost()->ShowDevTools(info, new DevToolsClient(), CefBrowserSettings(),
                                    CefPoint((int)point.x, (int)point.y));
}

- (void)closeDevTools {
  if (_browser) _browser->GetHost()->CloseDevTools();
}

- (void)printPage {
  if (_browser) _browser->GetHost()->Print();
}

- (void)focusContent {
  if (!_browser) return;
  _browser->GetHost()->SetFocus(true);
}

- (void)exitContentFullscreen {
  if (_browser && _browser->GetHost()->IsFullscreen()) _browser->GetHost()->ExitFullscreen(true);
}

- (BOOL)isAudioMuted {
  return _browser ? _browser->GetHost()->IsAudioMuted() : _pendingMute;
}

- (void)setAudioMuted:(BOOL)audioMuted {
  _pendingMute = audioMuted;
  if (_browser) _browser->GetHost()->SetAudioMuted(audioMuted);
}

- (void)downloadImageAtURL:(NSString*)url
                 isFavicon:(BOOL)isFavicon
              maxPixelSize:(NSUInteger)maxPixelSize
                completion:(void (^)(NSImage*))completion {
  if (!_browser) {
    completion(nil);
    return;
  }
  _browser->GetHost()->DownloadImage(ToCef(url), isFavicon, (uint32_t)maxPixelSize, false,
                                     new ImageCallback(completion));
}

- (void)startDownloadOfURL:(NSString*)url {
  if (_browser) _browser->GetHost()->StartDownload(ToCef(url));
}

#pragma mark - DevTools protocol

- (BOOL)sendDevToolsMessage:(NSData*)json {
  if (!_browser) return NO;
  if (!_devToolsRegistration) {
    _devToolsObserver = new WinkDevToolsObserver(self);
    _devToolsRegistration = _browser->GetHost()->AddDevToolsMessageObserver(_devToolsObserver.get());
  }
  return _browser->GetHost()->SendDevToolsMessage(json.bytes, json.length);
}

#pragma mark - Privacy / diagnostics

- (NSInteger)blockedRequestCount {
  return _client ? _client->resources()->BlockedCount() : 0;
}

- (void)resetBlockedRequestCount {
  if (_client) _client->resources()->ResetBlocked();
}

- (NSArray<WinkNetworkEntry*>*)recentNetworkEntries {
  return _client ? _client->resources()->Entries() : @[];
}

- (void)clearNetworkEntries {
  if (_client) _client->resources()->ClearEntries();
}

@end
