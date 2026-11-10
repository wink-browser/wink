import Foundation

/// What Wink records about a tab while agents use it: JavaScript dialogs that
/// are open, network requests in detail, and the steps each agent took (so
/// they can be exported as a Playwright test). Started the first time an
/// agent touches the tab; everything stays in memory.
@MainActor
final class AgentInstruments {
    private weak var tab: Tab?
    private var started = false

    /// An open alert/confirm/prompt/beforeunload: the page is blocked until it's answered.
    struct Dialog {
        let type: String
        let message: String
        let defaultPrompt: String
    }
    private(set) var dialog: Dialog?

    struct Request {
        let id: String
        var method: String
        var url: String
        var type: String
        var requestHeaders: [String: String]
        var postData: String?
        var status: Int?
        var statusText: String = ""
        var mimeType: String = ""
        var responseHeaders: [String: String] = [:]
        var failure: String?
        var finished = false
        let started: Date
    }
    private(set) var requests: [Request] = []
    private var requestIndex: [String: Int] = [:]

    /// Steps an agent took in this tab, per agent session.
    struct Step {
        enum Kind { case goto, click, doubleClick, fill, press, select, hover, check, uncheck, upload, dragTo,
                    back, forward, reload, dialog, viewport, media, route, offline, storage, pdf }
        let kind: Kind
        var locator: [String: Any]
        var value: String
        var target: [String: Any]?
        var sensitive = false
    }
    private var steps: [UUID: [Step]] = [:]

    var emulating = false
    var userAgent: String?
    let mocks: NetworkMocks
    let recorder: TabRecorder
    /// Set while an agent traces this tab (the trace tool).
    var trace: TabTrace?

    init(tab: Tab) {
        self.tab = tab
        mocks = NetworkMocks(tab: tab)
        recorder = TabRecorder(tab: tab)
    }

    /// The DevTools session was reset (tab slept or its browser restarted).
    func cdpReset() {
        started = false
        dialog = nil
    }

    func start() async {
        guard let tab, !started else { return }
        started = true
        let cdp = tab.cdp
        tab.webView?.devToolsEventsEnabled = true
        // JavaScript dialogs in this tab now wait for the agent (handle_dialog)
        // instead of popping up native alerts.
        tab.webView?.agentHandlesDialogs = true
        if !listening {
            listening = true
            cdp.on("Network.requestWillBeSent") { [weak self] params in self?.requestWillBeSent(params) }
            cdp.on("Network.responseReceived") { [weak self] params in self?.responseReceived(params) }
            cdp.on("Network.loadingFinished") { [weak self] params in
                guard let self, let id = params["requestId"] as? String, let i = self.requestIndex[id] else { return }
                self.requests[i].finished = true
            }
            cdp.on("Network.loadingFailed") { [weak self] params in
                guard let self, let id = params["requestId"] as? String, let i = self.requestIndex[id] else { return }
                let blocked = params["blockedReason"] as? String
                self.requests[i].failure = blocked.map { "blocked (\($0))" } ?? params["errorText"] as? String ?? "failed"
                self.requests[i].finished = true
            }
        }
        _ = try? await cdp.send("Network.enable", ["maxResourceBufferSize": 4_000_000, "maxTotalBufferSize": 24_000_000])
        await mocks.restore()
    }
    private var listening = false

    func dialogHandled() { dialog = nil }

    /// The engine is holding a JavaScript dialog for the agent.
    func dialogOpened(type: String, message: String, defaultPrompt: String) {
        dialog = Dialog(type: type, message: message, defaultPrompt: defaultPrompt)
        // Input commands and scripts don't return while a dialog blocks the page.
        tab?.cdp.releaseBlockedInput()
    }

    func dialogClosed() { dialog = nil }

    /// The agent is done with this tab: its dialogs are the user's again.
    func release() {
        tab?.webView?.agentHandlesDialogs = false
        dialog = nil
        started = false
    }

    // MARK: Network

    private func requestWillBeSent(_ params: [String: Any]) {
        guard let id = params["requestId"] as? String, let request = params["request"] as? [String: Any] else { return }
        let headers = (request["headers"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
        let record = Request(id: id, method: request["method"] as? String ?? "GET", url: request["url"] as? String ?? "",
                             type: (params["type"] as? String ?? "other").lowercased(), requestHeaders: headers,
                             postData: request["postData"] as? String, started: Date())
        if let i = requestIndex[id] {
            requests[i] = record  // a redirect reuses the id
        } else {
            requests.append(record)
            requestIndex[id] = requests.count - 1
            if requests.count > 400 {
                requests.removeFirst(100)
                requestIndex = Dictionary(uniqueKeysWithValues: requests.enumerated().map { ($1.id, $0) })
            }
        }
    }

    private func responseReceived(_ params: [String: Any]) {
        guard let id = params["requestId"] as? String, let i = requestIndex[id],
              let response = params["response"] as? [String: Any] else { return }
        requests[i].status = response["status"] as? Int ?? (response["status"] as? Double).map { Int($0) }
        requests[i].statusText = response["statusText"] as? String ?? ""
        requests[i].mimeType = response["mimeType"] as? String ?? ""
        requests[i].responseHeaders = (response["headers"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
    }

    /// The most recent request whose URL contains `fragment`.
    func request(matching fragment: String) -> Request? {
        let needle = fragment.lowercased()
        return requests.last { $0.url.lowercased().contains(needle) }
    }

    func responseBody(_ request: Request) async -> String? {
        guard let tab else { return nil }
        guard let result = try? await tab.cdp.send("Network.getResponseBody", ["requestId": request.id]) else { return nil }
        let body = result["body"] as? String ?? ""
        if result["base64Encoded"] as? Bool == true {
            guard let data = Data(base64Encoded: body) else { return "(binary)" }
            return String(data: data, encoding: .utf8) ?? "(binary, \(data.count) bytes)"
        }
        return body
    }

    // MARK: Steps (for export)

    func record(_ step: Step, session: AgentSession) {
        steps[session.id, default: []].append(step)
    }

    func steps(for session: AgentSession) -> [Step] { steps[session.id] ?? [] }

    func clearSteps(for session: AgentSession) { steps[session.id] = [] }
}

/// Writes recorded steps as a Playwright test.
enum PlaywrightExport {
    static func quote(_ s: String) -> String {
        var out = "'"
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out + "'"
    }

    static func locator(_ l: [String: Any]) -> String {
        if let role = l["role"] as? String, let name = l["name"] as? String {
            var code = "page.getByRole(\(quote(role)), { name: \(quote(name)), exact: true })"
            if let nth = (l["nth"] as? NSNumber)?.intValue { code += ".nth(\(nth))" }
            return code
        }
        if let id = l["testId"] as? String { return "page.getByTestId(\(quote(id)))" }
        if let text = l["text"] as? String { return "page.getByText(\(quote(text)), { exact: true })" }
        if let css = l["css"] as? String { return "page.locator(\(quote(css)))" }
        return "page.locator('body')"
    }

    static func code(name: String, steps: [AgentInstruments.Step], assertions: [String]) -> String {
        var lines: [String] = []
        var lastFill: (locator: String, index: Int)?
        var lastGoto: String?
        for (i, step) in steps.enumerated() {
            if i + 1 < steps.count, steps[i + 1].kind == .dialog {
                let answer = steps[i + 1]
                if answer.value == "accept", let text = answer.target?["text"] as? String {
                    lines.append("page.once('dialog', dialog => dialog.accept(\(quote(text))));")
                } else {
                    lines.append("page.once('dialog', dialog => dialog.\(answer.value == "accept" ? "accept" : "dismiss")());")
                }
            }
            let target = locator(step.locator)
            var line: String?
            switch step.kind {
            case .goto:
                // Skip a repeat of the page we're already on.
                if !(lastGoto == step.value && lines.last?.hasPrefix("await page.goto") == true) {
                    line = "await page.goto(\(quote(step.value)));"
                }
                lastGoto = step.value
            case .click: line = step.value == "left" || step.value.isEmpty ? "await \(target).click();" : "await \(target).click({ button: \(quote(step.value)) });"
            case .doubleClick: line = "await \(target).dblclick();"
            case .fill:
                let value = step.sensitive ? "process.env.WINK_SECRET ?? ''" : quote(step.value)
                let text = "await \(target).fill(\(value));" + (step.sensitive ? " // sensitive: set WINK_SECRET" : "")
                if let previous = lastFill, previous.locator == target, previous.index == lines.count - 1 {
                    lines[previous.index] = text  // retyped the same field: keep the last value
                    continue
                }
                line = text
                lastFill = (target, lines.count)
            case .press: line = step.locator.isEmpty ? "await page.keyboard.press(\(quote(step.value)));" : "await \(target).press(\(quote(step.value)));"
            case .select: line = "await \(target).selectOption({ label: \(quote(step.value)) });"
            case .hover: line = "await \(target).hover();"
            case .check: line = "await \(target).check();"
            case .uncheck: line = "await \(target).uncheck();"
            case .upload:
                let files = step.value.split(separator: "\n").map { quote(String($0)) }.joined(separator: ", ")
                line = "await \(target).setInputFiles([\(files)]);"
            case .dragTo: line = "await \(target).dragTo(\(locator(step.target ?? [:])));"
            case .back: line = "await page.goBack();"
            case .forward: line = "await page.goForward();"
            case .reload: line = "await page.reload();"
            case .dialog: line = nil
            case .viewport: line = "await page.setViewportSize({ \(step.value) });"
            case .media: line = "await page.emulateMedia({ \(step.value) });"
            case .route: line = step.value
            case .offline: line = "await page.context().setOffline(\(step.value));"
            case .storage: line = step.value
            case .pdf: line = "await page.pdf({ path: \(quote(step.value)) });"
            }
            if let line { lines.append(line) }
            if step.kind != .fill { lastFill = nil }
        }
        let body = (lines + (assertions.isEmpty ? [] : [""] + assertions)).map { $0.isEmpty ? "" : "  " + $0 }.joined(separator: "\n")
        return """
        import { test, expect } from '@playwright/test';

        // Recorded by Wink from an agent's session.
        test(\(quote(name)), async ({ page }) => {
        \(body)
        });
        """
    }
}
