import AppKit
import ImageIO
import Observation
import SwiftUI

@MainActor
@Observable
final class TranscriptItem: Identifiable {
    enum Kind { case user, assistant, progress, tool, notice, error }
    enum Status { case running, done, failed }

    let id = UUID()
    let kind: Kind
    var text: String
    var title = ""
    var status = Status.running
    var output = ""
    var expanded = false
    /// A downscaled copy of an image the tool returned (screenshots).
    var thumbnail: NSImage?

    init(kind: Kind, text: String, title: String = "") {
        self.kind = kind
        self.text = text
        self.title = title
    }
}

/// State of the agent panel (shared across windows).
@MainActor
@Observable
final class AgentPanelModel: AgentEngineDelegate {
    static let shared = AgentPanelModel()

    var items: [TranscriptItem] = []
    var draft = ""
    var focusToken = 0
    var isRunning = false
    var lastCost: String?

    @ObservationIgnored let session = AgentSession(name: Winky.name, origin: .panel, trusted: true)
    @ObservationIgnored private lazy var api: ClaudeAPIEngine = {
        let engine = ClaudeAPIEngine(session: session)
        engine.delegate = self
        return engine
    }()
    @ObservationIgnored private lazy var code: ClaudeCodeEngine = {
        let engine = ClaudeCodeEngine()
        engine.delegate = self
        return engine
    }()
    @ObservationIgnored private var currentAssistant: TranscriptItem?
    @ObservationIgnored private var toolItems: [String: TranscriptItem] = [:]

    private init() {
        AgentHub.shared.register(session)
        AgentHub.shared.onStop(session) { [weak self] in self?.stop() }
    }

    var engineKind: AgentEngineKind { WinkSettings.shared.agentEngine }

    var needsAPIKey: Bool {
        engineKind == .claudeAPI && Keychain.read("anthropic-api-key") == nil
            && ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] == nil
    }

    var claudeCodeMissing: Bool { engineKind == .claudeCode && ClaudeCodeLocator.find() == nil }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        draft = ""
        session.stoppedAt = nil
        items.append(TranscriptItem(kind: .user, text: text))
        currentAssistant = nil
        let context = browserContext()
        switch engineKind {
        case .claudeAPI: api.send(text, context: context)
        case .claudeCode: code.send(text, context: context)
        }
    }

    func stop() {
        api.cancel()
        code.cancel()
    }

    /// Called at quit: ends any Claude Code subprocess.
    func shutdown() {
        api.cancel()
        code.reset()
    }

    func newConversation() {
        api.reset()
        code.reset()
        items.removeAll()
        toolItems.removeAll()
        currentAssistant = nil
        isRunning = false
        lastCost = nil
        focusToken += 1
    }

    /// Describes the tab in view. Asking from the panel implicitly grants the
    /// agent access to that tab (never to private or protected ones).
    private func browserContext() -> String {
        guard let tab = AppDelegate.shared?.activeWindow?.state.activeTab, !tab.url.isEmpty else {
            return "The user has no tab open."
        }
        var lines = ["Active tab: \(tab.displayTitle) — \(tab.url) (tab_id: \(AgentHub.shortID(tab)))"]
        if !Profile.shared.firstName.isEmpty { lines.append("The user's name: \(Profile.shared.firstName)") }
        if tab.isPrivate {
            lines.append("This tab is in a private window: you cannot access it.")
        } else if WinkSettings.shared.isAgentProtected(host: tab.host_) {
            lines.append("This site is protected by the user: you cannot access it.")
        } else {
            session.allowedTabs.insert(tab.id)
            session.currentTabID = tab.id
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        lines.append("Local time: \(formatter.string(from: Date()))")
        return lines.joined(separator: "\n")
    }

    // MARK: - AgentEngineDelegate

    func engineDidStartTurn() {
        isRunning = true
        lastCost = nil
    }

    func engine(appendText text: String) {
        if let currentAssistant {
            currentAssistant.text += text
        } else {
            let item = TranscriptItem(kind: .assistant, text: text)
            items.append(item)
            currentAssistant = item
        }
    }

    func engine(progress text: String) {
        currentAssistant = nil
        items.append(TranscriptItem(kind: .progress, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func engine(toolStarted id: String, name: String, summary: String) {
        currentAssistant = nil
        let item = TranscriptItem(kind: .tool, text: summary, title: name)
        toolItems[id] = item
        items.append(item)
    }

    func engine(toolFinished id: String, isError: Bool, output: String, image: Data?) {
        guard let item = toolItems[id] else { return }
        item.status = isError ? .failed : .done
        item.output = output
        if let image, let thumbnail = Self.thumbnail(image) {
            item.thumbnail = thumbnail
            // Keep memory flat in long sessions: only recent screenshots keep pixels.
            let withImages = items.filter { $0.thumbnail != nil }
            withImages.dropLast(12).forEach { $0.thumbnail = nil }
        }
    }

    private static func thumbnail(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 640,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }

    func engine(notice text: String) {
        currentAssistant = nil
        items.append(TranscriptItem(kind: .notice, text: text))
    }

    func engine(error text: String) {
        currentAssistant = nil
        items.append(TranscriptItem(kind: .error, text: text))
    }

    func engineDidFinishTurn(cost: String?) {
        isRunning = false
        lastCost = cost
        currentAssistant = nil
        for item in toolItems.values where item.status == .running { item.status = .failed }
    }
}

// MARK: - Views

struct AgentPanelView: View {
    let model: AgentPanelModel
    let window: BrowserWindowController
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                WinkyAvatar(size: 24)
                Text(Winky.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                EngineMenu(model: model)
                Spacer(minLength: 4)
                QuietIconButton(symbol: "square.and.pencil", help: "New conversation") { model.newConversation() }
                QuietIconButton(symbol: "xmark", help: "Close (⌘J)") { window.toggleAgentPanel() }
            }
            .padding(.leading, 14).padding(.trailing, 10)
            .frame(height: Theme.titlebarHeight)
            .padding(.top, 2)

            if model.items.isEmpty {
                AgentEmptyState(model: model)
            } else {
                Transcript(model: model)
            }

            Composer(model: model, focused: $composerFocused)
        }
        .onChange(of: model.focusToken) { composerFocused = true }
        .onAppear { composerFocused = true }
    }
}

/// Which agent answers in the panel, as a quiet inline menu.
private struct EngineMenu: View {
    let model: AgentPanelModel
    @State private var hovering = false

    var body: some View {
        @Bindable var settings = WinkSettings.shared
        Menu {
            Picker("Agent", selection: $settings.agentEngine) {
                ForEach(AgentEngineKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(settings.agentEngine.displayName)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .disabled(model.isRunning)
        .help("Choose who answers: Claude (API) or your Claude Code")
        .onChange(of: settings.agentEngine) { model.newConversation() }
    }
}

private struct Transcript: View {
    let model: AgentPanelModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.items) { item in
                        TranscriptRow(item: item)
                            .padding(.vertical, item.kind == .tool ? 0 : 7)
                            .id(item.id)
                    }
                    if model.isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Working…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .id("working")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .onChange(of: model.items.count) { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom") } }
            .onChange(of: model.items.last?.text) { proxy.scrollTo("bottom") }
        }
    }
}

private struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 32)
                Text(item.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.16)))
            }
        case .assistant:
            MarkdownText(text: item.text)
        case .progress:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).padding(.top, 3)
                Text(item.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
        case .tool:
            ToolRow(item: item)
        case .notice:
            Text(item.text).font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        case .error:
            Text(item.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.1)))
        }
    }
}

private struct ToolRow: View {
    let item: TranscriptItem
    @State private var hovering = false

    var body: some View {
        let tool = ToolPresentation(raw: item.title, summary: item.text, output: item.output, done: item.status != .running)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    switch item.status {
                    case .running: ProgressView().controlSize(.mini).scaleEffect(0.8)
                    case .done: Image(systemName: tool.symbol).foregroundStyle(.secondary)
                    case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .frame(width: 16, height: 16)
                Text(tool.title)
                    .font(.system(size: 12))
                    .foregroundStyle(item.status == .failed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary.opacity(0.78)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if !item.output.isEmpty && hovering {
                    Image(systemName: item.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: item.expanded ? .infinity : 220, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                    .padding(.leading, 24)
            }
            if item.expanded && !item.output.isEmpty {
                Text(String(item.output.prefix(2000)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { item.expanded.toggle() }
    }
}

/// Turns raw tool calls ("mcp__wink__click", {ref: e12}) into quiet,
/// human lines ("Clicked button “Send”") with a matching symbol.
@MainActor
struct ToolPresentation {
    let symbol: String
    let title: String

    init(raw: String, summary: String, output: String, done: Bool) {
        let browserTool: String? = raw.hasPrefix("mcp__wink__") ? String(raw.dropFirst("mcp__wink__".count))
            : (BrowserTools.definitions.contains { $0.name == raw } ? raw : nil)
        if let tool = browserTool {
            symbol = BrowserTools.symbol(for: tool)
            let firstLine = output.split(separator: "\n").first.map(String.init) ?? ""
            if done, !firstLine.isEmpty, ["click", "type", "press_key", "select_option", "hover"].contains(tool) {
                title = Self.tidy(firstLine)
            } else {
                title = Self.verb(tool) + (summary.isEmpty ? "" : " " + summary)
            }
            return
        }
        switch raw {
        case "Bash": symbol = "terminal"; title = summary.isEmpty ? "Run a command" : summary
        case "Read": symbol = "doc.text"; title = "Read " + URL(fileURLWithPath: summary).lastPathComponent
        case "Edit", "MultiEdit": symbol = "pencil"; title = "Edit " + URL(fileURLWithPath: summary).lastPathComponent
        case "Write": symbol = "square.and.pencil"; title = "Write " + URL(fileURLWithPath: summary).lastPathComponent
        case "Grep", "Glob": symbol = "magnifyingglass"; title = "Search " + summary
        case "WebFetch": symbol = "globe"; title = "Fetch " + summary
        case "WebSearch": symbol = "magnifyingglass"; title = "Search the web for " + summary
        case "Task", "Agent": symbol = "person.2"; title = summary.isEmpty ? "Delegate a task" : summary
        default:
            symbol = "wrench.and.screwdriver"
            let name = raw.hasPrefix("mcp__") ? raw.split(separator: "_").filter { !$0.isEmpty }.dropFirst().joined(separator: " · ") : raw
            title = name + (summary.isEmpty ? "" : " " + summary)
        }
    }

    private static func verb(_ tool: String) -> String {
        switch tool {
        case "click": "Click"
        case "type": "Type"
        case "press_key": "Press"
        case "select_option": "Choose"
        case "hover": "Point at"
        case "scroll": "Scroll"
        case "find": "Find"
        case "snapshot": "Look at the page"
        case "read_page": "Read the page"
        case "screenshot": "Screenshot"
        case "navigate", "tab_open": "Open"
        case "tab_close": "Close a tab"
        case "tab_focus": "Show a tab"
        case "go_back": "Go back"
        case "go_forward": "Go forward"
        case "reload": "Reload"
        case "batch": "Run"
        case "wait_for": "Wait for"
        case "tabs_list": "Check tabs"
        case "get_active_tab": "Ask for this tab"
        case "get_selection": "Read the selection"
        case "console_logs": "Read the console"
        case "network_requests": "Check network requests"
        case "evaluate": "Run a script"
        case "approve": "Ask permission"
        default: tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "Clicked button “Send” [ref=e93]." → "Clicked button “Send”"
    private static func tidy(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #"\s*\[ref=e\d+\]"#, with: "", options: .regularExpression)
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Minimal Markdown renderer: inline styles + fenced code blocks.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.code {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(segment.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                } else {
                    Text(Self.attributed(segment.text))
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var segments: [(text: String, code: Bool)] {
        var result: [(String, Bool)] = []
        let parts = text.components(separatedBy: "```")
        for (index, part) in parts.enumerated() {
            if index % 2 == 1 {
                var code = part
                if let newline = code.firstIndex(of: "\n") {
                    let firstLine = code[..<newline]
                    if !firstLine.contains(" ") { code = String(code[code.index(after: newline)...]) }
                }
                result.append((code.trimmingCharacters(in: .newlines), true))
            } else {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append((trimmed, false)) }
            }
        }
        return result
    }

    static func attributed(_ markdown: String) -> AttributedString {
        // Headings and bullets render as plain lines; inline styles are parsed.
        let normalized = ("\n" + markdown)
            .replacingOccurrences(of: "\n### ", with: "\n")
            .replacingOccurrences(of: "\n## ", with: "\n")
            .replacingOccurrences(of: "\n# ", with: "\n")
            .replacingOccurrences(of: "\n- ", with: "\n• ")
            .replacingOccurrences(of: "\n* ", with: "\n• ")
            .dropFirst()
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: String(normalized), options: options)) ?? AttributedString(markdown)
    }
}

private struct AgentEmptyState: View {
    let model: AgentPanelModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            WinkyAvatar(size: 84)
            VStack(spacing: 4) {
                Text(Profile.shared.firstName.isEmpty ? "Hi, I'm Winky." : "Hi \(Profile.shared.firstName), I'm Winky.")
                    .font(.system(size: 16, weight: .semibold))
                Text("Ask me about this page,\nor give me a task.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            if model.needsAPIKey {
                notice("Add your Anthropic API key to use Claude here, or switch to Claude Code.",
                       action: "Open Settings") { AppDelegate.shared?.showSettings(nil) }
            } else if model.claudeCodeMissing {
                notice("Claude Code isn't installed. Install it, or switch to Claude with an API key.",
                       action: "Open Settings") { AppDelegate.shared?.showSettings(nil) }
            }
            VStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { model.send(suggestion) } label: {
                        Text(suggestion)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var suggestions: [String] {
        model.engineKind == .claudeCode
            ? ["Summarize this page", "Open localhost:3000 and check the console for errors",
               "Compare this page with the docs in my current project"]
            : ["Summarize this page", "What are the key takeaways?", "Find the pricing on this site"]
    }

    private func notice(_ text: String, action: String, _ perform: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action, action: perform).controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
        .padding(.horizontal, 18)
    }
}

private struct Composer: View {
    let model: AgentPanelModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            if let tab = AppDelegate.shared?.activeWindow?.state.activeTab, !tab.url.isEmpty {
                HStack(spacing: 5) {
                    FaviconView(tab: tab).scaleEffect(0.75).frame(width: 12, height: 12)
                    Text(tab.displayTitle).lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Winky…",
                          text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...8)
                    .focused(focused)
                    .onSubmit { model.send(model.draft) }
                if model.isRunning {
                    Button { model.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Stop")
                } else {
                    Button { model.send(model.draft) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.draft.isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor)
                    .disabled(model.draft.isEmpty)
                    .help("Send (↩)")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
            if let cost = model.lastCost {
                Text(cost).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 6)
    }
}
