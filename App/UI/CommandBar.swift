import AppKit
import WinkEngine

/// One row in the command bar.
struct CommandSuggestion {
    enum Kind { case url, search, history, tab, ask }
    let kind: Kind
    let title: String
    let subtitle: String
    let value: String
    let hint: String
    var tab: Tab?
}

/// Spotlight-style command bar: address, search, open tabs, history, and
/// "Ask Wink" in one place. AppKit for exact keyboard handling.
@MainActor
final class CommandBarController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = CommandBarController()

    enum Mode { case newTab, navigate }

    private var panel: CommandBarPanel?
    private let field = NSTextField()
    private let rowsStack = NSStackView()
    private let effect = NSVisualEffectView()
    private weak var target: BrowserWindowController?
    private var mode: Mode = .newTab
    private var suggestions: [CommandSuggestion] = []
    private var selectedIndex = 0
    private var rowViews: [SuggestionRowView] = []

    private let fieldHeight: CGFloat = 54
    private let rowHeight: CGFloat = 40
    private let maxRows = 8

    var isVisible: Bool { panel?.isVisible == true }

    func show(for controller: BrowserWindowController, mode: Mode) {
        target = controller
        self.mode = mode
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if mode == .navigate, let url = controller.state.activeTab?.url, !url.isEmpty {
            field.stringValue = url
        } else {
            field.stringValue = ""
        }
        field.placeholderString = mode == .newTab ? "Search, enter an address, or ask Wink…" : "Search or enter address"
        recompute()

        if let window = controller.window {
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            position(panel, in: window)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Development hook (DebugDriver): set the query as if typed.
    func debugSetQuery(_ text: String) {
        field.stringValue = text
        recompute()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // Only refocus the page if Wink is still the active app.
        if NSApp.isActive, let target, target.window?.isVisible == true {
            target.window?.makeKeyAndOrderFront(nil)
            target.state.activeTab?.webView?.focusContent()
        }
    }

    private func makePanel() -> CommandBarPanel {
        let panel = CommandBarPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: fieldHeight),
                                    styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isMovable = false

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effect

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        icon.contentTintColor = .tertiaryLabelColor
        icon.frame = NSRect(x: 18, y: 0, width: 22, height: fieldHeight)
        icon.autoresizingMask = [.minYMargin]
        icon.identifier = NSUserInterfaceItemIdentifier("icon")
        effect.addSubview(icon)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19)
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        effect.addSubview(field)

        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.alignment = .leading
        effect.addSubview(rowsStack)
        return panel
    }

    private func position(_ panel: NSPanel, in window: NSWindow) {
        let width = min(660, window.frame.width - 80)
        let rows = min(suggestions.count, maxRows)
        let height = fieldHeight + (rows > 0 ? CGFloat(rows) * rowHeight + 14 : 0)
        let top = window.frame.maxY - window.frame.height * 0.16
        panel.setFrame(NSRect(x: window.frame.midX - width / 2, y: top - height, width: width, height: height), display: true)
        layoutContent(width: width, height: height)
    }

    private func layoutContent(width: CGFloat, height: CGFloat) {
        field.frame = NSRect(x: 48, y: height - fieldHeight + (fieldHeight - 26) / 2, width: width - 66, height: 26)
        if let icon = effect.subviews.first(where: { $0.identifier?.rawValue == "icon" }) {
            icon.frame = NSRect(x: 18, y: height - fieldHeight, width: 22, height: fieldHeight)
        }
        let rows = min(suggestions.count, maxRows)
        rowsStack.frame = NSRect(x: 8, y: 6, width: width - 16, height: CGFloat(rows) * rowHeight)
    }

    // MARK: - Suggestions

    private func recompute() {
        suggestions = buildSuggestions(for: field.stringValue)
        selectedIndex = 0
        rebuildRows()
        if let panel, let window = target?.window { position(panel, in: window) }
    }

    private func buildSuggestions(for raw: String) -> [CommandSuggestion] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = WinkSettings.shared.searchEngine
        var result: [CommandSuggestion] = []
        var seen = Set<String>()

        func add(_ suggestion: CommandSuggestion) {
            guard !seen.contains(suggestion.value) else { return }
            seen.insert(suggestion.value)
            result.append(suggestion)
        }

        let allTabs = AppDelegate.shared?.allTabs ?? []
        if text.isEmpty {
            for tab in allTabs.sorted(by: { $0.lastActive > $1.lastActive }).prefix(5) where tab.id != target?.state.activeTabID {
                add(.init(kind: .tab, title: tab.displayTitle, subtitle: URLInput.display(tab.url),
                          value: "tab:\(tab.id)", hint: "Switch to Tab", tab: tab))
            }
            return result
        }

        let resolved = URLInput.resolve(text, searchEngine: engine)
        let isSearch = resolved == engine.searchURL(for: text)
        let history = (target?.state.isPrivate ?? false) ? [] : HistoryStore.shared.search(text, limit: 8)

        // Autocomplete: a visited site whose host or domain starts with what
        // you typed wins ("wiki" → en.wikipedia.org).
        let typed = text.lowercased()
        if !text.contains(" "), let top = history.first,
           Site.host(of: top.url).replacingOccurrences(of: "www.", with: "").hasPrefix(typed)
            || Site.registrableDomain(Site.host(of: top.url)).hasPrefix(typed) {
            if let open = allTabs.first(where: { $0.url == top.url }) {
                add(.init(kind: .tab, title: open.displayTitle, subtitle: URLInput.display(open.url),
                          value: "tab:\(open.id)", hint: "Switch to Tab", tab: open))
                seen.insert(open.url)
            } else {
                add(.init(kind: .history, title: top.title.isEmpty ? URLInput.display(top.url) : top.title,
                          subtitle: URLInput.display(top.url), value: top.url, hint: "Open"))
            }
        }
        if isSearch {
            add(.init(kind: .search, title: text, subtitle: "Search \(engine.displayName)", value: resolved, hint: "Search"))
        } else {
            add(.init(kind: .url, title: URLInput.display(resolved), subtitle: resolved, value: resolved, hint: "Open"))
        }
        let lower = text.lowercased()
        for tab in allTabs where tab.title.lowercased().contains(lower) || tab.url.lowercased().contains(lower) {
            if result.count >= 5 { break }
            if seen.contains(tab.url) { continue }
            add(.init(kind: .tab, title: tab.displayTitle, subtitle: URLInput.display(tab.url),
                      value: "tab:\(tab.id)", hint: "Switch to Tab", tab: tab))
            seen.insert(tab.url)  // don't repeat an open tab as a history row
        }
        for entry in history {
            if result.count >= maxRows - 2 { break }
            add(.init(kind: .history, title: entry.title.isEmpty ? URLInput.display(entry.url) : entry.title,
                      subtitle: URLInput.display(entry.url), value: entry.url, hint: "Open"))
        }
        if !isSearch {
            add(.init(kind: .search, title: text, subtitle: "Search \(engine.displayName)",
                      value: engine.searchURL(for: text), hint: "Search"))
        }
        add(.init(kind: .ask, title: text, subtitle: "Ask Wink", value: "ask:\(text)", hint: "⌘↩"))
        return result
    }

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = suggestions.prefix(maxRows).enumerated().map { index, suggestion in
            let row = SuggestionRowView(suggestion: suggestion)
            row.onClick = { [weak self] in self?.execute(index) }
            row.isSelected = index == selectedIndex
            return row
        }
        for row in rowViews {
            rowsStack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    private func select(_ index: Int) {
        guard !rowViews.isEmpty else { return }
        selectedIndex = (index + rowViews.count) % rowViews.count
        for (i, row) in rowViews.enumerated() { row.isSelected = i == selectedIndex }
    }

    private func execute(_ index: Int, forceAsk: Bool = false) {
        guard let target else { hide(); return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTab = mode == .newTab
        if forceAsk {
            hide()
            if !text.isEmpty { target.showAgentPanel(); AgentPanelModel.shared.send(text) }
            return
        }
        guard suggestions.indices.contains(index) else {
            hide()
            if !text.isEmpty { target.open(text, inNewTab: newTab) }
            return
        }
        let suggestion = suggestions[index]
        hide()
        switch suggestion.kind {
        case .tab:
            if let tab = suggestion.tab { AppDelegate.shared?.reveal(tab) }
        case .ask:
            target.showAgentPanel()
            AgentPanelModel.shared.send(suggestion.title)
        case .url, .search, .history:
            target.open(suggestion.value, inNewTab: newTab)
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        recompute()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(selectedIndex - 1); return true
        case #selector(NSResponder.moveDown(_:)): select(selectedIndex + 1); return true
        case #selector(NSResponder.insertNewline(_:)):
            execute(selectedIndex, forceAsk: NSEvent.modifierFlags.contains(.command))
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            execute(selectedIndex, forceAsk: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        case #selector(NSResponder.insertTab(_:)):
            if suggestions.indices.contains(selectedIndex), suggestions[selectedIndex].kind == .history {
                field.stringValue = suggestions[selectedIndex].value
                recompute()
            }
            return true
        default: return false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘↩ asks the agent; let the field editor see it as a newline.
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            if let editor = firstResponder as? NSTextView {
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SuggestionRowView: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true; updateColors() } }

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let isAsk: Bool

    init(suggestion: CommandSuggestion) {
        isAsk = suggestion.kind == .ask
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        let symbol: String
        switch suggestion.kind {
        case .url: symbol = "globe"
        case .search: symbol = "magnifyingglass"
        case .history: symbol = "clock"
        case .tab: symbol = "square.on.square"
        case .ask: symbol = "sparkle"
        }
        if suggestion.kind == .ask, let eye = Brand.eyeImage {
            icon.image = eye
        } else if suggestion.kind == .tab, let favicon = suggestion.tab?.favicon {
            icon.image = favicon
        } else if suggestion.kind == .history, let favicon = FaviconCache.shared.image(for: Site.host(of: suggestion.value)) {
            icon.image = favicon
        } else {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.stringValue = suggestion.kind == .ask ? "Ask Wink: \(suggestion.title)" : suggestion.title
        title.font = .systemFont(ofSize: 13.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.stringValue = suggestion.kind == .ask ? "" : suggestion.subtitle
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.lineBreakMode = .byTruncatingMiddle
        hint.stringValue = suggestion.hint
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.alignment = .right
        for view in [icon, title, subtitle, hint] { addSubview(view) }
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 12, y: (h - 18) / 2, width: 18, height: 18)
        let hintWidth: CGFloat = 110
        hint.frame = NSRect(x: bounds.width - hintWidth - 12, y: (h - 16) / 2, width: hintWidth, height: 16)
        let textX: CGFloat = 40
        let available = hint.frame.minX - textX - 8
        let titleWidth = min(title.intrinsicContentSize.width + 4, available * (subtitle.stringValue.isEmpty ? 1 : 0.6))
        title.frame = NSRect(x: textX, y: (h - 18) / 2, width: titleWidth, height: 18)
        subtitle.frame = NSRect(x: title.frame.maxX + 8, y: (h - 16) / 2, width: max(0, available - titleWidth - 8), height: 16)
    }

    private func updateColors() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor : NSColor.clear.cgColor
        title.textColor = isSelected ? .white : .labelColor
        subtitle.textColor = isSelected ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        hint.textColor = isSelected ? NSColor.white.withAlphaComponent(0.8) : .tertiaryLabelColor
        icon.contentTintColor = isSelected ? .white : (isAsk ? Theme.agentNSColor : .secondaryLabelColor)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
