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
        "description": "Tab id (default: your last tab).",
    ]
    private static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    private static let stepSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["click", "type", "press_key", "select_option", "hover", "scroll", "wait_for", "navigate"]],
            "ref": prop("string", "Element ref."),
            "selector": prop("string", "CSS selector of the element to act on (wait_for: to wait for)."),
            "label": prop("string", "type/select_option: the field's label, placeholder or name."),
            "text": prop("string", "click: visible text to click; type: text to type; wait_for: text."),
            "x": prop("number", "click: x."), "y": prop("number", "click: y."),
            "key": prop("string", "press_key: key."),
            "value": prop("string", "select_option: option."),
            "url": prop("string", "navigate: URL."),
            "direction": ["type": "string", "enum": ["up", "down", "left", "right", "top", "bottom"]],
            "amount": prop("integer", "scroll: pixels."),
            "clear": prop("boolean", "type: replace text (default true)."),
            "submit": prop("boolean", "type: press Enter after."),
            "gone": prop("boolean", "wait_for: until gone."),
            "timeout_ms": prop("integer", "wait_for: max wait."),
            "double_click": prop("boolean", "click: double-click."),
        ],
        "required": ["action"],
        "additionalProperties": false,
    ]

    private static let expectSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "text": prop("string", "Text that must be on the page."),
            "ref": prop("string", "Element to check."),
            "checked": prop("boolean", "ref is checked / unchecked."),
            "value": prop("string", "ref has this value."),
            "visible": prop("boolean", "ref is visible / hidden."),
        ],
        "additionalProperties": false,
    ]

    static let definitions: [AgentToolDefinition] = [
        .init(name: "tabs_list", description: "List the tabs you can use: yours and ones the user shared.",
              properties: [:], required: [], readOnly: true),
        .init(name: "get_active_tab",
              description: "Ask for the tab the user is viewing (they may be asked). Use when they say 'this page'.",
              properties: [:], required: [], readOnly: true),
        .init(name: "tab_open", description: "Open a URL in a new tab of yours and wait for it to load. Returns its tab_id.",
              properties: ["url": prop("string", "Absolute URL."),
                           "focus": prop("boolean", "Show it to the user (default: background).")],
              required: ["url"], readOnly: false),
        .init(name: "tab_close", description: "Close a tab you opened.",
              properties: ["tab_id": tabID], required: ["tab_id"], readOnly: false),
        .init(name: "tab_focus", description: "Show a tab to the user.",
              properties: ["tab_id": tabID], required: ["tab_id"], readOnly: false),
        .init(name: "navigate", description: "Load a URL in the tab and wait for it.",
              properties: ["url": prop("string", "Absolute URL."), "tab_id": tabID], required: ["url"], readOnly: false),
        .init(name: "go_back", description: "Go back.", properties: ["tab_id": tabID], required: [], readOnly: false),
        .init(name: "go_forward", description: "Go forward.", properties: ["tab_id": tabID], required: [], readOnly: false),
        .init(name: "reload", description: "Reload the page.", properties: ["tab_id": tabID], required: [], readOnly: false),
        .init(name: "find",
              description: "Find elements whose label or text contains `text`: refs plus the row or card each sits in. Much cheaper than snapshot.",
              properties: ["text": prop("string", "Text to look for (case-insensitive)."),
                           "role": prop("string", "Role filter: button, link, textbox, checkbox, heading…"),
                           "max": prop("integer", "Max matches (default 25)."), "tab_id": tabID],
              required: [], readOnly: true),
        .init(name: "snapshot",
              description: "Accessibility outline of the page with refs, for an overview. Actions already report what they changed.",
              properties: ["viewport_only": prop("boolean", "Only what's scrolled into view."),
                           "max_lines": prop("integer", "Max lines (default 500)."), "tab_id": tabID],
              required: [], readOnly: true),
        .init(name: "read_page",
              description: "The page's readable content as Markdown. With match, only the paragraphs, list items and table rows that mention it: the cheap way to read one fact from a long page.",
              properties: ["match": prop("string", "Only parts containing this (case-insensitive)."),
                           "max_chars": prop("integer", "Max characters (default 20000)."), "tab_id": tabID],
              required: [], readOnly: true),
        .init(name: "screenshot",
              description: "JPEG of the tab. Image pixels = CSS pixels, so x/y can go straight to click; labels:true draws refs.",
              properties: ["labels": prop("boolean", "Draw element refs."),
                           "full_page": prop("boolean", "Whole page, not just the viewport."), "tab_id": tabID],
              required: [], readOnly: true),
        .init(name: "click",
              description: "Click by ref (best), CSS selector, visible text, or x/y. Returns what changed: dialogs, notices, new/changed/gone elements, updated texts. Refs survive re-renders.",
              properties: ["ref": prop("string", "Element ref, e.g. e12."), "selector": prop("string", "CSS selector."),
                           "text": prop("string", "Visible label, if you have no ref."),
                           "x": prop("number", "x from your latest screenshot."), "y": prop("number", "y."),
                           "double_click": prop("boolean", "Double-click."),
                           "button": ["type": "string", "enum": ["left", "right", "middle"]], "tab_id": tabID],
              required: [], readOnly: false),
        .init(name: "type",
              description: "Type into a field (by ref, CSS selector or label); replaces its text unless clear:false, submit:true presses Enter. Checks the text landed.",
              properties: ["ref": prop("string", "Field ref."), "selector": prop("string", "CSS selector."),
                           "label": prop("string", "The field's label, placeholder or name."), "text": prop("string", "Text."),
                           "clear": prop("boolean", "Replace current text (default true)."),
                           "submit": prop("boolean", "Press Enter after."), "tab_id": tabID],
              required: ["text"], readOnly: false),
        .init(name: "fill_form",
              description: "Fill many fields in one call. value: text for text fields, an option for selects, true/false for checkboxes, radios and switches.",
              properties: ["fields": ["type": "array", "description": "Fields in order.",
                                      "items": ["type": "object", "properties": ["ref": prop("string", "Field ref."), "value": prop("string", "Value.")],
                                                "required": ["ref", "value"], "additionalProperties": false]],
                           "tab_id": tabID],
              required: ["fields"], readOnly: false),
        .init(name: "press_key", description: "Press a key or shortcut: Enter, Escape, Tab, ArrowDown, Meta+A…",
              properties: ["key": prop("string", "Key, modifiers joined by '+'."), "tab_id": tabID],
              required: ["key"], readOnly: false),
        .init(name: "select_option", description: "Choose a <select> option by value or text.",
              properties: ["ref": prop("string", "Select ref."), "selector": prop("string", "CSS selector."),
                           "label": prop("string", "The select's label."), "value": prop("string", "Option."), "tab_id": tabID],
              required: ["value"], readOnly: false),
        .init(name: "hover", description: "Hover an element; returns menus or tooltips that opened.",
              properties: ["ref": prop("string", "Element ref."), "selector": prop("string", "CSS selector."), "tab_id": tabID],
              required: [], readOnly: false),
        .init(name: "drag", description: "Drag an element onto another (HTML5 drag and drop or pointer-based). Give each end by ref or by visible text.",
              properties: ["from_ref": prop("string", "What to drag."), "to_ref": prop("string", "Where to drop it."),
                           "from_text": prop("string", "Or: text shown on what to drag."),
                           "to_text": prop("string", "Or: text shown where to drop (e.g. a column title)."), "tab_id": tabID],
              required: [], readOnly: false),
        .init(name: "upload_file",
              description: "Attach files to a file input (its ref, or its button's). Outside localhost the user approves.",
              properties: ["ref": prop("string", "File input or upload button ref."),
                           "paths": ["type": "array", "items": ["type": "string"], "description": "Absolute file paths."],
                           "tab_id": tabID],
              required: ["ref", "paths"], readOnly: false),
        .init(name: "scroll", description: "Scroll the page, or an element by ref. Returns the position and new items.",
              properties: ["direction": ["type": "string", "enum": ["up", "down", "left", "right", "top", "bottom"]],
                           "amount": prop("integer", "Pixels (default: most of a screen)."),
                           "ref": prop("string", "Scrollable element."), "tab_id": tabID],
              required: ["direction"], readOnly: false),
        .init(name: "batch",
              description: "Run a whole flow in one call, across page loads: up to 40 steps of navigate, click, type, select_option, press_key, hover, scroll, wait_for. Target by ref, CSS selector, visible text or field label, so a flow you know needs no lookup first. Each step waits for its element and the page; stops at the first failure.",
              properties: ["steps": ["type": "array", "items": stepSchema, "description": "Steps in order."], "tab_id": tabID],
              required: ["steps"], readOnly: false),
        .init(name: "wait_for", description: "Wait for text or a CSS selector to appear (gone:true: disappear).",
              properties: ["text": prop("string", "Text."), "selector": prop("string", "CSS selector."),
                           "gone": prop("boolean", "Wait until gone."),
                           "timeout_ms": prop("integer", "Max wait (default 10000, max 60000)."), "tab_id": tabID],
              required: [], readOnly: true),
        .init(name: "handle_dialog", description: "Answer the open JavaScript alert, confirm or prompt.",
              properties: ["accept": prop("boolean", "OK (true) or Cancel (false)."),
                           "prompt_text": prop("string", "Text for a prompt."), "tab_id": tabID],
              required: ["accept"], readOnly: false),
        .init(name: "get_selection", description: "The text the user selected in the tab.",
              properties: ["tab_id": tabID], required: [], readOnly: true),
        .init(name: "console_logs", description: "The tab's console messages.",
              properties: ["level": ["type": "string", "enum": ["error", "warning", "all"]],
                           "limit": prop("integer", "Max entries (default 50)."), "tab_id": tabID],
              required: [], readOnly: true),
        .init(name: "network_requests",
              description: "Requests the page made (method, status, type, size, URL), failed and blocked ones included. url: one request in full, with headers and request and response bodies.",
              properties: ["filter": ["type": "string", "enum": ["all", "failed", "fetch", "blocked"]],
                           "url": prop("string", "Part of a request's URL, for its full details."),
                           "limit": prop("integer", "Max entries (default 50)."), "tab_id": tabID],
              required: [], readOnly: true),
        .init(name: "evaluate",
              description: "Run JavaScript in the page; returns the JSON result. Always allowed on localhost, 127.0.0.1 and *.test; elsewhere only if the user enabled it.",
              properties: ["expression": prop("string", "Expression; may return a Promise."), "tab_id": tabID],
              required: ["expression"], readOnly: false),
        .init(name: "emulate",
              description: "Make your tab look like a phone, tablet or other size, in dark mode or with reduced motion. reset:true undoes it.",
              properties: ["device": ["type": "string", "enum": ["iphone", "ipad", "android", "desktop"]],
                           "width": prop("integer", "Viewport width."), "height": prop("integer", "Viewport height."),
                           "color_scheme": ["type": "string", "enum": ["light", "dark"]],
                           "reduced_motion": prop("boolean", "Prefer reduced motion."),
                           "reset": prop("boolean", "Back to normal."), "tab_id": tabID],
              required: [], readOnly: false),
        .init(name: "mock_network",
              description: "In your tab: make requests whose URL contains url return status/body (or fail with block:true), go offline, or clear:true every mock.",
              properties: ["url": prop("string", "Part of the URL; * matches anything."),
                           "status": prop("integer", "Status (default 200)."), "body": prop("string", "Response body."),
                           "content_type": prop("string", "Default application/json."), "block": prop("boolean", "Fail the request instead."),
                           "offline": prop("boolean", "Take the tab offline (or back online)."),
                           "clear": prop("boolean", "Remove all mocks."), "tab_id": tabID],
              required: [], readOnly: false),
        .init(name: "storage",
              description: "The page's cookies, localStorage and sessionStorage: get (default), set, delete or clear. Values outside localhost stay hidden.",
              properties: ["action": ["type": "string", "enum": ["get", "set", "delete", "clear"]],
                           "kind": ["type": "string", "enum": ["cookies", "local", "session"]],
                           "name": prop("string", "Key or cookie name."), "value": prop("string", "Value to set."), "tab_id": tabID],
              required: [], readOnly: false),
        .init(name: "save_pdf", description: "Save the page as a PDF in Downloads; returns its path.",
              properties: ["tab_id": tabID], required: [], readOnly: false),
        .init(name: "record", description: "Video of the tab: start, then stop to get the .mp4 (saved in Downloads).",
              properties: ["action": ["type": "string", "enum": ["start", "stop"]], "tab_id": tabID],
              required: ["action"], readOnly: false),
        .init(name: "verify", description: "Check the live page: each expect passes or fails (text on the page, or a ref checked, with a value, or visible).",
              properties: ["expect": ["type": "array", "items": expectSchema, "description": "Checks."], "tab_id": tabID],
              required: ["expect"], readOnly: true),
        .init(name: "trace", description: "Trace your tab step by step: start, then stop to save an HTML timeline (each step's result, a screenshot, console and network) in Downloads.",
              properties: ["action": ["type": "string", "enum": ["start", "stop"]], "tab_id": tabID],
              required: ["action"], readOnly: false),
        .init(name: "export_test",
              description: "Turn the steps you took in this tab into a Playwright test (TypeScript), with expect checks verified on the live page first. Save it with your own file tools.",
              properties: ["name": prop("string", "Test name."),
                           "expect": ["type": "array", "items": expectSchema, "description": "Checks to end the test with."],
                           "tab_id": tabID],
              required: [], readOnly: true),
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
        var list = externalDefinitions
        if session.trusted && session.origin == .mcp { list.append(approvalTool) }
        return list
    }

    /// The tools any connected agent gets.
    static var externalDefinitions: [AgentToolDefinition] { definitions }

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
        case "fill_form": "list.bullet.rectangle"
        case "drag": "hand.draw"
        case "upload_file": "paperclip"
        case "handle_dialog": "exclamationmark.bubble"
        case "emulate": "iphone"
        case "export_test": "checkmark.seal"
        case "mock_network": "arrow.left.arrow.right"
        case "storage": "tray.full"
        case "save_pdf": "doc.richtext"
        case "record": "record.circle"
        case "verify": "checkmark.circle"
        case "trace": "list.bullet.clipboard"
        case "tabs_list", "get_active_tab": "square.on.square"
        default: "sparkle"
        }
    }

    // MARK: - Dispatch

    static func call(_ name: String, _ args: [String: Any], session: AgentSession) async -> AgentToolResult {
        let began = Date()
        let result = await dispatch(name, args, session: session)
        // A traced tab records every step, with a screenshot after each action.
        if name != "trace", let id = session.currentTabID,
           let tab = AppDelegate.shared?.allTabs.first(where: { $0.id == id }), let trace = tab.instruments.trace {
            let acts = !(definitions.first { $0.name == name }?.readOnly ?? true)
            var shot: Data?
            if acts && tab.instruments.dialog == nil {
                shot = try? await tab.cdp.screenshot(maxWidth: 960, quality: 58).data
            }
            trace.add(tool: name, args: traceArgs(args), result: result, began: began, screenshot: shot, tab: tab)
        }
        return result
    }

    /// Arguments as one line for a trace, with typed text kept out of it.
    private static func traceArgs(_ args: [String: Any]) -> String {
        var shown = args
        for key in ["text", "value", "body", "prompt_text", "expression"] where shown[key] != nil {
            if let text = shown[key] as? String { shown[key] = text.count > 60 ? String(text.prefix(60)) + "…" : text }
        }
        if var fields = shown["fields"] as? [[String: Any]] {
            for i in fields.indices { fields[i]["value"] = "…" }
            shown["fields"] = fields
        }
        let data = (try? JSONSerialization.data(withJSONObject: shown, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func dispatch(_ name: String, _ args: [String: Any], session: AgentSession) async -> AgentToolResult {
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
            case "fill_form": return try await fillForm(args, session)
            case "drag": return try await drag(args, session)
            case "upload_file": return try await uploadFile(args, session)
            case "handle_dialog": return try await handleDialog(args, session)
            case "emulate": return try await emulate(args, session)
            case "export_test": return try await exportTest(args, session)
            case "mock_network": return try await mockNetwork(args, session)
            case "storage": return try await storage(args, session)
            case "save_pdf": return try await savePDF(args, session)
            case "record": return try await record(args, session)
            case "verify": return try await verify(args, session)
            case "trace": return try await trace(args, session)
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
        await tab.instruments.start()
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

    private enum Settled { case navigated, quiet, idle, busy, dialog }

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
            if tab.instruments.dialog != nil { return .dialog }
            if tab.isLoading { break }
            let elapsed = Date().timeIntervalSince(start)
            let value = (try? await tab.cdp.evaluateAgent("__wink.muts()", timeout: 5)) as? [Any]
            if tab.instruments.dialog != nil { return .dialog }
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
        if settled == .dialog, let dialog = tab.instruments.dialog {
            let kind = dialog.type == "beforeunload" ? "“Leave page?” dialog" : "JavaScript \(dialog.type)"
            return "\n\(kind) is open: “\(dialog.message.prefix(300))”. The page waits until you answer with handle_dialog (accept true or false)."
        }
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
        if let dialog = tab.instruments.dialog {
            throw AgentAccessError(message: "A JavaScript \(dialog.type) is open (“\(dialog.message.prefix(120))”) and the page is waiting. Answer it with handle_dialog first.")
        }
        return try await tab.cdp.evaluateAgent(expression)
    }

    /// Real (trusted) input first. If the page never saw it (Chromium drops
    /// input while the Mac's display sleeps or the screen is locked), the same
    /// events are played from inside the page, so agents keep working while
    /// the user is away.
    private static func deliver(_ tab: Tab, expecting event: String, fallback: String,
                                _ trusted: () async throws -> Void) async throws {
        _ = try? await js(tab, "__wink.armInput(\(jsString(event)))")
        try await trusted()
        if tab.instruments.dialog != nil { return }  // it worked: a dialog opened
        let arrived = (try? await tab.cdp.evaluateAgent("__wink.inputArrived()", timeout: 3)) as? Bool ?? true
        if arrived { return }
        do {
            _ = try await js(tab, fallback)
        } catch where tab.instruments.dialog != nil {
            // The replayed input opened a JavaScript dialog: that's its effect.
        }
    }

    private static func pressKey(_ tab: Tab, _ combo: String) async throws {
        let key = KeyDescriptor.parse(combo)
        let fallback = "__wink.syntheticKey(\(jsString(key.key)), \(jsString(key.code)), \(key.keyCode), \(key.text.map(jsString) ?? "null"), \(key.modifiers))"
        try await deliver(tab, expecting: "keydown", fallback: fallback) { try await tab.cdp.press(combo) }
    }

    /// How a Playwright test should find the element behind a ref.
    private static func locator(_ tab: Tab, _ ref: String?) async -> [String: Any]? {
        guard let ref else { return nil }
        return (try? await js(tab, "__wink.locatorOf(\(jsString(ref)))")) as? [String: Any]
    }

    /// Clicks into the field and types like a person, then checks the text
    /// landed; if it didn't (custom inputs, lost focus), sets it directly.
    /// Returns a note for the agent, empty when all went well.
    private static func typeVerified(_ tab: Tab, target: Target, ref: String, text: String, clear: Bool) async throws -> String {
        try await tab.cdp.click(x: target.point.x, y: target.point.y)
        _ = try await js(tab, "__wink.prepareTyping(\(jsString(ref)), \(clear))")
        try await tab.cdp.insertText(text)
        let normalize = { (value: String) in value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined() }
        let want = normalize(text)
        let landed = { (value: String) in want.isEmpty || normalize(value).contains(want) }
        let read = { (try? await js(tab, "__wink.valueOf(\(jsString(ref)))")) as? String ?? "" }
        if landed(await read()) { return "" }
        try? await Task.sleep(nanoseconds: 80_000_000)  // debounced inputs
        if landed(await read()) { return "" }
        let after = (try? await js(tab, "__wink.setValue(\(jsString(ref)), \(jsString(text)), \(clear))")) as? String ?? ""
        if landed(after) { return " (Set directly: the field didn't take keystrokes.)" }
        return target.sensitive
            ? " Warning: the field may not have accepted the text."
            : " Warning: the field shows “\(after.prefix(60))”, not the typed text; it may format or reject input."
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
            await tab.instruments.start()
            await settleNavigation(tab, since: issued, startedWithin: 3)
            tab.instruments.record(.init(kind: .goto, locator: [:], value: url), session: session)
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
            tab.instruments.record(.init(kind: .goto, locator: [:], value: url), session: session)
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
            let kind: AgentInstruments.Step.Kind = action == "go_back" ? .back : action == "go_forward" ? .forward : .reload
            tab.instruments.record(.init(kind: kind, locator: [:], value: ""), session: session)
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
        let match = string(args, "match") ?? ""
        return try await run(session, tab, match.isEmpty ? "Reading the page" : "Looking for “\(match.prefix(30))”", symbol: symbol(for: "read_page")) {
            AgentVisuals.scan(tab)
            let result = try await js(tab, "__wink.read(\(maxChars), \(jsString(match)))")
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
        // A CSS selector or a field label: waited for briefly, since the step
        // before may have just loaded the page.
        let lookup: (expression: String, what: String)? =
            string(args, "selector").map { ("__wink.refBySelector(\(jsString($0)))", "matching “\($0)”") }
            ?? string(args, "label").map { ("__wink.fieldByLabel(\(jsString($0)))", "labelled “\($0)”") }
        if string(args, "ref") == nil, let lookup {
            let deadline = Date().addingTimeInterval(max(wait, 1))
            while true {
                if let ref = try? await js(tab, lookup.expression) as? String,
                   let target = target(from: try await js(tab, "__wink.locate(\(jsString(ref)))")) {
                    return target
                }
                if Date() > deadline {
                    throw AgentAccessError(message: "No visible element \(lookup.what). Use find or snapshot for refs.")
                }
                try await Task.sleep(nanoseconds: 120_000_000)
            }
        }
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
        let recorder = tab.instruments
        if recorder.steps(for: session).isEmpty, !tab.url.isEmpty {
            recorder.record(.init(kind: .goto, locator: [:], value: tab.url), session: session)
        }
        switch action {
        case "click":
            let target = try await resolveTarget(tab, args, wait: inBatch ? 6 : 1.5)
            let double = bool(args, "double_click") ?? false
            let clicks = double ? 2 : 1
            let button = string(args, "button") ?? "left"
            let locator = await locator(tab, target.ref)
            let result = try await act(session, tab, "Clicking \(target.label)", tool: "click", target: target,
                                       risk: target.risk, changeLimit: limit) {
                AgentVisuals.press(tab, at: target.point)
                try await deliver(tab, expecting: button == "right" ? "contextmenu" : "mousedown",
                                  fallback: "__wink.syntheticClick(\(target.point.x), \(target.point.y), \(jsString(button)), \(clicks))") {
                    try await tab.cdp.click(x: target.point.x, y: target.point.y, button: button, clickCount: clicks)
                }
                var line = "Clicked \(target.phrase)"
                if let ref = target.ref { line += " [ref=\(ref)]" }
                if let cover = target.obscuredBy { line += ". Note: the click point was covered by \(cover)" }
                return line + "."
            }
            if let locator {
                recorder.record(.init(kind: double ? .doubleClick : .click, locator: locator, value: button), session: session)
            }
            return result

        case "type":
            guard let text = args["text"] as? String,
                  string(args, "ref") != nil || string(args, "selector") != nil || string(args, "label") != nil else {
                throw AgentAccessError(message: "type needs text, and the field's ref, selector or label.")
            }
            let target = try await resolveTarget(tab, args, wait: inBatch ? 6 : 2)
            guard let ref = target.ref else { throw AgentAccessError(message: "Could not find that field.") }
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
            let locator = await locator(tab, ref)
            let result = try await act(session, tab, "Typing into \(target.label)", tool: "type", target: target,
                                       risk: nil, changeLimit: limit) {
                AgentVisuals.typing(tab, in: target.rect, text: target.sensitive ? nil : text)
                let note = try await typeVerified(tab, target: target, ref: ref, text: text, clear: clear)
                let shown = target.sensitive ? "(hidden)" : "“\(text.prefix(60))”"
                var line = "Typed \(shown) into \(target.label).\(note)"
                if submit {
                    if let risk = ConsequentialAction(try? await js(tab, "__wink.enterRisk()")) {
                        try await Guardrails.check(risk, session: session, tab: tab, verb: "press")
                    }
                    _ = try? await js(tab, "__wink.watch()")
                    try await pressKey(tab, "Enter")
                    line += " Pressed Enter."
                }
                return line
            }
            if let locator {
                recorder.record(.init(kind: .fill, locator: locator, value: text, sensitive: target.sensitive), session: session)
                if submit { recorder.record(.init(kind: .press, locator: locator, value: "Enter"), session: session) }
            }
            return result

        case "press_key", "press":
            guard let key = string(args, "key") else { throw AgentAccessError(message: "press_key needs key.") }
            let lower = key.lowercased()
            let isEnter = lower.hasSuffix("enter") || lower.hasSuffix("return")
            let risk = isEnter ? ConsequentialAction(try? await js(tab, "__wink.enterRisk()")) : nil
            let result = try await act(session, tab, "Pressing \(key)", tool: "press_key", target: nil, risk: risk,
                                       riskVerb: "press", changeLimit: limit) {
                try await pressKey(tab, key)
                return "Pressed \(key)."
            }
            recorder.record(.init(kind: .press, locator: [:], value: key), session: session)
            return result

        case "select_option", "select":
            guard let value = args["value"] as? String,
                  string(args, "ref") != nil || string(args, "selector") != nil || string(args, "label") != nil else {
                throw AgentAccessError(message: "select_option needs value, and the select's ref, selector or label.")
            }
            let target = try await resolveTarget(tab, args, wait: inBatch ? 6 : 2)
            guard let ref = target.ref else { throw AgentAccessError(message: "Could not find that select.") }
            let locator = await locator(tab, ref)
            var chosenLabel = value
            let result = try await act(session, tab, "Choosing “\(value.prefix(30))”", tool: "select_option", target: target,
                                       risk: nil, changeLimit: limit) {
                let chosen = try await js(tab, "__wink.selectOption(\(jsString(ref)), \(jsString(value)))") as? String ?? value
                chosenLabel = chosen
                return "Selected “\(chosen)” in \(target.label)."
            }
            if let locator { recorder.record(.init(kind: .select, locator: locator, value: chosenLabel), session: session) }
            return result

        case "hover":
            guard string(args, "ref") != nil || string(args, "selector") != nil else { throw AgentAccessError(message: "hover needs ref or selector.") }
            let target = try await resolveTarget(tab, args, wait: inBatch ? 6 : 1)
            guard let ref = target.ref else { throw AgentAccessError(message: "Could not find that element.") }
            let locator = await locator(tab, ref)
            let result = try await act(session, tab, "Pointing at \(target.label)", tool: "hover", target: target,
                                       risk: nil, changeLimit: limit) {
                try await deliver(tab, expecting: "mouseover", fallback: "__wink.syntheticHover(\(target.point.x), \(target.point.y))") {
                    try await tab.cdp.hover(x: target.point.x, y: target.point.y)
                }
                return "Hovering over \(target.phrase)."
            }
            if let locator { recorder.record(.init(kind: .hover, locator: locator, value: ""), session: session) }
            return result

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
                try await deliver(tab, expecting: "wheel", fallback: "__wink.scrollElement(null, \(jsString(direction)), \(Int(abs(dx + dy))))") {
                    try await tab.cdp.scroll(x: width / 2, y: height / 2, deltaX: dx, deltaY: dy)
                }
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
        guard steps.count <= 40 else { return .error("At most 40 steps per batch.") }
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
        if let fragment = string(args, "url") { return await networkDetail(tab, fragment) }
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
        }.joined(separator: "\n") + "\n(network_requests url:<part of a URL> shows one request in full.)")
    }

    private static let hiddenHeaders: Set<String> = ["cookie", "set-cookie", "authorization", "proxy-authorization", "x-api-key", "x-auth-token", "x-csrf-token"]

    private static func networkDetail(_ tab: Tab, _ fragment: String) async -> AgentToolResult {
        guard let request = tab.instruments.request(matching: fragment) else {
            return .text("No request recorded whose URL contains “\(fragment)”. Wink keeps details from when an agent first used this tab: reload or repeat the action, then ask again.")
        }
        var out = ["\(request.method) \(request.url)"]
        if let status = request.status {
            out.append("→ \(status) \(request.statusText)\(request.mimeType.isEmpty ? "" : " (\(request.mimeType))")")
        } else {
            out.append("→ \(request.failure ?? (request.finished ? "no response" : "pending"))")
        }
        let headers = { (headers: [String: String]) in
            headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { key, value in
                "  \(key): \(hiddenHeaders.contains(key.lowercased()) ? "(hidden)" : String(value.prefix(300)))"
            }.joined(separator: "\n")
        }
        out.append("Request headers:\n" + headers(request.requestHeaders))
        if let body = request.postData, !body.isEmpty {
            out.append("Request body:\n" + String(body.prefix(4000)) + (body.count > 4000 ? "\n…" : ""))
        }
        if request.status != nil {
            out.append("Response headers:\n" + headers(request.responseHeaders))
            if let body = await tab.instruments.responseBody(request), !body.isEmpty {
                out.append("Response body:\n" + String(body.prefix(6000)) + (body.count > 6000 ? "\n… (\(body.count) characters)" : ""))
            }
        }
        return .text(out.joined(separator: "\n"))
    }

    private static func evaluate(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        guard let expression = string(args, "expression") else { return .error("evaluate needs expression.") }
        let tab = try await accessTab(args, session, purpose: "run JavaScript in")
        guard WinkSettings.shared.allowAgentJavaScript || Site.isLocalDevelopment(Site.host(of: tab.url)) else {
            return .error("JavaScript is allowed on localhost, 127.0.0.1 and *.test; on other sites only if the user enables it in Wink Settings › Agents. Use read_page (with match), find or snapshot instead.")
        }
        try await AgentHub.shared.waitWhilePaused(session)
        return try await run(session, tab, "Running a script", symbol: symbol(for: "evaluate")) {
            let value = try await tab.cdp.evaluateInPage(expression)
            guard let value, !(value is NSNull) else { return .text("undefined") }
            if let string = value as? String { return .text(String(string.prefix(50_000))) }
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .prettyPrinted])) ?? Data()
            return .text(String((String(data: data, encoding: .utf8) ?? "\(value)").prefix(50_000)))
        }
    }

    // MARK: - Forms, files, drag and drop, dialogs

    /// Fills every field in one action: one wait for the page to settle and
    /// one report of what changed at the end, not one per field.
    private static func fillForm(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        guard let fields = args["fields"] as? [[String: Any]], !fields.isEmpty else {
            return .error("fill_form needs fields, e.g. [{\"ref\":\"e3\",\"value\":\"Ada\"},{\"ref\":\"e7\",\"value\":\"true\"}].")
        }
        guard fields.count <= 40 else { return .error("At most 40 fields per call.") }
        let tab = try await accessTab(args, session, purpose: "control")
        let recorder = tab.instruments
        if recorder.steps(for: session).isEmpty, !tab.url.isEmpty {
            recorder.record(.init(kind: .goto, locator: [:], value: tab.url), session: session)
        }
        // Resolve everything first, so a bad ref fails before anything is typed.
        var plan: [(ref: String, value: String, target: Target, locator: [String: Any]?)] = []
        for field in fields {
            guard let ref = string(field, "ref") else { return .error("Every field needs a ref.") }
            let value: String = (field["value"] as? String) ?? (field["value"] as? Bool).map { $0 ? "true" : "false" }
                ?? (field["value"] as? NSNumber)?.stringValue ?? ""
            let target = try await resolveTarget(tab, ["ref": ref], wait: 0)
            if target.sensitive {
                let ok = await AgentHub.shared.confirm(session, tab: tab, title: "\(session.name) wants to type into a sensitive field",
                                                       message: "\(URLInput.display(tab.url)) · \(target.label) looks like a password or payment field.")
                guard ok else { return .error("The user did not allow typing into \(target.label).") }
            }
            plan.append((ref, value, target, await locator(tab, ref)))
        }
        var lines: [String] = []
        let text = try await act(session, tab, "Filling \(plan.count) field\(plan.count == 1 ? "" : "s")", tool: "fill_form",
                                 target: plan.first?.target, risk: nil, changeLimit: 22) {
            for item in plan {
                try Task.checkCancellation()
                let target = item.target
                switch target.role {
                case "checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio":
                    let want = ["true", "yes", "on", "1", "checked"].contains(item.value.lowercased())
                    let isChecked = (try? await js(tab, "__wink.checkedOf(\(jsString(item.ref)))")) as? Bool ?? false
                    if isChecked != want {
                        AgentVisuals.press(tab, at: target.point)
                        try await deliver(tab, expecting: "mousedown",
                                          fallback: "__wink.syntheticClick(\(target.point.x), \(target.point.y), 'left', 1)") {
                            try await tab.cdp.click(x: target.point.x, y: target.point.y)
                        }
                    }
                    let now = (try? await js(tab, "__wink.checkedOf(\(jsString(item.ref)))")) as? Bool ?? want
                    lines.append(now == want ? "\(want ? "checked" : "unchecked") \(target.label)" : "✗ \(target.label) stayed \(now ? "checked" : "unchecked")")
                    if let locator = item.locator { recorder.record(.init(kind: want ? .check : .uncheck, locator: locator, value: ""), session: session) }
                case "combobox", "listbox" where !target.editable:
                    let chosen = try await js(tab, "__wink.selectOption(\(jsString(item.ref)), \(jsString(item.value)))") as? String ?? item.value
                    lines.append("\(target.label) “\(chosen)”")
                    if let locator = item.locator { recorder.record(.init(kind: .select, locator: locator, value: chosen), session: session) }
                default:
                    guard target.editable else { throw AgentAccessError(message: "Element \(item.ref) (\(target.role)) is not a field.") }
                    AgentVisuals.typing(tab, in: target.rect, text: target.sensitive ? nil : item.value)
                    let note = try await typeVerified(tab, target: target, ref: item.ref, text: item.value, clear: true)
                    lines.append("\(target.label) “\(target.sensitive ? "(hidden)" : String(item.value.prefix(40)))”\(note)")
                    if let locator = item.locator {
                        recorder.record(.init(kind: .fill, locator: locator, value: item.value, sensitive: target.sensitive), session: session)
                    }
                }
            }
            return "Filled " + lines.joined(separator: ", ") + "."
        }
        return .text(text)
    }

    private static func drag(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "control")
        let end = { (refKey: String, textKey: String) async throws -> String? in
            if let ref = string(args, refKey) { return ref }
            guard let text = string(args, textKey) else { return nil }
            return try await js(tab, "__wink.refByText(\(jsString(text)))") as? String
        }
        guard let fromRef = try await end("from_ref", "from_text"), let toRef = try await end("to_ref", "to_text") else {
            return .error("drag needs from_ref or from_text, and to_ref or to_text.")
        }
        _ = try await resolveTarget(tab, ["ref": toRef], wait: 0)  // scrolls the drop zone into view
        let from = try await resolveTarget(tab, ["ref": fromRef], wait: 0)
        let to = try await resolveTarget(tab, ["ref": toRef], wait: 0)
        let fromLocator = await locator(tab, fromRef), toLocator = await locator(tab, toRef)
        let text = try await act(session, tab, "Dragging \(from.label) to \(to.label)", tool: "drag", target: to,
                                 risk: nil, changeLimit: 22) {
            AgentVisuals.press(tab, at: from.point)
            try await deliver(tab, expecting: "mousedown",
                              fallback: "__wink.syntheticDrag(\(from.point.x), \(from.point.y), \(to.point.x), \(to.point.y))") {
                try await tab.cdp.drag(from: from.point, to: to.point)
            }
            return "Dragged \(from.phrase) onto \(to.phrase)."
        }
        if let fromLocator, let toLocator {
            tab.instruments.record(.init(kind: .dragTo, locator: fromLocator, value: "", target: toLocator), session: session)
        }
        return .text(text)
    }

    private static func uploadFile(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        guard let ref = string(args, "ref"), let raw = args["paths"] as? [String], !raw.isEmpty else {
            return .error("upload_file needs ref and paths (absolute file paths).")
        }
        let tab = try await accessTab(args, session, purpose: "control")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        for path in raw {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return .error("No file at \(path).")
            }
            // Secrets stay home: hidden folders (~/.ssh, ~/.aws, …), Library, system folders.
            if url.pathComponents.contains(where: { $0.hasPrefix(".") }) || url.path.hasPrefix(home + "/Library/")
                || ["/etc/", "/private/etc/", "/System/", "/var/root/"].contains(where: { url.path.hasPrefix($0) }) {
                return .error("Wink doesn't let agents upload files from hidden or system folders (\(url.lastPathComponent)).")
            }
            paths.append(url.path)
        }
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        let host = Site.host(of: tab.url)
        if !Site.isLocalDevelopment(host) {
            let ok = await AgentHub.shared.confirm(session, tab: tab, title: "\(session.name) wants to upload \(names)",
                                                   message: "to \(host.isEmpty ? "this page" : host). The files leave your Mac.")
            guard ok else { return .error("The user didn't allow uploading \(names). Don't retry; ask them.") }
        }
        let target = try? await resolveTarget(tab, ["ref": ref], wait: 0)  // file inputs are often hidden
        let inputLocator = (try? await js(tab, "__wink.locatorOf(__wink.refFor(__wink.fileInput(\(jsString(ref)))))")) as? [String: Any]
        let text = try await act(session, tab, "Attaching \(names)", tool: "upload_file", target: target, risk: nil, changeLimit: 22) {
            let objectID = try await tab.cdp.agentObjectID("__wink.fileInput(\(jsString(ref)))")
            _ = try await tab.cdp.send("DOM.setFileInputFiles", ["files": paths, "objectId": objectID])
            return "Attached \(names)."
        }
        if let inputLocator {
            tab.instruments.record(.init(kind: .upload, locator: inputLocator, value: paths.joined(separator: "\n")), session: session)
        }
        return .text(text)
    }

    private static func handleDialog(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try resolveTab(args, session)
        try await AgentHub.shared.authorize(session, tab: tab, purpose: "control")
        guard let dialog = tab.instruments.dialog else { return .error("No JavaScript dialog is open in this tab.") }
        let accept = bool(args, "accept") ?? true
        let promptText = args["prompt_text"] as? String
        return try await run(session, tab, accept ? "Answering OK" : "Answering Cancel", symbol: symbol(for: "handle_dialog")) {
            guard tab.webView?.answerJavaScriptDialog(accept, text: promptText) == true else {
                tab.instruments.dialogHandled()
                return .error("The dialog was already closed.")
            }
            tab.instruments.dialogHandled()
            tab.instruments.record(.init(kind: .dialog, locator: [:], value: accept ? "accept" : "dismiss",
                                         target: promptText.map { ["text": $0] }), session: session)
            let settled = await settle(tab, patient: false)
            let summary = "\(accept ? "Accepted" : "Dismissed") the \(dialog.type) “\(dialog.message.prefix(120))”."
            return .text(summary + (await changes(tab, settled, near: nil, limit: 22)))
        }
    }

    // MARK: - Emulation

    private static let devices: [String: (width: Int, height: Int, scale: Double, mobile: Bool, userAgent: String?)] = [
        "iphone": (390, 844, 3, true, "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"),
        "ipad": (820, 1180, 2, true, "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"),
        "android": (412, 915, 2.625, true, "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Mobile Safari/537.36"),
        "desktop": (1440, 900, 1, false, nil),
    ]

    private static func emulate(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "control")
        let cdp = tab.cdp
        return try await run(session, tab, "Changing how the page is shown", symbol: symbol(for: "emulate")) {
            if bool(args, "reset") == true {
                _ = try? await cdp.send("Emulation.clearDeviceMetricsOverride")
                _ = try? await cdp.send("Emulation.setTouchEmulationEnabled", ["enabled": false])
                _ = try? await cdp.send("Emulation.setEmulatedMedia", ["media": "", "features": [] as [Any]])
                if let agent = tab.instruments.userAgent { _ = try? await cdp.send("Emulation.setUserAgentOverride", ["userAgent": agent]) }
                tab.instruments.emulating = false
                return .text("Back to the normal size, color scheme and motion.")
            }
            var parts: [String] = []
            let device = string(args, "device").flatMap { devices[$0.lowercased()] }
            if string(args, "device") != nil && device == nil { return .error("device is iphone, ipad, android or desktop.") }
            var width = int(args, "width") ?? device?.width
            var height = int(args, "height") ?? device?.height
            if width != nil || height != nil {
                let metrics = try await cdp.send("Page.getLayoutMetrics")
                let viewport = metrics["cssLayoutViewport"] as? [String: Any] ?? [:]
                width = width ?? (viewport["clientWidth"] as? NSNumber)?.intValue ?? 1280
                height = height ?? (viewport["clientHeight"] as? NSNumber)?.intValue ?? 800
                let mobile = device?.mobile ?? false
                _ = try await cdp.send("Emulation.setDeviceMetricsOverride",
                                       ["width": width!, "height": height!, "deviceScaleFactor": device?.scale ?? 0, "mobile": mobile])
                _ = try? await cdp.send("Emulation.setTouchEmulationEnabled", ["enabled": mobile, "maxTouchPoints": mobile ? 5 : 1])
                parts.append("\(width!)×\(height!)\(mobile ? " mobile" : "") viewport")
                tab.instruments.record(.init(kind: .viewport, locator: [:], value: "width: \(width!), height: \(height!)"), session: session)
            }
            if let device {
                if tab.instruments.userAgent == nil { tab.instruments.userAgent = try? await js(tab, "navigator.userAgent") as? String }
                if let agent = device.userAgent ?? tab.instruments.userAgent {
                    _ = try? await cdp.send("Emulation.setUserAgentOverride", ["userAgent": agent])
                }
            }
            var features: [[String: String]] = []
            var media: [String] = []
            if let scheme = string(args, "color_scheme") {
                features.append(["name": "prefers-color-scheme", "value": scheme])
                parts.append("\(scheme) mode")
                media.append("colorScheme: \(PlaywrightExport.quote(scheme))")
            }
            if let reduced = bool(args, "reduced_motion") {
                features.append(["name": "prefers-reduced-motion", "value": reduced ? "reduce" : "no-preference"])
                parts.append(reduced ? "reduced motion" : "full motion")
                media.append("reducedMotion: \(PlaywrightExport.quote(reduced ? "reduce" : "no-preference"))")
            }
            if !features.isEmpty {
                _ = try await cdp.send("Emulation.setEmulatedMedia", ["features": features])
                tab.instruments.record(.init(kind: .media, locator: [:], value: media.joined(separator: ", ")), session: session)
            }
            guard !parts.isEmpty else { return .error("Pass device, width/height, color_scheme or reduced_motion, or reset:true.") }
            tab.instruments.emulating = true
            let note = device?.mobile == true ? " Reload if the site chooses its layout on the server." : ""
            return .text("Showing the page at \(parts.joined(separator: ", ")).\(note) Take a screenshot to see it.")
        }
    }

    // MARK: - Playwright export

    private static func exportTest(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "read")
        let steps = tab.instruments.steps(for: session)
        let checks = args["expect"] as? [[String: Any]] ?? []
        guard steps.contains(where: { $0.kind != .goto }) || !checks.isEmpty else {
            return .error("Nothing recorded in this tab yet. Act on the page (click, type, …), then export.")
        }
        var assertions: [String] = []
        var failures: [String] = []
        for check in checks {
            let data = (try? JSONSerialization.data(withJSONObject: check)) ?? Data("{}".utf8)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            let result: [String: Any]
            do {
                result = try await js(tab, "__wink.verify(\(json))") as? [String: Any] ?? [:]
            } catch {
                failures.append("\(json): \(error.localizedDescription)")
                continue
            }
            guard result["ok"] as? Bool == true else {
                failures.append("\(json): actually \(result["actual"] as? String ?? "different")")
                continue
            }
            if let text = check["text"] as? String {
                assertions.append("await expect(page.locator('body')).toContainText(\(PlaywrightExport.quote(text)));")
            } else if let ref = check["ref"] as? String, let locator = await locator(tab, ref) {
                let target = PlaywrightExport.locator(locator)
                if let checked = check["checked"] as? Bool {
                    assertions.append("await expect(\(target))\(checked ? "" : ".not").toBeChecked();")
                } else if let value = check["value"] as? String {
                    assertions.append("await expect(\(target)).toHaveValue(\(PlaywrightExport.quote(value)));")
                } else {
                    assertions.append("await expect(\(target)).\(check["visible"] as? Bool == false ? "toBeHidden" : "toBeVisible")();")
                }
            }
        }
        guard failures.isEmpty else {
            return .error("These checks don't hold on the page now, so the test would fail:\n" + failures.joined(separator: "\n"))
        }
        let name = string(args, "name") ?? tab.displayTitle
        let code = PlaywrightExport.code(name: name, steps: steps, assertions: assertions)
        let actions = steps.filter { $0.kind != .goto && $0.kind != .dialog }.count
        return .text("Playwright test from \(actions) step\(actions == 1 ? "" : "s") and \(assertions.count) check\(assertions.count == 1 ? "" : "s") (verified on the live page). Save it as tests/<name>.spec.ts and run npx playwright test.\n\n```ts\n\(code)\n```")
    }

    // MARK: - Network mocks, storage, PDF, recording, checks

    private static func mockNetwork(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "control")
        let mocks = tab.instruments.mocks
        var lines: [String] = []
        return try await run(session, tab, "Changing the network", symbol: symbol(for: "mock_network")) {
            if bool(args, "clear") == true {
                try await mocks.clear()
                lines.append("Removed every mock.")
                tab.instruments.record(.init(kind: .route, locator: [:], value: "await page.unrouteAll();"), session: session)
            }
            if let offline = bool(args, "offline") {
                try await mocks.setOffline(offline)
                lines.append(offline ? "The tab is offline." : "The tab is back online.")
                tab.instruments.record(.init(kind: .offline, locator: [:], value: offline ? "true" : "false"), session: session)
            }
            if let url = string(args, "url") {
                let block = bool(args, "block") ?? false
                let status = int(args, "status") ?? 200
                let body = args["body"] as? String ?? ""
                let type = string(args, "content_type") ?? "application/json"
                try await mocks.add(.init(pattern: url, block: block, status: status, body: body, contentType: type))
                lines.append(block ? "Requests whose URL contains “\(url)” now fail."
                                   : "Requests whose URL contains “\(url)” now get \(status) \(type) (\(body.utf8.count) bytes).")
                // escapedPattern already escapes "/" for a JavaScript regex literal.
                let regex = NSRegularExpression.escapedPattern(for: url).replacingOccurrences(of: "\\*", with: ".*")
                let line = block ? "await page.route(/\(regex)/, route => route.abort());"
                    : "await page.route(/\(regex)/, route => route.fulfill({ status: \(status), contentType: \(PlaywrightExport.quote(type)), body: \(PlaywrightExport.quote(body)) }));"
                tab.instruments.record(.init(kind: .route, locator: [:], value: line), session: session)
            }
            guard !lines.isEmpty else { return .error("Pass url (with status/body or block), offline, or clear.") }
            if string(args, "url") != nil { lines.append("It applies to this tab's new requests until clear:true; reload if the page already made the request.") }
            return .text(lines.joined(separator: " "))
        }
    }

    private static func storage(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "use the storage of")
        let action = string(args, "action") ?? "get"
        let name = string(args, "name")
        let value = args["value"] as? String
        let host = Site.host(of: tab.url)
        let local = Site.isLocalDevelopment(host)
        if action == "set" || action == "delete" { guard name != nil else { return .error("\(action) needs name.") } }
        if action == "set" && value == nil { return .error("set needs value.") }
        let kinds = string(args, "kind").map { [$0] } ?? (action == "get" ? ["cookies", "local", "session"] : [])
        guard !kinds.isEmpty else { return .error("\(action) needs kind: cookies, local or session.") }
        if action != "get" && !local {
            let what = action == "clear" ? "clear \(kinds[0] == "cookies" ? "the cookies" : "the stored data")" : "\(action) \(name ?? "")"
            let ok = await AgentHub.shared.confirm(session, tab: tab, title: "\(session.name) wants to \(what)",
                                                   message: "on \(host.isEmpty ? "this page" : host). This can sign you out or change the site's settings.")
            guard ok else { return .error("The user didn't allow changing this site's storage. Don't retry; ask them.") }
        }
        return try await run(session, tab, "Looking at stored data", symbol: symbol(for: "storage")) {
            var out: [String] = []
            for kind in kinds {
                if kind == "cookies" {
                    out.append(try await cookies(tab, action: action, name: name, value: value, reveal: local, session: session))
                } else {
                    let result = try await js(tab, "__wink.storage(\(jsString(kind)), \(jsString(action)), \(name.map(jsString) ?? "null"), \(value.map(jsString) ?? "null"), \(local))") as? String ?? ""
                    out.append(result)
                    let store = kind == "session" ? "sessionStorage" : "localStorage"
                    let line: String? = switch action {
                    case "set": "await page.evaluate(([k, v]) => \(store).setItem(k, v), [\(PlaywrightExport.quote(name ?? "")), \(PlaywrightExport.quote(value ?? ""))]);"
                    case "delete": "await page.evaluate(k => \(store).removeItem(k), \(PlaywrightExport.quote(name ?? "")));"
                    case "clear": "await page.evaluate(() => \(store).clear());"
                    default: nil
                    }
                    if let line { tab.instruments.record(.init(kind: .storage, locator: [:], value: line), session: session) }
                }
            }
            if action == "get" && !local { out.append("(Values are hidden outside localhost.)") }
            return .text(out.joined(separator: "\n"))
        }
    }

    private static func cookies(_ tab: Tab, action: String, name: String?, value: String?, reveal: Bool,
                                session: AgentSession) async throws -> String {
        let url = tab.url
        func list() async throws -> [[String: Any]] {
            try await tab.cdp.send("Network.getCookies", ["urls": [url]])["cookies"] as? [[String: Any]] ?? []
        }
        switch action {
        case "set":
            _ = try await tab.cdp.send("Network.setCookie", ["name": name!, "value": value!, "url": url])
            tab.instruments.record(.init(kind: .storage, locator: [:],
                                         value: "await page.context().addCookies([{ name: \(PlaywrightExport.quote(name!)), value: \(PlaywrightExport.quote(value!)), url: page.url() }]);"), session: session)
            return "cookies: set \(name!)."
        case "delete":
            _ = try await tab.cdp.send("Network.deleteCookies", ["name": name!, "url": url])
            return "cookies: deleted \(name!)."
        case "clear":
            let all = try await list()
            for cookie in all {
                _ = try? await tab.cdp.send("Network.deleteCookies", ["name": cookie["name"] as? String ?? "", "url": url])
            }
            tab.instruments.record(.init(kind: .storage, locator: [:], value: "await page.context().clearCookies();"), session: session)
            return "cookies: cleared \(all.count)."
        default:
            let all = try await list()
            if all.isEmpty { return "cookies: none" }
            return "cookies (\(all.count)):\n" + all.prefix(100).map { cookie in
                let n = cookie["name"] as? String ?? "", v = cookie["value"] as? String ?? ""
                var flags = [cookie["domain"] as? String ?? ""]
                if cookie["httpOnly"] as? Bool == true { flags.append("HttpOnly") }
                if cookie["secure"] as? Bool == true { flags.append("Secure") }
                if cookie["session"] as? Bool == true { flags.append("session") }
                let shown = reveal ? "\"\(v.prefix(300))\"" : "(hidden, \(v.count) characters)"
                return "  \(n) = \(shown) [\(flags.joined(separator: ", "))]"
            }.joined(separator: "\n")
        }
    }

    /// Where agents' PDFs and recordings go: the user's Downloads (tests can redirect it).
    private static func outputFile(_ base: String, ext: String) -> URL {
        let env = ProcessInfo.processInfo.environment["WINK_DEBUG_DOWNLOADS"]
        let folder = env.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clean = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n\r")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(80)
        let stem = clean.isEmpty ? "Wink" : String(clean)
        var url = folder.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(n).\(ext)")
            n += 1
        }
        return url
    }

    private static func savePDF(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "save")
        return try await run(session, tab, "Saving a PDF", symbol: symbol(for: "save_pdf")) {
            let result = try await tab.cdp.send("Page.printToPDF", ["printBackground": true], timeout: 60)
            guard let data = (result["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                return .error("Chromium didn't produce a PDF.")
            }
            let url = outputFile(tab.displayTitle, ext: "pdf")
            try data.write(to: url)
            tab.instruments.record(.init(kind: .pdf, locator: [:], value: url.lastPathComponent), session: session)
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            return .text("Saved \(url.path) (\(size)).")
        }
    }

    private static func record(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "record")
        let recorder = tab.instruments.recorder
        switch string(args, "action") ?? "" {
        case "start":
            guard !recorder.isRecording else { return .error("Already recording this tab. Call record with action stop.") }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            try await recorder.begin(to: outputFile("Wink recording \(format.string(from: Date()))", ext: "mp4"))
            return .text("Recording the tab. Call record with action stop when you're done.")
        case "stop":
            guard let url = await recorder.end() else {
                return .error("Nothing was recorded: the page didn't change on screen, or the display is asleep.")
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
            return .text("Saved \(url.path) (\(recorder.frames) frames, \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))).")
        default:
            return .error("record needs action start or stop.")
        }
    }

    private static func trace(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        let tab = try await accessTab(args, session, purpose: "trace")
        switch string(args, "action") ?? "" {
        case "start":
            guard tab.instruments.trace == nil else { return .error("Already tracing this tab. Call trace with action stop.") }
            tab.instruments.trace = TabTrace(agent: session.name, url: tab.url)
            return .text("Tracing this tab: from now on every step is recorded with its result, a screenshot, console and network. Call trace with action stop to save it.")
        case "stop":
            guard let trace = tab.instruments.trace else { return .error("This tab isn't being traced. Call trace with action start first.") }
            tab.instruments.trace = nil
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = outputFile("Wink trace \(format.string(from: trace.started))", ext: "html")
            try trace.html().write(to: url, atomically: true, encoding: .utf8)
            return .text("Saved \(url.path) (\(trace.steps.count) steps). It opens in any browser.")
        default:
            return .error("trace needs action start or stop.")
        }
    }

    private static func verify(_ args: [String: Any], _ session: AgentSession) async throws -> AgentToolResult {
        guard let checks = args["expect"] as? [[String: Any]], !checks.isEmpty else { return .error("verify needs expect.") }
        let tab = try await accessTab(args, session, purpose: "read")
        var lines: [String] = []
        var passed = 0
        for check in checks {
            let json = String(data: (try? JSONSerialization.data(withJSONObject: check, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
            do {
                let result = try await js(tab, "__wink.verify(\(json))") as? [String: Any] ?? [:]
                if result["ok"] as? Bool == true { passed += 1; lines.append("✓ \(json)") }
                else { lines.append("✗ \(json): actually \(result["actual"] as? String ?? "different")") }
            } catch {
                lines.append("✗ \(json): \(error.localizedDescription)")
            }
        }
        return .text("\(passed) of \(checks.count) passed.\n" + lines.joined(separator: "\n"))
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
