#import <AppKit/AppKit.h>
#import <WinkEngine/WinkProfile.h>

NS_ASSUME_NONNULL_BEGIN

@class WinkWebView;

typedef NS_ENUM(NSInteger, WinkOpenDisposition) {
  WinkOpenDispositionCurrentTab = 0,
  WinkOpenDispositionForegroundTab,
  WinkOpenDispositionBackgroundTab,
  WinkOpenDispositionNewWindow,
  WinkOpenDispositionPopup,
};

typedef NS_OPTIONS(NSUInteger, WinkPermissionKinds) {
  WinkPermissionCamera = 1 << 0,
  WinkPermissionMicrophone = 1 << 1,
  WinkPermissionScreenCapture = 1 << 2,
  WinkPermissionGeolocation = 1 << 3,
  WinkPermissionNotifications = 1 << 4,
  WinkPermissionClipboard = 1 << 5,
  WinkPermissionMIDI = 1 << 6,
  WinkPermissionStorageAccess = 1 << 7,
  WinkPermissionLocalNetwork = 1 << 8,
  WinkPermissionOther = 1 << 15,
};

typedef NS_ENUM(NSInteger, WinkContextAction) {
  WinkContextActionOpenLinkInNewTab = 1,
  WinkContextActionOpenLinkInBackground,
  WinkContextActionCopyLink,
  WinkContextActionOpenImageInNewTab,
  WinkContextActionCopyImageAddress,
  WinkContextActionSearchSelection,
  WinkContextActionAskAgent,
  WinkContextActionInspect,
  WinkContextActionViewSource,
};

typedef NS_ENUM(NSInteger, WinkConsoleLevel) {
  WinkConsoleLevelDebug = 0,
  WinkConsoleLevelInfo,
  WinkConsoleLevelWarning,
  WinkConsoleLevelError,
};

/// Snapshot of a download's progress.
@interface WinkDownloadInfo : NSObject
@property (nonatomic) uint32_t identifier;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *suggestedFileName;
@property (nonatomic, copy) NSString *fullPath;
@property (nonatomic, copy) NSString *mimeType;
@property (nonatomic) int64_t receivedBytes;
@property (nonatomic) int64_t totalBytes;
@property (nonatomic) int64_t currentSpeed;
@property (nonatomic) NSInteger percentComplete;
@property (nonatomic) BOOL inProgress;
@property (nonatomic) BOOL complete;
@property (nonatomic) BOOL canceled;
@property (nonatomic) BOOL interrupted;
@end

/// Context-menu payload forwarded to the app.
@interface WinkContextMenuInfo : NSObject
@property (nonatomic, copy) NSString *pageURL;
@property (nonatomic, copy) NSString *linkURL;
@property (nonatomic, copy) NSString *sourceURL;
@property (nonatomic, copy) NSString *selectionText;
@property (nonatomic) NSPoint location;
@end

/// One network request observed in a tab (for developer/agent tooling).
@interface WinkNetworkEntry : NSObject
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *resourceType;
@property (nonatomic) NSInteger statusCode;
@property (nonatomic) int64_t bytes;
@property (nonatomic) BOOL blocked;
@property (nonatomic) BOOL failed;
@property (nonatomic) NSTimeInterval timestamp;
@end

NS_SWIFT_UI_ACTOR
@protocol WinkWebViewDelegate <NSObject>
@optional
- (void)webViewDidCreateBrowser:(WinkWebView *)webView;
- (void)webView:(WinkWebView *)webView didChangeURL:(NSString *)url;
- (void)webView:(WinkWebView *)webView didChangeTitle:(NSString *)title;
- (void)webView:(WinkWebView *)webView didChangeFaviconURLs:(NSArray<NSString *> *)urls;
- (void)webView:(WinkWebView *)webView
    didChangeLoading:(BOOL)isLoading
           canGoBack:(BOOL)canGoBack
        canGoForward:(BOOL)canGoForward;
- (void)webView:(WinkWebView *)webView didChangeProgress:(double)progress;
- (void)webViewDidStartMainFrameLoad:(WinkWebView *)webView;
- (void)webView:(WinkWebView *)webView didFinishMainFrameLoadWithStatus:(NSInteger)httpStatus;
- (void)webView:(WinkWebView *)webView
    didFailLoadWithError:(NSInteger)errorCode
             description:(NSString *)description
                     url:(NSString *)url;
- (void)webView:(WinkWebView *)webView didChangeStatusText:(NSString *)text;
- (void)webView:(WinkWebView *)webView didChangeFullscreen:(BOOL)fullscreen;
- (void)webView:(WinkWebView *)webView
    didLogConsoleMessage:(NSString *)message
                   level:(WinkConsoleLevel)level
                  source:(NSString *)source
                    line:(NSInteger)line;

/// A page asked for a new window/tab (target=_blank, window.open). Return an
/// unattached web view (created with +webViewForPopup...) to host it while
/// keeping the opener relationship, or nil to block it.
- (nullable WinkWebView *)webView:(WinkWebView *)webView
    createWebViewForPopupWithURL:(NSString *)url
                     disposition:(WinkOpenDisposition)disposition
                     userGesture:(BOOL)userGesture;
/// The user asked to open a link elsewhere (⌘-click, middle-click).
- (void)webView:(WinkWebView *)webView
    openURL:(NSString *)url
    disposition:(WinkOpenDisposition)disposition;

/// The browser is closing (tab close, window.close()). Remove it from the UI.
- (void)webViewWillClose:(WinkWebView *)webView;
/// The underlying browser is gone; the view can be released.
- (void)webViewDidClose:(WinkWebView *)webView;
- (void)webView:(WinkWebView *)webView renderProcessDidTerminateWithStatus:(NSInteger)status;
- (void)webView:(WinkWebView *)webView
    didFindMatches:(NSInteger)count
       activeMatch:(NSInteger)activeMatch
       finalUpdate:(BOOL)finalUpdate;
- (void)webView:(WinkWebView *)webView didBlockRequestsTotal:(NSInteger)totalBlocked lastHost:(NSString *)host;
- (void)webView:(WinkWebView *)webView
    requestPermissions:(WinkPermissionKinds)kinds
                origin:(NSString *)origin
              decision:(void (^)(BOOL allow))decision;
- (nullable NSString *)webView:(WinkWebView *)webView
    destinationPathForDownload:(WinkDownloadInfo *)download;
- (void)webView:(WinkWebView *)webView downloadDidUpdate:(WinkDownloadInfo *)download;
- (void)webView:(WinkWebView *)webView
    performContextAction:(WinkContextAction)action
                    info:(WinkContextMenuInfo *)info;
- (void)webView:(WinkWebView *)webView mediaAccessChangedVideo:(BOOL)video audio:(BOOL)audio;
- (void)webViewDidReceiveFocus:(WinkWebView *)webView;
/// Raw Chrome DevTools Protocol event (only when `devToolsEventsEnabled`).
- (void)webView:(WinkWebView *)webView
    didReceiveDevToolsEvent:(NSString *)method
                     params:(NSData *)paramsJSON;
@end

/// A single Chromium browser hosted in an NSView. One per tab.
NS_SWIFT_UI_ACTOR
@interface WinkWebView : NSView

- (instancetype)initWithFrame:(NSRect)frame
                      profile:(WinkProfile *)profile
                   initialURL:(nullable NSString *)url;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// An unattached view used to host a popup requested by `opener`.
+ (instancetype)webViewForPopupFromOpener:(WinkWebView *)opener;

@property (nonatomic, weak, nullable) id<WinkWebViewDelegate> delegate;
@property (nonatomic, readonly) WinkProfile *profile;
@property (nonatomic, readonly) NSInteger browserIdentifier;
@property (nonatomic, readonly) BOOL hasBrowser;
@property (nonatomic, readonly) BOOL isClosing;

@property (nonatomic, readonly, copy) NSString *currentURL;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;

- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;

- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;
@property (nonatomic) double zoomLevel;

- (void)findString:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;
- (void)stopFindingAndClearSelection:(BOOL)clearSelection;

- (void)showDevTools;
- (void)inspectElementAtPoint:(NSPoint)point;
- (void)closeDevTools;
- (void)printPage;
- (void)focusContent;
/// Leaves HTML5 element fullscreen (e.g. when the window exits fullscreen).
- (void)exitContentFullscreen;
@property (nonatomic, getter=isAudioMuted) BOOL audioMuted;

/// Begins closing the browser. JavaScript unload handlers run unless `force`.
- (void)closeBrowserForce:(BOOL)force;

/// Downloads an image through the tab's network context (favicons).
- (void)downloadImageAtURL:(NSString *)url
                 isFavicon:(BOOL)isFavicon
               maxPixelSize:(NSUInteger)maxPixelSize
                completion:(void (^)(NSImage *_Nullable image))completion;
- (void)startDownloadOfURL:(NSString *)url;

// --- Chrome DevTools Protocol (agent automation) ---------------------------

/// Sends a raw CDP message: {"id": N, "method": "...", "params": {...}}.
- (BOOL)sendDevToolsMessage:(NSData *)json;
/// Receives results for messages sent with -sendDevToolsMessage:.
@property (nonatomic, copy, nullable) void (^devToolsResultHandler)(NSInteger messageId, BOOL success, NSData *result);
/// When YES, CDP events are forwarded to the delegate.
@property (nonatomic) BOOL devToolsEventsEnabled;

// --- Privacy / diagnostics --------------------------------------------------

@property (nonatomic, readonly) NSInteger blockedRequestCount;
- (void)resetBlockedRequestCount;
/// Most recent network requests (bounded ring buffer), oldest first.
- (NSArray<WinkNetworkEntry *> *)recentNetworkEntries;
- (void)clearNetworkEntries;

@end

NS_ASSUME_NONNULL_END
