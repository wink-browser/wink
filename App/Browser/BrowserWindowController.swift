import AppKit
import WinkEngine

/// One browser window: owns its tabs, the view hierarchy and every
/// tab-strip level action.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, TabHost {
    let state: BrowserWindowState
    private(set) var root: BrowserRootView!
    private var closedTabs: [(url: String, title: String, index: Int)] = []
    private var closingWindow = false
    private var enteredFullscreenForContent = false
    private var grantedPermissions: [String: Bool] = [:]

    var activeTab: Tab? { state.activeTab }

    init(state: BrowserWindowState, frame: NSRect? = nil) {
        self.state = state
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1440, screen.width * 0.86), height: min(940, screen.height * 0.9))
        let defaultFrame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                                  width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame ?? defaultFrame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 560, height: 400)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = .windowBackgroundColor
        if frame == nil { window.setFrame(defaultFrame, display: false) }
        if DebugDriver.isHeadless {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        }
        super.init(window: window)
        window.delegate = self
        root = BrowserRootView(controller: self)
        window.contentView = root
        window.title = state.isPrivate ? "Private" : "Wink"
        updateTrafficLights()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Tabs

    @discardableResult
    func newTab(url: String?, activate: Bool = true, after anchor: Tab? = nil, pinned: Bool = false,
                profile: WinkProfile? = nil, profileKind: TabProfileKind? = nil) -> Tab {
        let kind = profileKind ?? (state.isPrivate ? .privateBrowsing : .standard)
        let tab = Tab(url: url ?? "", isPinned: pinned, profile: profile ?? state.defaultProfile, profileKind: kind)
        tab.host = self
        tab.favicon = FaviconCache.shared.image(for: Site.host(of: tab.url))
        insert(tab, after: anchor)
        if activate {
            select(tab)
        } else if !(url ?? "").isEmpty {
            // Background tabs start loading right away (like ⌘-click in Safari).
            root.content.attach(tab, visible: false)
        }
        SessionStore.shared.scheduleSave()
        return tab
    }

    private func insert(_ tab: Tab, after anchor: Tab?) {
        if let anchor, let index = state.tabs.firstIndex(where: { $0.id == anchor.id }) {
            state.tabs.insert(tab, at: index + 1)
        } else {
            state.tabs.append(tab)
        }
    }

    func select(_ tab: Tab) {
        guard state.tabs.contains(where: { $0.id == tab.id }) else { return }
        let previous = state.activeTab
        previous?.lastActive = Date()
        state.activeTabID = tab.id
        tab.lastActive = Date()
        state.findBarVisible = false
        root.content.show(tab)
        window?.title = tab.displayTitle
        if window?.isKeyWindow == true, !CommandBarController.shared.isVisible {
            tab.webView?.focusContent()
        }
        SessionStore.shared.scheduleSave()
    }

    func selectTab(atSidebarIndex index: Int) {
        let ordered = state.orderedTabs
        guard !ordered.isEmpty else { return }
        select(index >= 8 ? ordered[ordered.count - 1] : ordered[min(index, ordered.count - 1)])
    }

    func selectAdjacentTab(offset: Int) {
        let ordered = state.orderedTabs
        guard let active = state.activeTab, let index = ordered.firstIndex(where: { $0.id == active.id }),
              ordered.count > 1 else { return }
        select(ordered[(index + offset + ordered.count) % ordered.count])
    }

    func closeTab(_ tab: Tab) {
        if tab.id == state.activeTabID { selectNeighbor(of: tab) }
        tab.close()
        // If an unload dialog keeps the page open, bring the tab back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak tab] in
            guard let self, let tab, !tab.isClosing, tab.closeRequested else { return }
            tab.closeRequested = false
            self.select(tab)
        }
    }

    func closeActiveTab() {
        if let tab = state.activeTab { closeTab(tab) } else { window?.performClose(nil) }
    }

    private func selectNeighbor(of tab: Tab) {
        let ordered = state.orderedTabs
        guard let index = ordered.firstIndex(where: { $0.id == tab.id }) else { return }
        let candidates = ordered.filter { $0.id != tab.id }
        guard !candidates.isEmpty else {
            state.activeTabID = nil
            root.content.show(nil)
            window?.title = "Wink"
            return
        }
        select(candidates[min(index, candidates.count - 1)])
    }

    func reopenClosedTab() {
        guard let last = closedTabs.popLast() else { return }
        let tab = newTab(url: last.url, activate: true)
        if let index = state.tabs.firstIndex(where: { $0.id == tab.id }) {
            state.tabs.remove(at: index)
            state.tabs.insert(tab, at: min(last.index, state.tabs.count))
        }
    }

    func togglePin(_ tab: Tab) {
        tab.isPinned.toggle()
        SessionStore.shared.scheduleSave()
    }

    func moveTab(_ tab: Tab, before target: Tab) {
        guard tab.id != target.id, let from = state.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        state.tabs.remove(at: from)
        let to = state.tabs.firstIndex(where: { $0.id == target.id }) ?? state.tabs.count
        state.tabs.insert(tab, at: to)
        if target.isPinned != tab.isPinned { tab.isPinned = target.isPinned }
        SessionStore.shared.scheduleSave()
    }

    func duplicate(_ tab: Tab) {
        newTab(url: tab.url, activate: true, after: tab)
    }

    func closeOtherTabs(except keep: Tab) {
        for tab in state.tabs where tab.id != keep.id && !tab.isPinned { tab.close() }
    }

    // MARK: - Navigation

    /// Opens what the user typed in the command bar.
    func open(_ input: String, inNewTab: Bool) {
        let target = URLInput.resolve(input, searchEngine: WinkSettings.shared.searchEngine)
        guard !target.isEmpty else { return }
        if inNewTab || state.activeTab == nil {
            newTab(url: target, activate: true)
        } else if let tab = state.activeTab {
            tab.load(target)
            if tab.webView == nil { root.content.show(tab) }
            tab.webView?.focusContent()
        }
    }

    func goBack() { state.activeTab?.webView?.goBack() }
    func goForward() { state.activeTab?.webView?.goForward() }
    func reload() { state.activeTab?.reload() }
    func reloadIgnoringCache() { state.activeTab?.webView?.reloadIgnoringCache() }
    func stopLoading() { state.activeTab?.webView?.stopLoading() }

    func toggleSidebar() {
        state.sidebarVisible.toggle()
        state.sidebarPeeking = false
        WinkSettings.shared.sidebarVisible = state.sidebarVisible
        root.animateLayout()
        updateTrafficLights()
    }

    func toggleAgentPanel(focus: Bool = true) {
        state.agentPanelVisible.toggle()
        root.animateLayout()
        if state.agentPanelVisible && focus { root.focusAgentComposer() }
    }

    func showAgentPanel(prefill: String? = nil) {
        if !state.agentPanelVisible {
            state.agentPanelVisible = true
            root.animateLayout()
        }
        if let prefill { AgentPanelModel.shared.draft = prefill }
        root.focusAgentComposer()
    }

    /// Traffic lights live in the sidebar; they hide with it (Arc-style).
    func updateTrafficLights() {
        let visible = (state.sidebarVisible || state.sidebarPeeking) && !state.contentFullscreen
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(type)?.isHidden = !visible
        }
    }

    // MARK: - Find

    func showFindBar() {
        guard state.activeTab != nil else { return }
        state.findBarVisible = true
        root.content.focusFindField()
    }

    func find(_ text: String, forward: Bool = true, next: Bool = false) {
        guard let webView = state.activeTab?.webView else { return }
        if text.isEmpty {
            webView.stopFindingAndClearSelection(true)
            state.activeTab?.findMatches = 0
        } else {
            webView.find(text, forward: forward, matchCase: false, findNext: next)
        }
    }

    func closeFindBar() {
        state.findBarVisible = false
        state.activeTab?.webView?.stopFindingAndClearSelection(false)
        state.activeTab?.webView?.focusContent()
    }

    // MARK: - Prompts (site permissions & agent consent)

    func enqueuePrompt(_ prompt: PromptRequest) {
        state.prompts.append(prompt)
        if let tabID = prompt.tabID, let tab = state.tabs.first(where: { $0.id == tabID }), tab.id != state.activeTabID {
            select(tab)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func resolvePrompt(_ prompt: PromptRequest) {
        state.prompts.removeAll { $0.id == prompt.id }
    }

    // MARK: - TabHost

    func tab(_ tab: Tab, createPopupFor url: String, disposition: WinkOpenDisposition) -> WinkWebView? {
        guard let opener = tab.webView else { return nil }
        let popupView = WinkWebView(forPopupFromOpener: opener)
        let popup = Tab(url: url, profile: tab.profile, profileKind: tab.profileKind)
        popup.host = self
        popup.agentOwnerID = tab.agentOwnerID
        popup.agentOwnerName = tab.agentOwnerName
        popup.adoptPopupView(popupView)
        insert(popup, after: tab)
        root.content.attach(popup, visible: false)
        if disposition != .backgroundTab && shouldFocusNewTab(from: tab) { select(popup) }
        return popupView
    }

    /// Tabs spawned by an agent working in the background never steal focus.
    private func shouldFocusNewTab(from opener: Tab) -> Bool {
        opener.agentOwnerID == nil || opener.id == state.activeTabID
    }

    func tab(_ tab: Tab, open url: String, disposition: WinkOpenDisposition) {
        let created = newTab(url: url, activate: disposition != .backgroundTab && shouldFocusNewTab(from: tab), after: tab,
                             profile: tab.profile, profileKind: tab.profileKind)
        created.agentOwnerID = tab.agentOwnerID
        created.agentOwnerName = tab.agentOwnerName
    }

    func tabWillClose(_ tab: Tab) {
        guard let index = state.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.id == state.activeTabID { selectNeighbor(of: tab) }
        if !state.isPrivate, HistoryStore.isRecordable(tab.url) {
            closedTabs.append((tab.url, tab.title, index))
            if closedTabs.count > 25 { closedTabs.removeFirst() }
        }
        state.tabs.remove(at: index)
        state.prompts.removeAll { $0.tabID == tab.id }
        AgentHub.shared.tabDidClose(tab)
        SessionStore.shared.scheduleSave()
        if closingWindow && state.tabs.isEmpty { finishClosingWindow() }
    }

    func tab(_ tab: Tab, didRequestFullscreen fullscreen: Bool) {
        guard tab.id == state.activeTabID, let window else { return }
        state.contentFullscreen = fullscreen
        updateTrafficLights()
        let isWindowFullscreen = window.styleMask.contains(.fullScreen)
        if fullscreen && !isWindowFullscreen {
            enteredFullscreenForContent = true
            window.toggleFullScreen(nil)
        } else if !fullscreen && isWindowFullscreen && enteredFullscreenForContent {
            enteredFullscreenForContent = false
            window.toggleFullScreen(nil)
        }
        root.needsLayout = true
    }

    func tab(_ tab: Tab, requestPermissions kinds: WinkPermissionKinds, origin: String,
             decision: @escaping (Bool) -> Void) {
        let key = "\(origin)|\(kinds.rawValue)"
        if let remembered = grantedPermissions[key] { decision(remembered); return }
        let site = URLInput.display(origin)
        let description = PermissionText.describe(kinds)
        var resolved = false
        var prompt: PromptRequest!
        let finish: (Bool) -> Void = { [weak self] allow in
            guard !resolved else { return }
            resolved = true
            self?.grantedPermissions[key] = allow
            self?.resolvePrompt(prompt)
            decision(allow)
        }
        prompt = PromptRequest(symbol: PermissionText.symbol(kinds), title: "\(site) wants to \(description)",
                               message: "Allowed for this session only.", tabID: tab.id, buttons: [
                                   .init(title: "Don't Allow", role: .cancel) { finish(false) },
                                   .init(title: "Allow", role: .primary) { finish(true) },
                               ])
        enqueuePrompt(prompt)
    }

    func tab(_ tab: Tab, contextAction action: WinkContextAction, info: WinkContextMenuInfo) {
        switch action {
        case .openLinkInNewTab:
            newTab(url: info.linkURL, activate: true, after: tab, profile: tab.profile, profileKind: tab.profileKind)
        case .openLinkInBackground:
            newTab(url: info.linkURL, activate: false, after: tab, profile: tab.profile, profileKind: tab.profileKind)
        case .openImageInNewTab:
            newTab(url: info.sourceURL, activate: true, after: tab, profile: tab.profile, profileKind: tab.profileKind)
        case .searchSelection:
            newTab(url: WinkSettings.shared.searchEngine.searchURL(for: info.selectionText), activate: true, after: tab)
        case .askAgent:
            let selection = info.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
            showAgentPanel(prefill: selection.isEmpty
                ? "Summarize this page."
                : "Explain this from the page:\n\n\"\(selection.prefix(2000))\"")
        case .viewSource:
            newTab(url: "view-source:" + info.pageURL, activate: true, after: tab)
        default:
            break
        }
    }

    func tabDidNavigate(_ tab: Tab) {
        if tab.id == state.activeTabID { window?.title = tab.displayTitle }
        SessionStore.shared.scheduleSave()
    }

    // MARK: - Window lifecycle

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if state.tabs.allSatisfy({ $0.webView == nil }) { return true }
        closingWindow = true
        for tab in state.tabs {
            if let webView = tab.webView { tab.isClosing = true; webView.closeBrowserForce(true) } else { tab.close() }
        }
        state.tabs.forEach { tabWillClose($0) }
        return false
    }

    private func finishClosingWindow() {
        closingWindow = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared?.windowDidClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        AppDelegate.shared?.lastActiveWindow = self
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if state.contentFullscreen {
            state.contentFullscreen = false
            state.activeTab?.webView?.exitContentFullscreen()
            enteredFullscreenForContent = false
            root.needsLayout = true
        }
        updateTrafficLights()
    }

    func windowDidResize(_ notification: Notification) {
        SessionStore.shared.scheduleSave()
    }

    func windowDidMove(_ notification: Notification) {
        SessionStore.shared.scheduleSave()
    }

    /// Force-closes every browser (used at quit).
    func closeAllForQuit() {
        for tab in state.tabs { tab.isClosing = true; tab.webView?.closeBrowserForce(true) }
    }

    func snapshot() -> SessionSnapshot.WindowState? {
        guard !state.isPrivate, let window else { return nil }
        let tabs = state.tabs.filter { $0.agentOwnerID == nil && !$0.isClosing && !$0.url.isEmpty }
        return SessionSnapshot.WindowState(
            frame: NSStringFromRect(window.frame), sidebarVisible: state.sidebarVisible,
            activeTabID: state.activeTabID,
            tabs: tabs.map { .init(id: $0.id, url: $0.url, title: $0.title, pinned: $0.isPinned) })
    }

    func restore(_ snapshot: SessionSnapshot.WindowState) {
        for saved in snapshot.tabs {
            let tab = Tab(url: saved.url, title: saved.title, isPinned: saved.pinned,
                          profile: state.defaultProfile, profileKind: .standard, id: saved.id)
            tab.host = self
            tab.favicon = FaviconCache.shared.image(for: Site.host(of: saved.url))
            state.tabs.append(tab)
        }
        // Only the active tab loads; the rest stay asleep until selected.
        if let id = snapshot.activeTabID, let tab = state.tabs.first(where: { $0.id == id }) {
            select(tab)
        } else if let first = state.tabs.first {
            select(first)
        }
    }
}

enum PermissionText {
    static func describe(_ kinds: WinkPermissionKinds) -> String {
        var parts: [String] = []
        if kinds.contains(.camera) && kinds.contains(.microphone) { parts.append("use your camera and microphone") }
        else if kinds.contains(.camera) { parts.append("use your camera") }
        else if kinds.contains(.microphone) { parts.append("use your microphone") }
        if kinds.contains(.screenCapture) { parts.append("see your screen") }
        if kinds.contains(.geolocation) { parts.append("know your location") }
        if kinds.contains(.notifications) { parts.append("send notifications") }
        if kinds.contains(.clipboard) { parts.append("read your clipboard") }
        if kinds.contains(.MIDI) { parts.append("control MIDI devices") }
        if kinds.contains(.storageAccess) { parts.append("use cookies across sites") }
        if kinds.contains(.localNetwork) { parts.append("access devices on your local network") }
        return parts.isEmpty ? "use a device permission" : parts.joined(separator: " and ")
    }

    static func symbol(_ kinds: WinkPermissionKinds) -> String {
        if kinds.contains(.camera) { return "video" }
        if kinds.contains(.microphone) { return "mic" }
        if kinds.contains(.screenCapture) { return "rectangle.dashed.badge.record" }
        if kinds.contains(.geolocation) { return "location" }
        if kinds.contains(.notifications) { return "bell" }
        if kinds.contains(.clipboard) { return "doc.on.clipboard" }
        return "hand.raised"
    }
}
