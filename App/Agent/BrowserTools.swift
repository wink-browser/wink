import AppKit
import ImageIO
import UniformTypeIdentifiers
import WinkEngine

struct AgentToolDefinition {
    let name: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    let readOnly: Bool

    var inputSchema: [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
}

enum AgentToolContent {
    case text(String)
    case image(Data, mimeType: String)
}

struct AgentToolResult {
    var content: [AgentToolContent]
    var isError = false

    static func text(_ text: String) -> AgentToolResult { AgentToolResult(content: [.text(text)]) }
    static func error(_ text: String) -> AgentToolResult { AgentToolResult(content: [.text(text)], isError: true) }

    var summary: String {
        content.compactMap { if case .text(let t) = $0 { return t } else { return "[image]" } }.joined(separator: "\n")
    }

    var image: Data? {
        for item in content { if case .image(let data, _) = item { return data } }
        return nil
    }
}

/// Browser automation tools exposed to every agent (MCP clients and Wink's
/// own panel). All access goes through AgentHub for consent and visibility,
/// and consequential actions go through Guardrails.
///
/// Speed comes from round trips, not milliseconds: every action reports what
/// it changed (dialogs, notices, updated controls, with fresh refs), `find`
/// replaces most full snapshots, and `batch` runs a whole sequence in one call.
@MainActor
enum BrowserTools {
    private static let tabID: [String: Any] = [
        "type": "string",
        "description": "Tab to act on (from tabs_list / tab_open). Defaults to the tab you used last.",
    ]
    private static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    private static let stepSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["click", "type", "press_key", "select_option", "hover", "scroll", "wait_for", "navigate"]],
            "ref": prop("string", "Element ref."),
            "text": prop("string", "click: visible label to click. type: text to type. wait_for: text to wait for."),
            "x": prop("number", "click: x in your latest screenshot."),
            "y": prop("number", "click: y in your latest screenshot."),
            "key": prop("string", "press_key: key or shortcut."),
            "value": prop("string", "select_option: option value or label."),
            "url": prop("string", "navigate: absolute URL."),
            "direction": ["type": "string", "enum": ["up", "down", "left", "right", "top", "bottom"]],
            "amount": prop("integer", "scroll: pixels."),
            "clear": prop("boolean", "type: replace existing text (default true)."),
            "submit": prop("boolean", "type: press Enter after typing."),
            "selector": prop("string", "wait_for: CSS selector."),
            "gone": prop("boolean", "wait_for: wait for it to disappear."),
            "timeout_ms": prop("integer", "wait_for: maximum wait."),
            "double_click": prop("boolean", "click: double-click."),
        ],
        "required": ["action"],
        "additionalProperties": false,
    ]

    static let definitions: [AgentToolDefinition] = [
        .init(name: "tabs_list",
              description: "List the browser tabs you can use: tabs you opened and tabs the user shared with you. The user's other tabs are private.",
              properties: [:], required: [], readOnly: true),
        .init(name: "get_active_tab",
              description: "Ask for access to the tab the user is currently looking at (the user may be asked to approve). Use when the user refers to 'this page' or 'my tab'.",
              properties: [:], required: [], readOnly: true),
        .init(name: "tab_open",
              description: "Open a URL in a new tab that belongs to you, and wait for it to load. Returns its tab_id.",
              properties: ["url": prop("string", "Absolute http(s) URL to open."),
                           "focus": prop("boolean", "Show the tab to the user (default false: opens in the background).")],
              required: ["url"], readOnly: false),
        .init(name: "tab_close", description: "Close a tab you opened.",
              properties: ["tab_id": tabID], required: ["tab_id"], readOnly: false),
        .init(name: "tab_focus", description: "Bring a tab to the front so the user can see it.",
              properties: ["tab_id": tabID], required: ["tab_id"], readOnly: false),
        .init(name: "navigate", description: "Load a URL in a tab and wait for the page to finish loading.",
              properties: ["url": prop("string", "Absolute http(s) URL."), "tab_id": tabID],
              required: ["url"], readOnly: false),
        .init(name: "go_back", description: "Go back in the tab's history.",
              properties: ["tab_id": tabID], required: [], readOnly: false),
        .init(name: "go_forward", description: "Go forward in the tab's history.",
              properties: ["tab_id": tabID], required: [], readOnly: false),
        .init(name: "reload", description: "Reload the page.",
              properties: ["tab_id": tabID], required: [], readOnly: false),
        .init(name: "find",
              description: "Find interactive elements whose label or text contains `text` (e.g. every \"Connect\" button) and get their refs plus the card or row each sits in. Much faster and smaller than a snapshot; use it to target repeated items.",
              properties: ["text": prop("string", "Text to look for (case-insensitive)."),
                           "role": prop("string", "Optional role filter: button, link, textbox, checkbox, heading, …"),
                           "max": prop("integer", "Maximum matches (default 25)."), "tab_id": tabID],
              required: [], readOnly: true),
        .init(name: "snapshot",
              description: "Describe the whole page as an accessibility outline (headings, text, links, buttons, inputs) with element refs like [ref=e12]. Use for an overview; prefer find for specific elements. Actions already report what they changed, so you rarely need a snapshot after one.",
              properties: ["tab_id": tabID,
                           "viewport_only": prop("boolean", "Only include what is currently scrolled into view (smaller output)."),
                           "max_lines": prop("integer", "Maximum outline lines (default 500).")],
              required: [], readOnly: true),
        .init(name: "read_page",
              description: "Extract the page's main readable content as Markdown (articles, docs, search results). Best for reading; use find/snapshot for interacting.",
              properties: ["tab_id": tabID, "max_chars": prop("integer", "Maximum characters (default 20000).")],
              required: [], readOnly: true),
        .init(name: "screenshot",
              description: "Capture what the tab shows as a JPEG. One image pixel is one CSS pixel, so x/y read off the image can be passed to click directly. labels:true draws each clickable element's ref on the image, so you can click by ref instead of coordinates.",
              properties: ["tab_id": tabID,
                           "labels": prop("boolean", "Overlay element refs on the image."),
                           "full_page": prop("boolean", "Capture the whole scrollable page instead of the viewport.")],
              required: [], readOnly: true),
        .init(name: "click",
              description: "Click an element by ref (preferred), by visible label text, or at x/y from your latest screenshot. Waits for the page to react and returns what changed (opened dialogs with their buttons' refs, notices, updated buttons), so you can chain the next step without a new snapshot or screenshot.",
              properties: ["ref": prop("string", "Element ref, e.g. e12."),
                           "text": prop("string", "Visible label of a link/button to click if you have no ref."),
                           "x": prop("number", "x in your latest screenshot (= CSS pixels)."),
                           "y": prop("number", "y in your latest screenshot (= CSS pixels)."),
                           "double_click": prop("boolean", "Double-click instead of single click."),
                           "tab_id": tabID],
              required: [], readOnly: false),
        .init(name: "type",
              description: "Type text into an input, textarea or editable element (by ref). Replaces existing text unless clear is false. Returns what changed (e.g. suggestions that appeared).",
              properties: ["ref": prop("string", "Element ref."),
                           "text": prop("string", "Text to type."),
                           "clear": prop("boolean", "Replace the current value (default true)."),
                           "submit": prop("boolean", "Press Enter after typing."),
                           "tab_id": tabID],
              required: ["ref", "text"], readOnly: false),
        .init(name: "press_key",
              description: "Press a key or shortcut in the page, e.g. Enter, Escape, Tab, ArrowDown, PageDown, Meta+A. Returns what changed.",
              properties: ["key": prop("string", "Key name, optionally with modifiers joined by '+'."), "tab_id": tabID],
              required: ["key"], readOnly: false),
        .init(name: "select_option", description: "Choose an option in a <select> dropdown by its value or visible text.",
              properties: ["ref": prop("string", "Ref of the select element."),
                           "value": prop("string", "Option value or label."), "tab_id": tabID],
              required: ["ref", "value"], readOnly: false),
        .init(name: "hover", description: "Move the mouse over an element; returns any menu or tooltip that opened.",
              properties: ["ref": prop("string", "Element ref."), "tab_id": tabID], required: ["ref"], readOnly: false),
        .init(name: "scroll",
              description: "Scroll the page (or a scrollable element by ref). Returns the new position and newly loaded items.",
              properties: ["direction": ["type": "string", "enum": ["up", "down", "left", "right", "top", "bottom"]],
                           "amount": prop("integer", "Pixels to scroll (default: most of a screen)."),
                           "ref": prop("string", "Scrollable element ref (optional)."), "tab_id": tabID],
              required: ["direction"], readOnly: false),
        .init(name: "batch",
              description: "Run up to 25 steps (click, type, press_key, select_option, hover, scroll, wait_for, navigate) in one call, each waiting for the page to settle. Stops at the first failure and reports every step's result and changes. Use it for known sequences, e.g. click a Connect button then the dialog's \"Send\" by text. Each step takes the same fields as its tool.",
              properties: ["steps": ["type": "array", "items": stepSchema, "description": "Steps to run in order."],
                           "tab_id": tabID],
              required: ["steps"], readOnly: false),
        .init(name: "wait_for",
              description: "Wait until text or a CSS selector appears (or disappears) on the page.",
              properties: ["text": prop("string", "Text to wait for."),
                           "selector": prop("string", "CSS selector to wait for."),
                           "gone": prop("boolean", "Wait for it to disappear instead."),
                           "timeout_ms": prop("integer", "Maximum wait (default 10000, max 60000)."), "tab_id": tabID],
              required: [], readOnly: true),
        .init(name: "get_selection", description: "Return the text the user has selected in the tab.",
              properties: ["tab_id": tabID], required: [], readOnly: true),
        .init(name: "console_logs", description: "Recent JavaScript console messages from the tab (great for debugging web apps).",
              properties: ["level": ["type": "string", "enum": ["error", "warning", "all"]],
                           "limit": prop("integer", "Maximum entries (default 50)."), "tab_id": tabID],
              required: [], readOnly: true),
        .init(name: "network_requests",
              description: "Recent network requests made by the page: URL, status, type, size; including failed and blocked ones.",
              properties: ["filter": ["type": "string", "enum": ["all", "failed", "fetch", "blocked"]],
                           "limit": prop("integer", "Maximum entries (default 50)."), "tab_id": tabID],
              required: [], readOnly: true),
        .init(name: "evaluate",
              description: "Run a JavaScript expression in the page and return its JSON result. Only available if the user enabled it in Wink settings.",
              properties: ["expression": prop("string", "JavaScript expression; may return a Promise."), "tab_id": tabID],
              required: ["expression"], readOnly: false),
    ]

    /// Permission hook for Claude Code sessions launched by Wink
    /// (`--permission-prompt-tool mcp__wink__approve`).
    static let approvalTool = AgentToolDefinition(
        name: "approve",
        description: "Ask the Wink user to approve a tool call requested by the agent.",
        properties: ["tool_name": prop("string", "Tool requesting permission."),
                     "input": ["type": "object", "description": "Tool input."],
                     "tool_use_id": prop("string", "Tool use id.")],
        required: ["tool_name", "input"], readOnly: true)

    static func definitions(for session: AgentSession) -> [AgentToolDefinition] {
        var list = definitions
        if !WinkSettings.shared.allowAgentJavaScript { list.removeAll { $0.name == "evaluate" } }
        if session.trusted && session.origin == .mcp { list.append(approvalTool) }
        return list
    }

    /// SF Symbol for a tool, shared by the activity log and the agent panel.
    static func symbol(for tool: String) -> String {
        switch tool {
        case "tab_open", "navigate": "globe"
        case "tab_close": "xmark.square"
        case "tab_focus": "macwindow"
        case "go_back": "chevron.backward"
        case "go_forward": "chevron.forward"
        case "reload": "arrow.clockwise"
        case "find": "magnifyingglass"
        case "snapshot": "text.viewfinder"
        case "read_page": "doc.plaintext"
        case "screenshot": "camera.viewfinder"
        case "click": "cursorarrow.click"
        case "type", "press_key": "keyboard"
        case "select_option": "filemenu.and.selection"
        case "hover": "cursorarrow"
        case "scroll": "arrow.up.and.down"
        case "batch": "list.number"
        case "wait_for": "hourglass"
        case "get_selection": "text.cursor"
        case "console_logs": "terminal"
        case "network_requests": "network"
        case "evaluate": "curlybraces"
        case "tabs_list", "get_active_tab": "square.on.square"
        default: "sparkle"
        }
    }

    // MARK: - Dispatch

    static func call(_ name: String, _ args: [String: Any], session: AgentSession) async -> AgentToolResult {
        do {
            switch name {
            case "tabs_list": return try await tabsList(session)
            case "get_active_tab": return try await getActiveTab(session)
            case "tab_open": return try await tabOpen(args, session)
            case "tab_close": return try await tabClose(args, session)
            case "tab_focus": return try await tabFocus(args, session)
            case "navigate":
                let tab = try await accessTab(args, session, purpose: "control")
                return .text(try await navigateStep(args, session, tab))
            case "go_back", "go_forward", "reload": return try await history(name, args, session)
            case "find": return try await find(args, session)
            case "snapshot": return try await snapshot(args, session)
            case "read_page": return try await readPage(args, session)
            case "screenshot": return try await screenshot(args, session)
            case "click", "type", "press_key", "select_option", "hover", "scroll":
                let tab = try await accessTab(args, session, purpose: "control")
                return .text(try await perform(name, args, session, tab, inBatch: false))
            case "batch": return try await batch(args, session)
            case "wait_for": return try await waitFor(args, session)
            case "get_selection": return try await getSelection(args, session)
            case "console_logs": return try await consoleLogs(args, session)
            case "network_requests": return try await networkRequests(args, session)
            case "evaluate": return try await evaluate(args, session)
            case "approve": return try await approve(args, session)
            default: return .error("Unknown tool \(name).")
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func string(_ args: [String: Any], _ key: String) -> String? {
        (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        if let b = args[key] as? Bool { return b }
        if let s = args[key] as? String { return s == "true" }
        return nil
    }

    private static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let d = args[key] as? Double { return Int(d) }
        if let s = args[key] as? String { return Int(s) }
        return nil
    }

    private static func double(_ args: [String: Any], _ key: String) -> Double? {
        if let d = args[key] as? Double { return d }
        if let i = args[key] as? Int { return Double(i) }
        if let s = args[key] as? String { return Double(s) }
        return nil
    }

    private static func resolveTab(_ args: [String: Any], _ session: AgentSession) throws -> Tab {
        if let id = string(args, "tab_id") {
            guard let tab = AgentHub.shared.tab(withShortID: id) else {
                throw AgentAccessError(message: "No tab \(id). Call tabs_list to see your tabs.")
            }
            return tab
        }
        if let current = session.currentTabID, let tab = AppDelegate.shared?.allTabs.first(where: { $0.id == current }) {
            return tab
        }
        throw AgentAccessError(message: "No tab selected. Call tab_open, or get_active_tab for the user's current tab, then pass its tab_id.")
    }

    /// Resolves the tab, checks consent, holds while the user has the agent
    /// paused, makes the tab current and wakes it.
    private static func accessTab(_ args: [String: Any], _ session: AgentSession, purpose: String) async throws -> Tab {
        let tab = try resolveTab(args, session)
        try await AgentHub.shared.authorize(session, tab: tab, purpose: purpose)
        try await AgentHub.shared.waitWhilePaused(session)
        session.currentTabID = tab.id
        try await ensureLive(tab)
        return tab
    }

    private static func ensureLive(_ tab: Tab) async throws {
        if tab.webView == nil, let window = AppDelegate.shared?.window(containing: tab) {
            window.root.content.attach(tab, visible: tab.id == window.state.activeTabID)
        }
        try await poll(timeout: 15) { tab.webView?.hasBrowser == true }
        if tab.isLoading { _ = await waitForLoad(tab, timeout: 20) }
    }

    private static func poll(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw AgentAccessError(message: "The tab did not become ready in time.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func waitForLoad(_ tab: Tab, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            tab.waitForLoad(timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// Waits for a navigation issued at `since` to finish. Returns as soon as
    /// a load that ended after `since` is seen — fast pages cost nothing extra.
    private static func settleNavigation(_ tab: Tab, since: Date, startedWithin: TimeInterval = 1.5,
                                         timeout: TimeInterval = 30) async {
        while !tab.isLoading && Date().timeIntervalSince(since) < startedWithin {
            if let finished = tab.lastLoadFinished, finished > since { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        if tab.isLoading { _ = await waitForLoad(tab, timeout: timeout) }
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    private enum Settled { case navigated, quiet, idle, busy }

    /// Waits for the page to react to an action: a navigation (then its load),
    /// or DOM mutations going quiet. Polled from Swift, so pages in background
    /// tabs (whose timers Chromium throttles) settle just as fast.
    private static func settle(_ tab: Tab, patient: Bool) async -> Settled {
        let start = Date()
        let firstChange = patient ? 1.4 : 0.35   // give up waiting for any reaction
        let minimum = patient ? 0.5 : 0.08
        let quiet = 0.11
        let maximum = patient ? 4.0 : 1.8
        while true {
            try? await Task.sleep(nanoseconds: 35_000_000)
            if tab.isLoading { break }
            let elapsed = Date().timeIntervalSince(start)
            let value = (try? await tab.cdp.evaluateAgent("__wink.muts()")) as? [Any]
            let count = (value?.first as? NSNumber)?.intValue ?? -1
            let since = ((value?.last as? NSNumber)?.doubleValue ?? 0) / 1000
            if count < 0 {
                if tab.isLoading { break }
                return .navigated  // the document was replaced
            }
            if count == 0 {
                if elapsed > firstChange { return .idle }
            } else if since > quiet && elapsed > minimum {
                return .quiet
            }
            if elapsed > maximum { return .busy }
        }
        _ = await waitForLoad(tab, timeout: 30)
        try? await Task.sleep(nanoseconds: 120_000_000)
        return .navigated
    }

    private static func changes(_ tab: Tab, _ settled: Settled, near target: Target?, limit: Int) async -> String {
        if settled == .navigated {
            if let failure = tab.loadFailure {
                return "\nNavigation failed: \(failure.description.isEmpty ? "error \(failure.code)" : failure.description)"
            }
            return "\nNavigated to: \(tab.displayTitle) — \(tab.url)"
        }
        let cx = target.map { Double($0.point.x) } ?? -1
        let cy = target.map { Double($0.point.y) } ?? -1
        let text = (try? await tab.cdp.evaluateAgent("__wink.changes(\(limit), \(cx), \(cy))")) as? String ?? ""
        if text.isEmpty {
            return settled == .busy
                ? "\nThe page is still busy; use find or wait_for if you expect something."
                : "\nNo visible change on the page."
        }
        let lines = text.split(separator: "\n").map { $0.hasPrefix("    ") ? "  " + $0 : "- " + $0 }
        return "\nChanges:\n" + lines.joined(separator: "\n")
    }

    private static func run<T>(_ session: AgentSession, _ tab: Tab?, _ description: String, symbol: String,
                               consequential: Bool = false, _ body: () async throws -> T) async throws -> T {
        AgentHub.shared.began(session, tab: tab, description, symbol: symbol, consequential: consequential)
        do {
            let value = try await body()
            AgentHub.shared.finished(session, tab: tab)
            return value
        } catch {
            AgentHub.shared.finished(session, tab: tab, failed: true)
            throw error
        }
    }

    private static func js(_ tab: Tab, _ expression: String) async throws -> Any? {
        try await tab.cdp.evaluateAgent(expression)
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static func validatedURL(_ raw: String?) throws -> String {
        guard let raw, let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme) || raw == "about:blank" else {
            throw AgentAccessError(message: "Only absolute http(s) URLs can be opened by agents.")
        }
        if let host = components.host, WinkSettings.shared.isAgentProtected(host: host.lowercased()) {
            throw AgentAccessError(message: "\(host) is protected: the user doesn't allow agents on this site.")
        }
        return raw
    }

    private static func describe(_ tab: Tab, session: AgentSession? = nil) -> String {
        var flags: [String] = []
        if let session, tab.agentOwnerID == session.id { flags.append("yours") }
        if tab.sharedWithAgents { flags.append("shared") }
        if AppDelegate.shared?.activeWindow?.state.activeTabID == tab.id { flags.append("visible to user") }
        if tab.isLoading { flags.append("loading") }
        let suffix = flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))"
        return "tab_id: \(AgentHub.shortID(tab)) — \(tab.displayTitle) — \(tab.url)\(suffix)"
    }

    private static func pageStatus(_ tab: Tab) -> String {
        if let failure = tab.loadFailure {
            return "Load failed: \(failure.description.isEmpty ? "error \(failure.code)" : failure.description) (\(failure.url))"
        }
        return "Title: \(tab.displayTitle)\nURL: \(tab.url)"
    }

    // MARK: - Tabs

    private static func tabsList(_ session: AgentSession) async throws -> AgentToolResult {
        try await AgentHub.shared.ensureApproved(session)
        let visible = AgentHub.shared.tabs(visibleTo: session)
        let total = AppDelegate.shared?.allTabs.filter { !$0.isPrivate }.count ?? 0
        var lines = visible.map { describe($0, session: session) }
        if lines.isEmpty { lines.append("You have no tabs yet. Use tab_open to open one.") }
        let hidden = max(0, total - visible.count)
        if hidden > 0 {
            lines.append("\(hidden) other tab(s) belong to the user and are private. Use get_active_tab to ask for the one they are viewing.")
        }
        return .text(lines.joined(separator: "\n"))
    }

    private static func getActiveTab(_ session: AgentSession) async throws -> AgentToolResult {
        guard let tab = AppDelegate.shared?.activeWindow?.state.activeTab else {
            return .error("The user has no tab open.")
        }
        try await AgentHub.shared.authorize(session, tab: tab, purpose: "use")
        session.currentTabID = tab.id
        return .text(describe(tab, session: session))
    }

    private static func tabOpen(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        try await AgentHub.shared.ensureApproved(session)
        try await AgentHub.shared.waitWhilePaused(session)
        let url = try validatedURL(string(args, "url"))
        let issued = Date()
        guard let tab = AgentHub.shared.openTab(for: session, url: url, focus: bool(args, "focus") ?? false) else {
            return .error("Could not open a tab.")
        }
        return try await run(session, tab, "Opening \(URLInput.display(url))", symbol: symbol(for: "tab_open")) {
            try await poll(timeout: 15) { tab.webView?.hasBrowser == true }
            await settleNavigation(tab, since: issued, startedWithin: 3)
            return .text("Opened \(describe(tab, session: session))\n\(pageStatus(tab))\nNext: find, snapshot or read_page.")
        }
    }

    private static func tabClose(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try resolveTab(args, session)
        guard tab.agentOwnerID == session.id else { return .error("You can only close tabs you opened.") }
        AppDelegate.shared?.window(containing: tab)?.closeTab(tab)
        return .text("Closed tab \(AgentHub.shortID(tab)).")
    }

    private static func tabFocus(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "show")
        AppDelegate.shared?.reveal(tab)
        return .text("Showing \(describe(tab, session: session)).")
    }

    private static func navigateStep(_ args: [String: Any], _ session: AgentSession, _ tab: Tab) async throws -> String {
        let url = try validatedURL(string(args, "url"))
        try await AgentHub.shared.waitWhilePaused(session)
        return try await run(session, tab, "Going to \(URLInput.display(url))", symbol: symbol(for: "navigate")) {
            let issued = Date()
            tab.load(url)
            await settleNavigation(tab, since: issued)
            return pageStatus(tab)
        }
    }

    private static func history(_ action: String, _ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "control")
        try await AgentHub.shared.waitWhilePaused(session)
        let label = action == "go_back" ? "Going back" : action == "go_forward" ? "Going forward" : "Reloading"
        return try await run(session, tab, label, symbol: symbol(for: action)) {
            let issued = Date()
            switch action {
            case "go_back": tab.webView?.goBack()
            case "go_forward": tab.webView?.goForward()
            default: tab.reload()
            }
            await settleNavigation(tab, since: issued, startedWithin: 1.0)
            return .text(pageStatus(tab))
        }
    }

    // MARK: - Reading

    private static func find(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let text = string(args, "text")
        let role = string(args, "role")
        guard text != nil || role != nil else { return .error("find needs text or role.") }
        let tab = try await accessTab(args, session, purpose: "read")
        let max = min(Swift.max(int(args, "max") ?? 25, 1), 100)
        return try await run(session, tab, "Finding “\((text ?? role ?? "").prefix(30))”", symbol: symbol(for: "find")) {
            AgentVisuals.scan(tab)
            let options = "{role: \(role.map(jsString) ?? "null"), max: \(max)}"
            let result = try await js(tab, "__wink.find(\(text.map(jsString) ?? "''"), \(options))")
            return .text("tab_id: \(AgentHub.shortID(tab))\n" + (result as? String ?? "No matches."))
        }
    }

    private static func snapshot(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "read")
        let maxLines = min(max(int(args, "max_lines") ?? 500, 50), 2000)
        let viewportOnly = bool(args, "viewport_only") ?? false
        return try await run(session, tab, "Looking at the page", symbol: symbol(for: "snapshot")) {
            AgentVisuals.scan(tab)
            let result = try await js(tab, "__wink.snapshot({maxLines: \(maxLines), viewportOnly: \(viewportOnly)})")
            return .text("tab_id: \(AgentHub.shortID(tab))\n" + (result as? String ?? "(empty page)"))
        }
    }

    private static func readPage(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "read")
        let maxChars = min(max(int(args, "max_chars") ?? 20_000, 1000), 200_000)
        return try await run(session, tab, "Reading the page", symbol: symbol(for: "read_page")) {
            AgentVisuals.scan(tab)
            let result = try await js(tab, "__wink.read(\(maxChars))")
            return .text(result as? String ?? "(no readable text)")
        }
    }

    private static func screenshot(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "see")
        let fullPage = bool(args, "full_page") ?? false
        let labels = bool(args, "labels") ?? false
        return try await run(session, tab, "Taking a screenshot", symbol: symbol(for: "screenshot")) {
            var targets: [[String: Any]] = []
            if labels && !fullPage {
                targets = (try? await js(tab, "__wink.targets(120)")) as? [[String: Any]] ?? []
            }
            let shot = try await tab.cdp.screenshot(fullPage: fullPage)
            AgentVisuals.shutter(tab)
            var data = shot.data
            if !targets.isEmpty, let annotated = annotate(shot, targets: targets) { data = annotated }
            var note: String
            if fullPage {
                note = "Full-page image (\(shot.width)×\(shot.height) px). Its coordinates are page positions, not clickable points: click by ref, or scroll and take a viewport screenshot."
            } else {
                tab.agentScreenshotScale = shot.scale
                note = shot.scale >= 0.999
                    ? "\(shot.width)×\(shot.height) px; image pixels = CSS pixels, so x/y from this image can be passed to click directly."
                    : "\(shot.width)×\(shot.height) px, scaled \(String(format: "%.2f", shot.scale))× from the viewport; pass x/y from this image to click and Wink converts them."
            }
            if !targets.isEmpty { note += " Labels show element refs: click by ref." }
            return AgentToolResult(content: [.image(data, mimeType: "image/jpeg"),
                                              .text("Screenshot of \(tab.displayTitle) — \(tab.url)\n\(note)")])
        }
    }

    /// Draws ref tags over clickable elements (in Swift, so the page never
    /// sees an overlay).
    private static func annotate(_ shot: CDPSession.Screenshot, targets: [[String: Any]]) -> Data? {
        guard let source = CGImageSourceCreateWithData(shot.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let s = shot.scale
        let tagFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: tagFont, .foregroundColor: NSColor.white]
        for target in targets {
            guard let ref = target["ref"] as? String else { continue }
            let box = CGRect(x: (target["x"] as? Double ?? 0) * s, y: (target["y"] as? Double ?? 0) * s,
                             width: (target["w"] as? Double ?? 0) * s, height: (target["h"] as? Double ?? 0) * s)
            context.setStrokeColor(Theme.auroraNS[0].withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1)
            context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            let label = ref as NSString
            let textSize = label.size(withAttributes: attributes)
            let tag = CGRect(x: max(0, box.minX), y: max(0, box.minY - textSize.height - 1),
                             width: textSize.width + 6, height: textSize.height + 1)
            context.setFillColor(NSColor(calibratedRed: 0.24, green: 0.16, blue: 0.45, alpha: 0.92).cgColor)
            context.fill(tag)
            label.draw(at: CGPoint(x: tag.minX + 3, y: tag.minY), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let annotated = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, annotated, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func getSelection(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "read")
        let text = try await js(tab, "__wink.selection()") as? String ?? ""
        return .text(text.isEmpty ? "(nothing selected)" : text)
    }

    // MARK: - Acting

    struct Target {
        var ref: String?
        /// Where to click, in CSS pixels of the viewport.
        var point: CGPoint
        var rect: CGRect?
        /// The element's corner radius (CSS px).
        var radius: CGFloat = 0
        var role: String
        var name: String
        var sensitive = false
        var editable = false
        var obscuredBy: String?
        var risk: ConsequentialAction?

        var label: String { name.isEmpty ? role : "“\(name.prefix(48))”" }
        var phrase: String { name.isEmpty ? role : "\(role) “\(name.prefix(70))”" }
    }

    private static func target(from value: Any?) -> Target? {
        guard let v = value as? [String: Any] else { return nil }
        let rect = (v["rect"] as? [String: Any]).map {
            CGRect(x: ($0["x"] as? NSNumber)?.doubleValue ?? 0, y: ($0["y"] as? NSNumber)?.doubleValue ?? 0,
                   width: ($0["width"] as? NSNumber)?.doubleValue ?? 0, height: ($0["height"] as? NSNumber)?.doubleValue ?? 0)
        }
        let x = (v["x"] as? NSNumber)?.doubleValue ?? rect.map { Double($0.midX) } ?? 0
        let y = (v["y"] as? NSNumber)?.doubleValue ?? rect.map { Double($0.midY) } ?? 0
        return Target(ref: v["ref"] as? String, point: CGPoint(x: x, y: y), rect: rect,
                      radius: CGFloat((v["radius"] as? NSNumber)?.doubleValue ?? 0),
                      role: v["role"] as? String ?? "element", name: v["name"] as? String ?? "",
                      sensitive: v["sensitive"] as? Bool ?? false, editable: v["editable"] as? Bool ?? false,
                      obscuredBy: v["obscuredBy"] as? String, risk: ConsequentialAction(v["risk"]))
    }

    /// A ref, a visible label (waited for briefly, since dialogs take a beat
    /// to open), or screenshot coordinates.
    private static func resolveTarget(_ tab: Tab, _ args: [String: Any], wait: TimeInterval) async throws -> Target {
        if let ref = string(args, "ref") {
            guard let target = target(from: try await js(tab, "__wink.locate(\(jsString(ref)))")) else {
                throw AgentAccessError(message: "Could not find element \(ref).")
            }
            return target
        }
        if let text = string(args, "text") {
            let deadline = Date().addingTimeInterval(wait)
            while true {
                if let ref = try await js(tab, "__wink.findByText(\(jsString(text)), true)") as? String,
                   let target = target(from: try await js(tab, "__wink.locate(\(jsString(ref)))")) {
                    return target
                }
                if Date() > deadline {
                    throw AgentAccessError(message: "Nothing clickable labelled “\(text)”. Use find or snapshot, then click by ref.")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if let x = double(args, "x"), let y = double(args, "y") {
            let scale = max(tab.agentScreenshotScale, 0.05)
            let point = CGPoint(x: x / scale, y: y / scale)
            var target = target(from: try? await js(tab, "__wink.at(\(point.x), \(point.y))"))
                ?? Target(ref: nil, point: point, rect: nil, role: "page", name: "")
            target.point = point
            return target
        }
        throw AgentAccessError(message: "Pass a ref (preferred), text, or x and y.")
    }

    /// The shared path for every action: pause check, guardrails, visible
    /// cursor, the action itself, then waiting for and describing its effect.
    private static func act(_ session: AgentSession, _ tab: Tab, _ description: String, tool: String,
                            target: Target?, risk: ConsequentialAction?, riskVerb: String = "click",
                            changeLimit: Int, _ body: () async throws -> String) async throws -> String {
        try await AgentHub.shared.waitWhilePaused(session)
        if let risk {
            AgentHub.shared.waiting(tab, "Waiting for your OK")
            do {
                try await Guardrails.check(risk, session: session, tab: tab, verb: riskVerb)
            } catch {
                AgentHub.shared.scheduleIdle(tab)
                throw error
            }
        }
        try Task.checkCancellation()
        return try await run(session, tab, description, symbol: symbol(for: tool), consequential: risk != nil) {
            defer { AgentVisuals.done(tab) }
            if let target {
                await AgentVisuals.approach(tab, point: target.point, highlight: target.rect, radius: target.radius)
            }
            _ = try? await js(tab, "__wink.watch()")
            let line = try await body()
            let settled = await settle(tab, patient: risk != nil)
            return line + (await changes(tab, settled, near: target, limit: changeLimit))
        }
    }

    private static func perform(_ action: String, _ args: [String: Any], _ session: AgentSession, _ tab: Tab,
                                inBatch: Bool) async throws -> String {
        let limit = inBatch ? 10 : 22
        switch action {
        case "click":
            let target = try await resolveTarget(tab, args, wait: inBatch ? 4 : 1.5)
            let clicks = (bool(args, "double_click") ?? false) ? 2 : 1
            return try await act(session, tab, "Clicking \(target.label)", tool: "click", target: target,
                                 risk: target.risk, changeLimit: limit) {
                AgentVisuals.press(tab, at: target.point)
                try await tab.cdp.click(x: target.point.x, y: target.point.y, clickCount: clicks)
                var line = "Clicked \(target.phrase)"
                if let ref = target.ref { line += " [ref=\(ref)]" }
                if let cover = target.obscuredBy { line += ". Note: the click point was covered by \(cover)" }
                return line + "."
            }

        case "type":
            guard let ref = string(args, "ref"), let text = args["text"] as? String else {
                throw AgentAccessError(message: "type needs ref and text.")
            }
            let target = try await resolveTarget(tab, ["ref": ref], wait: 0)
            guard target.editable else {
                throw AgentAccessError(message: "Element \(ref) (\(target.role)) is not editable. Click it first or choose an input.")
            }
            if target.sensitive {
                let ok = await AgentHub.shared.confirm(session, tab: tab,
                                                       title: "\(session.name) wants to type into a sensitive field",
                                                       message: "\(URLInput.display(tab.url)) · \(target.label) looks like a password or payment field.")
                guard ok else { throw AgentAccessError(message: "The user did not allow typing into a sensitive field.") }
            }
            let clear = bool(args, "clear") ?? true
            let submit = bool(args, "submit") ?? false
            return try await act(session, tab, "Typing into \(target.label)", tool: "type", target: target,
                                 risk: nil, changeLimit: limit) {
                AgentVisuals.typing(tab, in: target.rect, text: target.sensitive ? nil : text)
                try await tab.cdp.click(x: target.point.x, y: target.point.y)
                _ = try await js(tab, "__wink.prepareTyping(\(jsString(ref)), \(clear))")
                try await tab.cdp.insertText(text)
                let shown = target.sensitive ? "(hidden)" : "“\(text.prefix(60))”"
                var line = "Typed \(shown) into \(target.label)."
                if submit {
                    if let risk = ConsequentialAction(try? await js(tab, "__wink.enterRisk()")) {
                        try await Guardrails.check(risk, session: session, tab: tab, verb: "press")
                    }
                    _ = try? await js(tab, "__wink.watch()")
                    try await tab.cdp.press("Enter")
                    line += " Pressed Enter."
                }
                return line
            }

        case "press_key", "press":
            guard let key = string(args, "key") else { throw AgentAccessError(message: "press_key needs key.") }
            let lower = key.lowercased()
            let isEnter = lower.hasSuffix("enter") || lower.hasSuffix("return")
            let risk = isEnter ? ConsequentialAction(try? await js(tab, "__wink.enterRisk()")) : nil
            return try await act(session, tab, "Pressing \(key)", tool: "press_key", target: nil, risk: risk,
                                 riskVerb: "press", changeLimit: limit) {
                try await tab.cdp.press(key)
                return "Pressed \(key)."
            }

        case "select_option", "select":
            guard let ref = string(args, "ref"), let value = args["value"] as? String else {
                throw AgentAccessError(message: "select_option needs ref and value.")
            }
            let target = try await resolveTarget(tab, ["ref": ref], wait: 0)
            return try await act(session, tab, "Choosing “\(value.prefix(30))”", tool: "select_option", target: target,
                                 risk: nil, changeLimit: limit) {
                let chosen = try await js(tab, "__wink.selectOption(\(jsString(ref)), \(jsString(value)))") as? String ?? value
                return "Selected “\(chosen)” in \(target.label)."
            }

        case "hover":
            guard let ref = string(args, "ref") else { throw AgentAccessError(message: "hover needs ref.") }
            let target = try await resolveTarget(tab, ["ref": ref], wait: 0)
            return try await act(session, tab, "Pointing at \(target.label)", tool: "hover", target: target,
                                 risk: nil, changeLimit: limit) {
                try await tab.cdp.hover(x: target.point.x, y: target.point.y)
                return "Hovering over \(target.phrase)."
            }

        case "scroll":
            let direction = string(args, "direction") ?? "down"
            let amount = int(args, "amount")
            return try await act(session, tab, "Scrolling \(direction)", tool: "scroll", target: nil, risk: nil,
                                 changeLimit: inBatch ? 6 : 12) {
                if let ref = string(args, "ref") {
                    return try await js(tab, "__wink.scrollElement(\(jsString(ref)), \(jsString(direction)), \(amount ?? 0))") as? String ?? "Scrolled."
                }
                if direction == "top" || direction == "bottom" {
                    return try await js(tab, "__wink.scrollElement(null, \(jsString(direction)), 0)") as? String ?? "Scrolled."
                }
                // Wheel events scroll whatever is under the pointer, like a real user.
                let metrics = try await tab.cdp.send("Page.getLayoutMetrics")
                let viewport = metrics["cssVisualViewport"] as? [String: Any] ?? [:]
                let width = viewport["clientWidth"] as? Double ?? 1200
                let height = viewport["clientHeight"] as? Double ?? 800
                let delta = Double(amount ?? Int(height * 0.85))
                let (dx, dy): (Double, Double) = switch direction {
                case "up": (0, -delta)
                case "left": (-delta, 0)
                case "right": (delta, 0)
                default: (0, delta)
                }
                AgentVisuals.scroll(tab, at: CGPoint(x: width / 2, y: height / 2), deltaY: dy)
                try await tab.cdp.scroll(x: width / 2, y: height / 2, deltaX: dx, deltaY: dy)
                try? await Task.sleep(nanoseconds: 120_000_000)
                return try await js(tab, "__wink.position()") as? String ?? "Scrolled."
            }

        case "wait_for", "wait":
            return try await waitStep(args, session, tab)

        case "navigate":
            return try await navigateStep(args, session, tab)

        default:
            throw AgentAccessError(message: "Unknown action “\(action)”. Use click, type, press_key, select_option, hover, scroll, wait_for or navigate.")
        }
    }

    private static func batch(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        guard let steps = args["steps"] as? [[String: Any]], !steps.isEmpty else {
            return .error("batch needs steps, e.g. [{\"action\":\"click\",\"ref\":\"e12\"},{\"action\":\"click\",\"text\":\"Send\"}].")
        }
        guard steps.count <= 25 else { return .error("At most 25 steps per batch.") }
        let tab = try await accessTab(args, session, purpose: "control")
        var lines: [String] = []
        var failed = false
        for (index, step) in steps.enumerated() {
            let action = (step["action"] as? String ?? "").lowercased()
            do {
                try Task.checkCancellation()
                let text = try await perform(action, step, session, tab, inBatch: true)
                lines.append("\(index + 1). " + text.replacingOccurrences(of: "\n", with: "\n   "))
            } catch {
                lines.append("\(index + 1). ✗ \(action): \(error.localizedDescription)")
                let remaining = steps.count - index - 1
                if remaining > 0 { lines.append("Stopped here; \(remaining) step\(remaining == 1 ? "" : "s") not run.") }
                failed = true
                break
            }
        }
        return AgentToolResult(content: [.text(lines.joined(separator: "\n"))], isError: failed)
    }

    private static func waitStep(_ args: [String: Any], _ session: AgentSession, _ tab: Tab) async throws -> String {
        let text = string(args, "text")
        let selector = string(args, "selector")
        guard text != nil || selector != nil else { throw AgentAccessError(message: "wait_for needs text or selector.") }
        let timeout = min(max(int(args, "timeout_ms") ?? 10_000, 100), 60_000)
        let gone = bool(args, "gone") ?? false
        let what = text.map { "“\($0.prefix(30))”" } ?? selector ?? ""
        return try await run(session, tab, "Waiting for \(what)", symbol: symbol(for: "wait_for")) {
            let expression = "__wink.waitFor(\(text.map(jsString) ?? "null"), \(selector.map(jsString) ?? "null"), \(gone), \(timeout))"
            let ok = try await js(tab, expression) as? Bool ?? false
            guard ok else { throw AgentAccessError(message: "Timed out after \(timeout) ms waiting for \(what).") }
            return gone ? "\(what) is gone." : "\(what) appeared."
        }
    }

    private static func waitFor(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "read")
        return .text(try await waitStep(args, session, tab))
    }

    // MARK: - Developer tools

    private static func consoleLogs(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "read the console of")
        let level = string(args, "level") ?? "all"
        let limit = min(max(int(args, "limit") ?? 50, 1), 400)
        let entries = tab.console.elements.filter { entry in
            switch level {
            case "error": return entry.level == .error
            case "warning": return entry.level == .error || entry.level == .warning
            default: return true
            }
        }.suffix(limit)
        if entries.isEmpty { return .text("No console messages (\(level)).") }
        let names: [WinkConsoleLevel: String] = [.debug: "debug", .info: "info", .warning: "warning", .error: "error"]
        return .text(entries.map { entry in
            let source = entry.source.isEmpty ? "" : " (\(URLInput.display(entry.source)):\(entry.line))"
            return "[\(names[entry.level] ?? "log")] \(entry.message.prefix(2000))\(source)"
        }.joined(separator: "\n"))
    }

    private static func networkRequests(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "inspect network traffic of")
        let filter = string(args, "filter") ?? "all"
        let limit = min(max(int(args, "limit") ?? 50, 1), 400)
        let entries = (tab.webView?.recentNetworkEntries() ?? []).filter { entry in
            switch filter {
            case "failed": return entry.failed || entry.statusCode >= 400
            case "fetch": return entry.resourceType == "fetch"
            case "blocked": return entry.blocked
            default: return true
            }
        }.suffix(limit)
        if entries.isEmpty { return .text("No matching requests.") }
        return .text(entries.map { entry in
            let status = entry.blocked ? "BLOCKED" : (entry.failed ? "FAILED" : "\(entry.statusCode)")
            let size = entry.bytes > 0 ? " \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))" : ""
            return "\(entry.method) \(status) [\(entry.resourceType)]\(size) \(entry.url)"
        }.joined(separator: "\n"))
    }

    private static func evaluate(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        guard WinkSettings.shared.allowAgentJavaScript else {
            return .error("Running JavaScript is disabled. The user can enable it in Wink Settings › Agents.")
        }
        guard let expression = string(args, "expression") else { return .error("evaluate needs expression.") }
        let tab = try await accessTab(args, session, purpose: "run JavaScript in")
        try await AgentHub.shared.waitWhilePaused(session)
        return try await run(session, tab, "Running a script", symbol: symbol(for: "evaluate")) {
            let value = try await tab.cdp.evaluateInPage(expression)
            guard let value, !(value is NSNull) else { return .text("undefined") }
            if let string = value as? String { return .text(String(string.prefix(50_000))) }
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted])) ?? Data()
            return .text(String((String(data: data, encoding: .utf8) ?? "\(value)").prefix(50_000)))
        }
    }

    // MARK: - Claude Code permission prompts

    private static func approve(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        guard session.trusted else { return .error("Not available.") }
        let toolName = string(args, "tool_name") ?? "a tool"
        let input = args["input"] as? [String: Any] ?? [:]
        let preview: String
        if let command = input["command"] as? String {
            preview = command
        } else if let path = input["file_path"] as? String ?? input["path"] as? String {
            preview = path
        } else {
            let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
            preview = String((String(data: data, encoding: .utf8) ?? "").prefix(300))
        }
        let choice = await AgentHub.shared.prompt(symbol: "terminal", title: "\(session.name) wants to use \(toolName)",
                                                  message: preview, options: ["Deny", "Allow"], tab: nil)
        let decision: [String: Any] = choice == 1
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": "The user denied this action in Wink."]
        let data = try JSONSerialization.data(withJSONObject: decision)
        return .text(String(data: data, encoding: .utf8) ?? "{}")
    }
}
