import AppKit
import Observation
import WinkEngine

/// One connected agent: an MCP client (Claude Code, Claude Desktop, …) or
/// Wink's own agent panel.
@MainActor
@Observable
final class AgentSession: Identifiable {
    enum Origin { case mcp, panel }

    let id = UUID()
    var name: String
    let origin: Origin
    var clientVersion = ""
    var parentProcess = ""
    /// Launched by Wink itself (agent panel / Wink-spawned Claude Code).
    let trusted: Bool
    var approved: Bool
    var stoppedAt: Date?
    var allowedTabs: Set<UUID> = []
    var currentTabID: UUID?
    var actionCount = 0
    var lastActivity = Date()
    /// Paused by the user (Pause button, or they clicked into the agent's tab).
    var pauseReason: String?
    var isPaused: Bool { pauseReason != nil }

    // Guardrails: consequential actions (send, buy, delete, connect).
    /// Sites where the user allowed such actions for the rest of this session.
    @ObservationIgnored var siteGrants: Set<String> = []
    @ObservationIgnored var consequential: [(site: String, date: Date)] = []
    @ObservationIgnored var extraAllowance: [String: Int] = [:]
    @ObservationIgnored var isolatedProfile: WinkProfile?

    init(name: String, origin: Origin, trusted: Bool) {
        self.name = name
        self.origin = origin
        self.trusted = trusted
        self.approved = trusted
    }

    var isStopped: Bool {
        guard let stoppedAt else { return false }
        return Date().timeIntervalSince(stoppedAt) < 30
    }
}

/// One line in the activity log (shown in the agent pill).
struct AgentActivity: Identifiable {
    let id = UUID()
    let sessionID: UUID?
    let session: String
    let tabID: UUID?
    var description: String
    let symbol: String
    let date = Date()
    var failed = false
    /// Sent, bought, deleted or connected something on the user's behalf.
    var consequential = false
}

struct AgentAccessError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Central authority for everything agents do in Wink: consent, tab access,
/// visible activity, pausing, and the global stop switch.
@MainActor
@Observable
final class AgentHub {
    static let shared = AgentHub()

    private(set) var sessions: [AgentSession] = []
    private(set) var activity: [AgentActivity] = []
    /// Secret handed to agents Wink launches itself, so their MCP connection
    /// is recognized as pre-approved.
    let internalToken = UUID().uuidString

    @ObservationIgnored private var server: MCPServer?
    @ObservationIgnored private var pendingApprovals: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private var clearActionItems: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var idleItems: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private var stopHandlers: [UUID: () -> Void] = [:]
    @ObservationIgnored private var takeoverMonitor: Any?

    var connectedClientNames: [String] {
        var seen = Set<String>()
        return sessions.filter { $0.origin == .mcp && !$0.isStopped }.compactMap {
            seen.insert($0.name).inserted ? $0.name : nil
        }
    }

    // MARK: - Lifecycle

    func start() {
        installTakeoverMonitor()
        restartServer()
    }

    /// Applies the "Let agents connect" setting immediately.
    func restartServer() {
        server?.stop()
        server = nil
        let socketPath = WinkPaths.shared.mcpSocketPath
        guard WinkSettings.shared.mcpServerEnabled else {
            MCPSessionController.removeHandshake(nextTo: socketPath)
            return
        }
        let server = MCPServer(socketPath: socketPath)
        if server.start() {
            self.server = server
            MCPSessionController.writeHandshake(nextTo: socketPath)
        } else {
            NSLog("[wink] MCP server failed to start")
        }
    }

    /// The tool list changed (a setting): agents opening Wink later see it.
    func refreshHandshake() {
        guard server != nil else { return }
        MCPSessionController.writeHandshake(nextTo: WinkPaths.shared.mcpSocketPath)
    }

    func shutdown() {
        server?.stop()
        stopHandlers.values.forEach { $0() }
    }

    func register(_ session: AgentSession) {
        sessions.append(session)
    }

    func unregister(_ session: AgentSession) {
        sessions.removeAll { $0.id == session.id }
        stopHandlers.removeValue(forKey: session.id)
        for tab in AppDelegate.shared?.allTabs ?? [] where tab.agentSessionID == session.id {
            tab.agentAction = nil
            setIdle(tab)
        }
        // Tabs no other agent is using get their own dialogs back.
        for tab in AppDelegate.shared?.allTabs ?? [] where tab.agentSessionID == session.id || tab.agentOwnerID == session.id {
            let othersHere = sessions.contains { $0.id == tab.agentSessionID || $0.id == tab.agentOwnerID }
            if !othersHere { tab.instruments.release() }
        }
    }

    /// Engines register a closure that cancels their in-flight work on Stop.
    func onStop(_ session: AgentSession, _ handler: @escaping () -> Void) {
        stopHandlers[session.id] = handler
    }

    func session(withID id: UUID?) -> AgentSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    // MARK: - Consent

    /// Ensures the user allowed this agent to use Wink at all.
    func ensureApproved(_ session: AgentSession) async throws {
        if session.isStopped {
            throw AgentAccessError(message: "The user stopped this agent. Wait for them to resume, or ask them to.")
        }
        if session.approved || session.trusted { return }
        if WinkSettings.shared.trustedAgentClients.contains(session.name) {
            session.approved = true
            return
        }
        let task = pendingApprovals[session.id] ?? Task { @MainActor in
            await self.askConnection(session)
        }
        pendingApprovals[session.id] = task
        let allowed = await task.value
        pendingApprovals[session.id] = nil
        guard allowed else {
            throw AgentAccessError(message: "The user did not allow \(session.name) to use the browser.")
        }
    }

    private func askConnection(_ session: AgentSession) async -> Bool {
        let detail = session.parentProcess.isEmpty ? "" : " (\(URL(fileURLWithPath: session.parentProcess).lastPathComponent))"
        let choice = await prompt(
            symbol: "sparkles",
            title: "\(session.name)\(detail) wants to use Wink",
            message: "It can open its own tabs and must ask before using yours. Stop it any time with ⇧⌘.",
            options: ["Don't Allow", "Allow Always", "Allow"], tab: nil)
        switch choice {
        case 2: session.approved = true; return true
        case 1:
            session.approved = true
            if !WinkSettings.shared.trustedAgentClients.contains(session.name) {
                WinkSettings.shared.trustedAgentClients.append(session.name)
            }
            return true
        default: return false
        }
    }

    /// Checks (and if needed asks for) access to a specific tab.
    func authorize(_ session: AgentSession, tab: Tab, purpose: String) async throws {
        try await ensureApproved(session)
        let host = Site.host(of: tab.url)
        if !host.isEmpty, WinkSettings.shared.isAgentProtected(host: host) {
            throw AgentAccessError(message: "\(host) is protected: the user doesn't allow agents on this site.")
        }
        if tab.isPrivate && tab.agentOwnerID != session.id {
            throw AgentAccessError(message: "Private-window tabs are never available to agents.")
        }
        if tab.agentOwnerID == session.id || tab.sharedWithAgents || session.allowedTabs.contains(tab.id) { return }
        // Agents Wink launched from its panel act on what the user is asking
        // about: the tab in view is implicitly shared with them.
        if session.trusted, AppDelegate.shared?.activeWindow?.state.activeTabID == tab.id {
            session.allowedTabs.insert(tab.id)
            return
        }
        let choice = await prompt(
            symbol: "hand.raised",
            title: "\(session.name) wants to \(purpose) “\(tab.displayTitle)”",
            message: URLInput.display(tab.url), options: ["Don't Allow", "Allow"], tab: tab)
        guard choice == 1 else {
            throw AgentAccessError(message: "The user did not allow access to that tab.")
        }
        session.allowedTabs.insert(tab.id)
    }

    /// Explicit confirmation for sensitive steps (e.g. typing into a password field).
    func confirm(_ session: AgentSession, tab: Tab, title: String, message: String) async -> Bool {
        await prompt(symbol: "exclamationmark.shield", title: title, message: message,
                     options: ["Don't Allow", "Allow"], tab: tab) == 1
    }

    /// Shows a prompt card and returns the chosen option index (0 = cancel).
    func prompt(symbol: String, title: String, message: String, options: [String], tab: Tab?,
                timeout: TimeInterval = 120) async -> Int {
        let app = AppDelegate.shared
        let window = tab.flatMap { app?.window(containing: $0) } ?? app?.activeWindow ?? app?.makeWindow(isPrivate: false)
        guard let window else { return 0 }
        if !DebugDriver.isHeadless { NSApp.requestUserAttention(.informationalRequest) }
        return await withCheckedContinuation { continuation in
            var resumed = false
            var request: PromptRequest!
            let finish: (Int) -> Void = { choice in
                guard !resumed else { return }
                resumed = true
                window.resolvePrompt(request)
                continuation.resume(returning: choice)
            }
            let buttons = options.enumerated().map { index, title in
                PromptRequest.Button(title: title, role: index == 0 ? .cancel : (index == options.count - 1 ? .primary : .normal)) {
                    finish(index)
                }
            }
            request = PromptRequest(symbol: symbol, title: title, message: message, isAgent: true,
                                    tabID: tab?.id, buttons: buttons)
            window.enqueuePrompt(request)
            // Unanswered prompts deny, so an unattended agent can't wait forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(0) }
        }
    }

    // MARK: - Tabs for agents

    /// Opens a tab owned by `session` (shown in the sidebar's agent section).
    func openTab(for session: AgentSession, url: String, focus: Bool) -> Tab? {
        guard let app = AppDelegate.shared else { return nil }
        let window = app.activeWindow.flatMap { $0.state.isPrivate ? nil : $0 }
            ?? app.windows.first { !$0.state.isPrivate } ?? app.makeWindow(isPrivate: false)
        var profile = WinkProfile.default
        var kind = TabProfileKind.standard
        if WinkSettings.shared.agentBrowsingProfile == .isolated {
            if session.isolatedProfile == nil {
                session.isolatedProfile = WinkProfile.ephemeralProfile(withName: "Agent: \(session.name)")
            }
            profile = session.isolatedProfile!
            kind = .agentIsolated
        }
        let anchor = window.state.tabs.last
        let tab = window.newTab(url: url, activate: focus, after: anchor, profile: profile, profileKind: kind)
        tab.agentOwnerID = session.id
        tab.agentOwnerName = session.name
        if !focus { window.root.content.attach(tab, visible: false) }
        session.currentTabID = tab.id
        return tab
    }

    func tabs(visibleTo session: AgentSession) -> [Tab] {
        (AppDelegate.shared?.allTabs ?? []).filter {
            $0.agentOwnerID == session.id || $0.sharedWithAgents || session.allowedTabs.contains($0.id)
        }
    }

    func tabDidClose(_ tab: Tab) {
        for session in sessions {
            session.allowedTabs.remove(tab.id)
            if session.currentTabID == tab.id { session.currentTabID = nil }
        }
        clearActionItems.removeValue(forKey: tab.id)?.cancel()
        idleItems.removeValue(forKey: tab.id)?.cancel()
    }

    // MARK: - Activity (always visible to the user)

    func began(_ session: AgentSession, tab: Tab?, _ description: String, symbol: String = "sparkle",
               consequential: Bool = false) {
        session.actionCount += 1
        session.lastActivity = Date()
        if let tab {
            clearActionItems.removeValue(forKey: tab.id)?.cancel()
            idleItems.removeValue(forKey: tab.id)?.cancel()
            tab.agentAction = description
            tab.agentSessionID = session.id
            if !tab.agentActive { tab.agentActive = true }
            if tab.agentOwnerID == nil && tab.agentOwnerName == nil { tab.agentOwnerName = session.name }
        }
        activity.append(AgentActivity(sessionID: session.id, session: session.name, tabID: tab?.id,
                                      description: description, symbol: symbol, consequential: consequential))
        if activity.count > 400 { activity.removeFirst(activity.count - 400) }
    }

    func finished(_ session: AgentSession, tab: Tab?, failed: Bool = false) {
        if let index = activity.lastIndex(where: { $0.sessionID == session.id }) {
            if failed { activity[index].failed = true } else {
                activity[index].description = Self.pastTense(activity[index].description)
            }
        }
        guard let tab else { return }
        scheduleIdle(tab)
    }

    /// Clears the step text shortly, and the glow/pill once the agent has
    /// been quiet for a while (it thinks between steps).
    func scheduleIdle(_ tab: Tab) {
        let clear = DispatchWorkItem { [weak tab] in tab?.agentAction = nil }
        clearActionItems[tab.id] = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: clear)
        // The glow and pill stay while the agent thinks between steps.
        let idle = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.setIdle(tab)
        }
        idleItems[tab.id] = idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: idle)
    }

    /// Shows a status on the pill (e.g. while a prompt waits for the user).
    func waiting(_ tab: Tab, _ status: String) {
        clearActionItems.removeValue(forKey: tab.id)?.cancel()
        idleItems.removeValue(forKey: tab.id)?.cancel()
        tab.agentAction = status
        if !tab.agentActive { tab.agentActive = true }
    }

    /// "Clicking “Send”" → "Clicked “Send”" for the activity log.
    static func pastTense(_ description: String) -> String {
        let forms = [("Clicking", "Clicked"), ("Typing into", "Typed into"), ("Pressing", "Pressed"),
                     ("Choosing", "Chose"), ("Pointing at", "Pointed at"), ("Scrolling", "Scrolled"),
                     ("Opening", "Opened"), ("Going to", "Went to"), ("Finding", "Found"),
                     ("Looking at the page", "Looked at the page"), ("Reading the page", "Read the page"),
                     ("Taking a screenshot", "Took a screenshot"), ("Waiting for", "Waited for"),
                     ("Going back", "Went back"), ("Going forward", "Went forward"), ("Reloading", "Reloaded"),
                     ("Running a script", "Ran a script")]
        for (present, past) in forms where description.hasPrefix(present) {
            return past + description.dropFirst(present.count)
        }
        return description
    }

    private func setIdle(_ tab: Tab) {
        if session(withID: tab.agentSessionID)?.isPaused == true { return }  // stay visible while paused
        tab.agentActive = false
        if tab.agentOwnerID == nil { tab.agentOwnerName = nil }
    }

    func isControlled(_ tab: Tab) -> Bool {
        tab.agentActive || tab.agentAction != nil
    }

    func controllerName(for tab: Tab) -> String? {
        session(withID: tab.agentSessionID)?.name ?? tab.agentOwnerName
            ?? sessions.first { $0.allowedTabs.contains(tab.id) }?.name
    }

    func controller(of tab: Tab) -> AgentSession? {
        session(withID: tab.agentSessionID)
    }

    func recentActivity(for tab: Tab, limit: Int = 8) -> [AgentActivity] {
        Array(activity.lazy.filter { $0.tabID == tab.id }.suffix(limit))
    }

    // MARK: - Pause / take over

    func pause(_ session: AgentSession, reason: String) {
        guard !session.isPaused else { return }
        session.pauseReason = reason
        activity.append(AgentActivity(sessionID: session.id, session: session.name, tabID: session.currentTabID,
                                      description: reason, symbol: "pause.fill"))
    }

    func resume(_ session: AgentSession) {
        session.pauseReason = nil
        for tab in AppDelegate.shared?.allTabs ?? [] where tab.agentSessionID == session.id {
            finished(session, tab: tab)  // restart the idle timer
        }
    }

    func togglePause(for tab: Tab) {
        guard let session = controller(of: tab) else { return }
        if session.isPaused { resume(session) } else { pause(session, reason: "Paused by you") }
    }

    /// Holds an agent's next step while the user has it paused.
    func waitWhilePaused(_ session: AgentSession) async throws {
        let start = Date()
        while session.isPaused {
            if session.isStopped { throw AgentAccessError(message: "Stopped by the user.") }
            if Date().timeIntervalSince(start) > 15 * 60 {
                throw AgentAccessError(message: "The user paused you and hasn't resumed. Ask them how to continue.")
            }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        if session.isStopped { throw AgentAccessError(message: "Stopped by the user. Do not retry unless they ask you to continue.") }
    }

    /// The user clicked or typed into a page an agent is driving: hand them
    /// the controls instead of fighting over the mouse.
    private func installTakeoverMonitor() {
        guard takeoverMonitor == nil else { return }
        takeoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated { AgentHub.shared.noticeUserInput(event) }
            return event
        }
    }

    private func noticeUserInput(_ event: NSEvent) {
        guard WinkSettings.shared.agentPauseOnTakeover,
              let window = event.window,
              let browser = window.windowController as? BrowserWindowController,
              let tab = browser.state.activeTab, tab.agentActive,
              let session = controller(of: tab), !session.isPaused,
              let webView = tab.webView else { return }
        if event.type == .keyDown {
            guard !event.modifierFlags.contains(.command),
                  let responder = window.firstResponder as? NSView, responder.isDescendant(of: webView) else { return }
        } else {
            guard let hit = window.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: webView) else { return }
        }
        pause(session, reason: "You took over")
    }

    /// Stops one agent (e.g. the user declined to extend its hourly limit).
    func stop(_ session: AgentSession, reason: String) {
        session.stoppedAt = Date()
        session.pauseReason = nil
        if !session.trusted { session.approved = false }
        session.siteGrants.removeAll()
        stopHandlers[session.id]?()
        for tab in AppDelegate.shared?.allTabs ?? [] where tab.agentSessionID == session.id {
            tab.agentAction = nil
            tab.agentActive = false
        }
        activity.append(AgentActivity(sessionID: session.id, session: session.name, tabID: session.currentTabID,
                                      description: reason, symbol: "stop.fill"))
    }

    /// The global kill switch (⇧⌘. or the Stop button on the page).
    func stopAll(reason: String) {
        for session in sessions {
            session.stoppedAt = Date()
            session.pauseReason = nil
            if !session.trusted { session.approved = false }
            session.allowedTabs.removeAll()
            session.siteGrants.removeAll()
        }
        stopHandlers.values.forEach { $0() }
        for tab in AppDelegate.shared?.allTabs ?? [] {
            tab.agentAction = nil
            tab.agentActive = false
        }
        for window in AppDelegate.shared?.windows ?? [] {
            for prompt in window.state.prompts where prompt.isAgent {
                prompt.buttons.first?.action()
            }
        }
        activity.append(AgentActivity(sessionID: nil, session: "Wink", tabID: nil, description: reason, symbol: "stop.fill"))
    }

    static func shortID(_ tab: Tab) -> String {
        String(tab.id.uuidString.prefix(8)).lowercased()
    }

    func tab(withShortID id: String) -> Tab? {
        let needle = id.lowercased().replacingOccurrences(of: "tab_", with: "")
        return AppDelegate.shared?.allTabs.first { Self.shortID($0) == needle }
    }
}
