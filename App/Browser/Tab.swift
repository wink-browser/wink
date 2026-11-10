import AppKit
import Observation
import WinkEngine

enum TabProfileKind: String, Codable {
    case standard
    case privateBrowsing
    case agentIsolated
}

struct ConsoleEntry {
    let level: WinkConsoleLevel
    let message: String
    let source: String
    let line: Int
    let timestamp: Date
}

struct LoadFailure: Equatable {
    let code: Int
    let description: String
    let url: String
}

/// Window-level owner of a tab; receives events that affect the tab strip.
@MainActor
protocol TabHost: AnyObject {
    func tab(_ tab: Tab, createPopupFor url: String, disposition: WinkOpenDisposition) -> WinkWebView?
    func tab(_ tab: Tab, open url: String, disposition: WinkOpenDisposition)
    func tabWillClose(_ tab: Tab)
    func tab(_ tab: Tab, didRequestFullscreen fullscreen: Bool)
    func tab(_ tab: Tab, requestPermissions kinds: WinkPermissionKinds, origin: String,
             decision: @escaping (Bool) -> Void)
    func tab(_ tab: Tab, contextAction action: WinkContextAction, info: WinkContextMenuInfo)
    func tabDidNavigate(_ tab: Tab)
}

/// A browser tab. Owns (at most) one Chromium view; a tab without a view is
/// "asleep" (discarded) and is recreated on demand from its URL.
@MainActor
@Observable
final class Tab: NSObject, Identifiable, WinkWebViewDelegate {
    let id: UUID
    var url: String
    var title: String
    var favicon: NSImage?
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var isPinned: Bool
    var blockedCount = 0
    var lastBlockedHost = ""
    var hasCrashed = false
    var statusText = ""
    var isCapturingMedia = false
    var isAudioMuted = false {
        didSet { webView?.isAudioMuted = isAudioMuted }
    }
    var findMatches = 0
    var findActiveMatch = 0
    var loadFailure: LoadFailure?
    var lastActive = Date()
    var isAsleep = true
    var isClosing = false
    /// Close requested by the user; hidden while unload handlers run.
    var closeRequested = false
    let profileKind: TabProfileKind

    // Agent state — surfaced in the UI so the user always sees agent activity.
    var agentOwnerID: UUID?
    var agentOwnerName: String?
    /// What the agent is doing right now ("Clicking “Send”"); nil between steps.
    var agentAction: String?
    /// An agent is working in this tab (stays on while it thinks between steps).
    var agentActive = false
    /// The session that acted here most recently.
    var agentSessionID: UUID?
    var sharedWithAgents = false
    /// Image pixels per CSS pixel of the agent's last viewport screenshot, so
    /// coordinates read off that image map back to the page.
    @ObservationIgnored var agentScreenshotScale: Double = 1
    /// When the last main-frame load finished (agents wait on navigations).
    @ObservationIgnored var lastLoadFinished: Date?

    @ObservationIgnored weak var host: TabHost?
    @ObservationIgnored private(set) var webView: WinkWebView?
    @ObservationIgnored let profile: WinkProfile
    @ObservationIgnored var console = RingBuffer<ConsoleEntry>(capacity: 400)
    @ObservationIgnored private var faviconURL: String?
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var loadWaiters: [(Bool) -> Void] = []
    @ObservationIgnored private var browserWaiters: [() -> Void] = []
    @ObservationIgnored private var _cdp: CDPSession?
    /// Dialogs, network details and recorded steps while agents use this tab.
    @ObservationIgnored lazy var instruments = AgentInstruments(tab: self)

    var cdp: CDPSession {
        if let existing = _cdp { return existing }
        let session = CDPSession(tab: self)
        _cdp = session
        return session
    }

    var isPrivate: Bool { profileKind == .privateBrowsing }
    var host_: String { Site.host(of: url) }
    var displayTitle: String {
        if !title.isEmpty { return title }
        if url.isEmpty || url == "about:blank" { return "New Tab" }
        return URLInput.display(url)
    }

    init(url: String, title: String = "", isPinned: Bool = false, profile: WinkProfile,
         profileKind: TabProfileKind = .standard, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.profile = profile
        self.profileKind = profileKind
        super.init()
    }

    // MARK: - Engine view lifecycle

    /// Returns the live Chromium view, creating (or waking) it if needed.
    @discardableResult
    func ensureWebView(frame: NSRect) -> WinkWebView {
        if let webView { return webView }
        let view = WinkWebView(frame: frame, profile: profile, initialURL: url.isEmpty ? nil : url)
        attach(view)
        return view
    }

    /// Adopts a view created by the engine for a popup (keeps window.opener).
    func adoptPopupView(_ view: WinkWebView) {
        attach(view)
    }

    private func attach(_ view: WinkWebView) {
        view.delegate = self
        view.isAudioMuted = isAudioMuted
        webView = view
        isAsleep = false
        hasCrashed = false
    }

    /// Discards the Chromium view to free memory; the tab remains in the UI.
    func sleep() {
        guard let webView, !isClosing else { return }
        sleeping = true
        self.webView = nil
        isAsleep = true
        isLoading = false
        _cdp?.reset()
        webView.delegate = nil
        webView.closeBrowserForce(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { webView.removeFromSuperview() }
        sleeping = false
    }

    /// Starts closing the tab; the host removes it in `tabWillClose`.
    func close() {
        guard !isClosing else { return }
        closeRequested = true
        if let webView {
            webView.closeBrowserForce(false)
        } else {
            isClosing = true
            host?.tabWillClose(self)
        }
    }

    func load(_ urlString: String) {
        url = urlString
        loadFailure = nil
        if let webView { webView.loadURL(urlString) }
    }

    func reload() {
        if hasCrashed || webView == nil {
            hasCrashed = false
            webView?.loadURL(url)
        } else {
            webView?.reload()
        }
    }

    // MARK: - Waiting (used by agent tools)

    /// Calls back once the current navigation finishes (or immediately if idle).
    func waitForLoad(timeout: TimeInterval = 30, _ completion: @escaping (Bool) -> Void) {
        if !isLoading && webView?.hasBrowser == true { completion(true); return }
        var done = false
        let finish: (Bool) -> Void = { ok in
            guard !done else { return }
            done = true
            completion(ok)
        }
        loadWaiters.append(finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    func whenBrowserReady(_ block: @escaping () -> Void) {
        if webView?.hasBrowser == true { block() } else { browserWaiters.append(block) }
    }

    // MARK: - WinkWebViewDelegate

    func webViewDidCreateBrowser(_ webView: WinkWebView) {
        let waiters = browserWaiters
        browserWaiters.removeAll()
        waiters.forEach { $0() }
    }

    func webView(_ webView: WinkWebView, didChangeURL url: String) {
        self.url = url
        host?.tabDidNavigate(self)
    }

    func webView(_ webView: WinkWebView, didChangeTitle title: String) {
        self.title = title
        if !isPrivate && agentOwnerID == nil { HistoryStore.shared.updateTitle(title, for: url) }
    }

    func webView(_ webView: WinkWebView, didChangeFaviconURLs urls: [String]) {
        guard let best = urls.first, best != faviconURL else { return }
        faviconURL = best
        let host = Site.host(of: url)
        webView.downloadImage(atURL: best, isFavicon: true, maxPixelSize: 64) { [weak self] image in
            guard let self, let image else { return }
            self.favicon = image
            if !self.isPrivate { FaviconCache.shared.store(image, for: host) }
        }
    }

    func webView(_ webView: WinkWebView, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        if !isLoading {
            progress = 1
            lastLoadFinished = Date()
            let waiters = loadWaiters
            loadWaiters.removeAll()
            waiters.forEach { $0(true) }
        }
    }

    func webView(_ webView: WinkWebView, didChangeProgress progress: Double) {
        self.progress = progress
    }

    func webViewDidStartMainFrameLoad(_ webView: WinkWebView) {
        loadFailure = nil
        hasCrashed = false
        blockedCount = 0
        webView.resetBlockedRequestCount()
        _cdp?.invalidateIsolatedWorld()
        if favicon == nil || Site.host(of: url) != Site.host(of: faviconURL ?? "") {
            favicon = FaviconCache.shared.image(for: Site.host(of: url))
        }
    }

    func webView(_ webView: WinkWebView, didFinishMainFrameLoadWithStatus httpStatus: Int) {
        // Only the user's own browsing becomes history — never private or agent tabs.
        if !isPrivate, profileKind == .standard, agentOwnerID == nil {
            HistoryStore.shared.recordVisit(url: url, title: title)
        }
    }

    func webView(_ webView: WinkWebView, didFailLoadWithError errorCode: Int, description: String, url: String) {
        loadFailure = LoadFailure(code: errorCode, description: description, url: url)
    }

    func webView(_ webView: WinkWebView, didChangeStatusText text: String) {
        statusText = text
    }

    func webView(_ webView: WinkWebView, didChangeFullscreen fullscreen: Bool) {
        host?.tab(self, didRequestFullscreen: fullscreen)
    }

    func webView(_ webView: WinkWebView, didLogConsoleMessage message: String, level: WinkConsoleLevel,
                 source: String, line: Int) {
        console.append(ConsoleEntry(level: level, message: message, source: source, line: line, timestamp: Date()))
    }

    func webView(_ webView: WinkWebView, createWebViewForPopupWithURL url: String,
                 disposition: WinkOpenDisposition, userGesture: Bool) -> WinkWebView? {
        host?.tab(self, createPopupFor: url, disposition: disposition)
    }

    func webView(_ webView: WinkWebView, openURL url: String, disposition: WinkOpenDisposition) {
        host?.tab(self, open: url, disposition: disposition)
    }

    func webViewWillClose(_ webView: WinkWebView) {
        guard webView === self.webView, !sleeping else { return }
        isClosing = true
        host?.tabWillClose(self)
    }

    func webViewDidClose(_ webView: WinkWebView) {
        webView.removeFromSuperview()
        if webView === self.webView { self.webView = nil }
    }

    func webView(_ webView: WinkWebView, renderProcessDidTerminateWithStatus status: Int) {
        hasCrashed = true
        isLoading = false
    }

    func webView(_ webView: WinkWebView, didFindMatches count: Int, activeMatch: Int, finalUpdate: Bool) {
        findMatches = count
        findActiveMatch = activeMatch
    }

    func webView(_ webView: WinkWebView, didBlockRequestsTotal totalBlocked: Int, lastHost host: String) {
        blockedCount = totalBlocked
        lastBlockedHost = host
        PrivacyStats.shared.recordBlocked(host: host)
    }

    func webView(_ webView: WinkWebView, requestPermissions kinds: WinkPermissionKinds, origin: String,
                 decision: @escaping (Bool) -> Void) {
        guard let host else { decision(false); return }
        host.tab(self, requestPermissions: kinds, origin: origin, decision: decision)
    }

    func webView(_ webView: WinkWebView, destinationPathForDownload download: WinkDownloadInfo) -> String? {
        DownloadManager.shared.destination(for: download)
    }

    func webView(_ webView: WinkWebView, downloadDidUpdate download: WinkDownloadInfo) {
        DownloadManager.shared.update(download)
    }

    func webView(_ webView: WinkWebView, perform action: WinkContextAction, info: WinkContextMenuInfo) {
        host?.tab(self, contextAction: action, info: info)
    }

    func webView(_ webView: WinkWebView, mediaAccessChangedVideo video: Bool, audio: Bool) {
        isCapturingMedia = video || audio
    }

    func webView(_ webView: WinkWebView, javaScriptDialogOpened type: String, message: String, defaultPrompt: String) {
        instruments.dialogOpened(type: type, message: message, defaultPrompt: defaultPrompt)
        // No agent at work here right now (paused, or gone): ask the user in
        // Wink's own prompt card rather than leave the page waiting.
        let session = AgentHub.shared.session(withID: agentSessionID ?? agentOwnerID)
        guard session == nil || session!.isPaused || session!.isStopped else { return }
        let title = type == "beforeunload" ? "Leave this page?" : "\(Site.host(of: url).isEmpty ? "This page" : Site.host(of: url)) says"
        let options = type == "alert" ? ["OK"] : type == "beforeunload" ? ["Stay", "Leave"] : ["Cancel", "OK"]
        Task { @MainActor [weak self, weak webView] in
            let choice = await AgentHub.shared.prompt(symbol: "exclamationmark.bubble", title: title, message: message,
                                                      options: options, tab: self)
            let accept = type == "alert" || choice == 1
            _ = webView?.answerJavaScriptDialog(accept, text: accept ? defaultPrompt : nil)
            self?.instruments.dialogHandled()
        }
    }

    func webViewJavaScriptDialogClosed(_ webView: WinkWebView) {
        instruments.dialogClosed()
    }

    func webView(_ webView: WinkWebView, didReceiveDevToolsEvent method: String, params paramsJSON: Data) {
        _cdp?.handleEvent(method: method, params: paramsJSON)
    }
}
