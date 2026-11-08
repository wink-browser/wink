import AppKit
import WinkEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?
    static var launchStart = Date()

    private(set) var windows: [BrowserWindowController] = []
    weak var lastActiveWindow: BrowserWindowController?
    private var terminating = false
    private var launched = false
    private var pendingURLs: [String] = []
    private var settingsWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    var activeWindow: BrowserWindowController? {
        if let key = NSApp.keyWindow?.windowController as? BrowserWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? BrowserWindowController { return main }
        return lastActiveWindow ?? windows.first
    }

    var allTabs: [Tab] { windows.flatMap { $0.state.tabs.filter { !$0.isClosing } } }

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        if DebugDriver.isHeadless { NSApp.setActivationPolicy(.accessory) }
        NSApp.mainMenu = MainMenu.build()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = WinkPaths.shared
        HistoryStore.shared.open(at: paths.state.appendingPathComponent("history.sqlite"))
        HistoryStore.shared.prune(olderThanDays: WinkSettings.shared.historyRetentionDays)
        ContentBlockerService.shared.start()

        SessionStore.shared.snapshotProvider = { [weak self] in
            SessionSnapshot(windows: self?.windows.compactMap { $0.snapshot() } ?? [])
        }
        TabSleeper.shared.windowsProvider = { [weak self] in self?.windows.map(\.state) ?? [] }
        TabSleeper.shared.start()

        WinkRuntime.relaunchHandler = { [weak self] arguments in
            let urls = arguments.filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            if urls.isEmpty { self?.newWindow(isPrivate: false) } else { urls.forEach { self?.openExternalURL($0) } }
            Self.activate()
        }

        AgentHub.shared.start()
        DebugDriver.shared.startIfRequested()

        if WinkSettings.shared.restoreSession, let snapshot = SessionStore.shared.load(), !snapshot.windows.isEmpty {
            for saved in snapshot.windows {
                let frame = saved.frame.map { NSRectFromString($0) }
                let controller = makeWindow(isPrivate: false, frame: frame, sidebarVisible: saved.sidebarVisible)
                controller.restore(saved)
            }
        }
        if windows.isEmpty { newWindow(isPrivate: false) }
        launched = true
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach { openExternalURL($0) }
        Self.activate()
        NSLog("[wink] ready in %.0f ms", Date().timeIntervalSince(Self.launchStart) * 1000)
    }

    /// Brings Wink forward (never for a headless test instance).
    static func activate() {
        guard !DebugDriver.isHeadless else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Windows

    @discardableResult
    func makeWindow(isPrivate: Bool, frame: NSRect? = nil, sidebarVisible: Bool? = nil) -> BrowserWindowController {
        let state = BrowserWindowState(isPrivate: isPrivate,
                                       sidebarVisible: sidebarVisible ?? WinkSettings.shared.sidebarVisible)
        let controller = BrowserWindowController(state: state, frame: frame)
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        lastActiveWindow = controller
        return controller
    }

    @discardableResult
    func newWindow(isPrivate: Bool) -> BrowserWindowController {
        let controller = makeWindow(isPrivate: isPrivate)
        if !DebugDriver.isHeadless {
            DispatchQueue.main.async { CommandBarController.shared.show(for: controller, mode: .newTab) }
        }
        return controller
    }

    func windowDidClose(_ controller: BrowserWindowController) {
        windows.removeAll { $0 === controller }
        if lastActiveWindow === controller { lastActiveWindow = windows.last }
        if !terminating { SessionStore.shared.scheduleSave() }
    }

    func reveal(_ tab: Tab) {
        guard let controller = windows.first(where: { $0.state.tabs.contains { $0.id == tab.id } }) else { return }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.select(tab)
    }

    func window(containing tab: Tab) -> BrowserWindowController? {
        windows.first { $0.state.tabs.contains { $0.id == tab.id } }
    }

    // MARK: - External URLs

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        openExternalURL(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { openExternalURL($0.absoluteString) }
    }

    func openExternalURL(_ url: String) {
        guard launched else { pendingURLs.append(url); return }
        let controller = activeWindow.flatMap { $0.state.isPrivate ? nil : $0 } ?? windows.first { !$0.state.isPrivate }
            ?? makeWindow(isPrivate: false)
        controller.newTab(url: url, activate: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = windows.first { window.window?.makeKeyAndOrderFront(nil) } else { newWindow(isPrivate: false) }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Window", action: #selector(newWindowAction(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "New Private Window", action: #selector(newPrivateWindowAction(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: - Termination

    /// Called for ⌘Q, Dock Quit and logout (WinkApplication.terminate:).
    func beginTermination() {
        guard !terminating else { return }
        terminating = true
        CommandBarController.shared.hide()
        SessionStore.shared.saveNow()
        AgentHub.shared.shutdown()
        AgentPanelModel.shared.shutdown()
        WinkRuntime.allBrowsersClosedHandler = { WinkRuntime.quitMessageLoop() }
        windows.forEach { $0.closeAllForQuit() }
        if WinkRuntime.liveBrowserCount == 0 {
            WinkRuntime.quitMessageLoop()
            return
        }
        // Never hang on quit: give pages a moment, then exit regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { WinkRuntime.quitMessageLoop() }
    }

    // MARK: - Settings

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindow.make() }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        Self.activate()
    }

    // MARK: - Menu actions (routed to the active window)

    @objc func newTabAction(_ sender: Any?) {
        guard let window = activeWindow else { newWindow(isPrivate: false); return }
        CommandBarController.shared.show(for: window, mode: .newTab)
    }
    @objc func newWindowAction(_ sender: Any?) { newWindow(isPrivate: false) }
    @objc func newPrivateWindowAction(_ sender: Any?) { newWindow(isPrivate: true) }
    @objc func openLocationAction(_ sender: Any?) {
        guard let window = activeWindow else { newWindow(isPrivate: false); return }
        CommandBarController.shared.show(for: window, mode: .navigate)
    }
    @objc func closeTabAction(_ sender: Any?) {
        if NSApp.keyWindow === settingsWindow { settingsWindow?.close(); return }
        activeWindow?.closeActiveTab()
    }
    @objc func closeWindowAction(_ sender: Any?) { NSApp.keyWindow?.performClose(nil) }
    @objc func reopenClosedTabAction(_ sender: Any?) { activeWindow?.reopenClosedTab() }
    @objc func reloadAction(_ sender: Any?) { activeWindow?.reload() }
    @objc func hardReloadAction(_ sender: Any?) { activeWindow?.reloadIgnoringCache() }
    @objc func stopAction(_ sender: Any?) { activeWindow?.stopLoading() }
    @objc func backAction(_ sender: Any?) { activeWindow?.goBack() }
    @objc func forwardAction(_ sender: Any?) { activeWindow?.goForward() }
    @objc func findAction(_ sender: Any?) { activeWindow?.showFindBar() }
    @objc func findNextAction(_ sender: Any?) {
        guard let window = activeWindow else { return }
        window.find(window.state.findQuery, forward: true, next: true)
    }
    @objc func findPreviousAction(_ sender: Any?) {
        guard let window = activeWindow else { return }
        window.find(window.state.findQuery, forward: false, next: true)
    }
    @objc func zoomInAction(_ sender: Any?) { activeWindow?.activeTab?.webView?.zoomIn() }
    @objc func zoomOutAction(_ sender: Any?) { activeWindow?.activeTab?.webView?.zoomOut() }
    @objc func actualSizeAction(_ sender: Any?) { activeWindow?.activeTab?.webView?.resetZoom() }
    @objc func toggleSidebarAction(_ sender: Any?) { activeWindow?.toggleSidebar() }
    @objc func toggleAgentPanelAction(_ sender: Any?) { activeWindow?.toggleAgentPanel() }
    @objc func devToolsAction(_ sender: Any?) { activeWindow?.activeTab?.webView?.showDevTools() }
    @objc func printAction(_ sender: Any?) { activeWindow?.activeTab?.webView?.printPage() }
    @objc func nextTabAction(_ sender: Any?) { activeWindow?.selectAdjacentTab(offset: 1) }
    @objc func previousTabAction(_ sender: Any?) { activeWindow?.selectAdjacentTab(offset: -1) }
    @objc func selectTabAction(_ sender: NSMenuItem) { activeWindow?.selectTab(atSidebarIndex: sender.tag) }
    @objc func copyURLAction(_ sender: Any?) {
        guard let url = activeWindow?.activeTab?.url, !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    @objc func pinTabAction(_ sender: Any?) {
        guard let window = activeWindow, let tab = window.activeTab else { return }
        window.togglePin(tab)
    }
    @objc func stopAgentsAction(_ sender: Any?) { AgentHub.shared.stopAll(reason: "Stopped by you") }
    @objc func connectClaudeCodeAction(_ sender: Any?) { AgentIntegrations.connectClaudeCode() }
    @objc func shareTabWithAgentsAction(_ sender: Any?) {
        guard let tab = activeWindow?.activeTab else { return }
        tab.sharedWithAgents.toggle()
    }
    @objc func clearBrowsingDataAction(_ sender: Any?) { PrivacyActions.clearBrowsingData() }
}
