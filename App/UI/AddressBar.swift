import AppKit
import SwiftUI
import WinkEngine

// The address bar. At rest it says where you are, centred: a lock, the site in
// the primary ink, the path in a quieter one (a search shows its words). Click
// it, or press ⌘L, and it becomes a field in place: the address selected, a
// site you have visited finished inline as you type, and suggestions dropping
// down right under it. ⌘T still opens the command bar for a new tab.

// MARK: - The pill

struct AddressPill: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController
    /// The tab placement this pill is shown in. Only the pill on screen edits.
    let placement: TabPlacement
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let editor = controller.addressEditor
        let owns = WinkSettings.shared.tabPlacement == placement
        let editing = owns && editor.isEditing
        let tab = state.activeTab
        let shield = !editing && (tab?.url.hasPrefix("http") ?? false)
        // Equal room on both sides, so the address sits on the pill's centre.
        let side: CGFloat = state.isPrivate ? 62 : (shield ? 30 : 6)
        ZStack {
            AddressField(editor: editor, owns: owns,
                         display: AddressDisplay.text(for: tab?.url ?? ""))
                .frame(height: 18)
                .padding(.leading, editing ? 22 : side)
                .padding(.trailing, editing ? 2 : side)
            HStack(spacing: 6) {
                if editing {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                } else if state.isPrivate {
                    PrivateBadge()
                }
                Spacer(minLength: 0)
                if shield, let tab { ShieldButton(tab: tab, state: state) }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(editing ? Color(nsColor: .textBackgroundColor).opacity(colorScheme == .dark ? 0.55 : 1)
                              : Color.primary.opacity(hovering ? 0.085 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(editing ? Color.accentColor.opacity(0.75) : .clear, lineWidth: 1.5)
        )
        .background(PillAnchor(editor: editor, owns: owns))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { editor.begin() }
        .animation(.easeOut(duration: 0.15), value: editing)
        .help(editing ? "" : "Search or enter address (⌘L)")
    }
}

struct PrivateBadge: View {
    var body: some View {
        Text("Private")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.purple)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.purple.opacity(0.15)))
            .help("Private window: nothing is saved, and agents can't see these tabs")
    }
}

/// How the address reads at rest.
@MainActor
enum AddressDisplay {
    static func text(for url: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard !url.isEmpty, url != "about:blank" else { return result }  // the placeholder shows
        let quiet = NSColor.tertiaryLabelColor
        let regular = NSFont.systemFont(ofSize: 13)
        let medium = NSFont.systemFont(ofSize: 13, weight: .medium)

        func add(_ text: String, _ font: NSFont, _ color: NSColor) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        func glyph(_ symbol: String, _ color: NSColor) {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
            result.append(NSAttributedString(attachment: attachment))
            add(" ", regular, quiet)
            result.addAttribute(.kern, value: 1.5, range: NSRange(location: result.length - 1, length: 1))
        }

        guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased() else {
            add(url, regular, .secondaryLabelColor)
            return finish(result)
        }
        if scheme == "http" || scheme == "https", let host = parts.host?.lowercased(), !host.isEmpty {
            if let query = searchQuery(parts) {
                glyph("magnifyingglass", quiet)
                add(query, medium, .labelColor)
                return finish(result)
            }
            if scheme == "https" {
                glyph("lock.fill", quiet)
            } else if Site.isLocalDevelopment(host) {
                glyph("laptopcomputer", quiet)
            } else {
                glyph("exclamationmark.triangle.fill", .systemOrange)
                add("Not secure  ", NSFont.systemFont(ofSize: 12, weight: .medium), .systemOrange)
            }
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            add(bare + (parts.port.map { ":\($0)" } ?? ""), medium, .labelColor)
            if parts.path.count > 1 { add(parts.path, regular, quiet) }
        } else if scheme == "file" {
            glyph("doc", quiet)
            add(parts.path, regular, .secondaryLabelColor)
        } else {
            add(url, regular, .secondaryLabelColor)
        }
        return finish(result)
    }

    /// The words of a search on one of the search engines Wink offers.
    static func searchQuery(_ parts: URLComponents) -> String? {
        guard let host = parts.host?.lowercased() else { return nil }
        for engine in SearchEngine.allCases {
            guard let search = URLComponents(string: engine.searchURL(for: "wink")),
                  search.host == host, search.path == parts.path else { continue }
            // Search engines write spaces as "+" (form encoding), which URLComponents leaves alone.
            let query = (parts.queryItems?.first { $0.name == "q" }?.value ?? "")
                .replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces)
            return query.isEmpty ? nil : query
        }
        return nil
    }

    private static func finish(_ text: NSMutableAttributedString) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return text
    }
}

/// The text of the pill: a label at rest, the field while editing.
private struct AddressField: NSViewRepresentable {
    let editor: AddressEditor
    let owns: Bool
    let display: NSAttributedString

    func makeNSView(context: Context) -> AddressTextField {
        AddressTextField()
    }

    func updateNSView(_ field: AddressTextField, context: Context) {
        field.editor = owns ? editor : nil
        field.delegate = owns ? editor : nil
        if owns { editor.register(field) }
        field.show(display)
    }
}

/// The pill's frame, for placing the suggestions under it.
private struct PillAnchor: NSViewRepresentable {
    let editor: AddressEditor
    let owns: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        if owns { editor.anchor = view }
    }
}

final class AddressTextField: NSTextField {
    weak var editor: AddressEditor?
    /// The address at rest, put back when editing ends.
    private var display = NSAttributedString()

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 13)
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        setAccessibilityLabel("Address and search")
        rest()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isEditingAddress: Bool { isEditable }

    /// Shows the address at rest (ignored while editing).
    func show(_ text: NSAttributedString) {
        display = text
        guard !isEditable, !attributedStringValue.isEqual(to: text) else { return }
        attributedStringValue = text
    }

    func beginEditing(_ text: String) {
        isEditable = true
        isSelectable = true
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
        alignment = .left
        font = .systemFont(ofSize: 13)
        textColor = .labelColor
        placeholderAttributedString = Self.placeholder(.left)
        stringValue = text
    }

    func endEditing() {
        rest()
        attributedStringValue = display
    }

    private func rest() {
        isEditable = false
        isSelectable = false
        cell?.isScrollable = false
        cell?.lineBreakMode = .byTruncatingTail
        alignment = .center
        placeholderAttributedString = Self.placeholder(.center)
    }

    private static func placeholder(_ alignment: NSTextAlignment) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: "Search or enter address", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph,
        ])
    }

    // In the titlebar, a click here edits; it never drags the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if let editor, !isEditable {
            editor.begin()
            return
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘↩ asks Winky, as in the command bar.
        if isEditable, currentEditor() != nil, event.keyCode == 36,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command {
            editor?.commit(ask: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Editing

/// One window's address editing: the field types in place and the
/// suggestions drop down under the pill.
@MainActor
@Observable
final class AddressEditor: NSObject, NSTextFieldDelegate {
    private(set) var isEditing = false

    @ObservationIgnored private weak var controller: BrowserWindowController?
    @ObservationIgnored private weak var field: AddressTextField?
    @ObservationIgnored weak var anchor: NSView?
    @ObservationIgnored private let dropdown = SuggestionDropdown()
    @ObservationIgnored private var suggestions: [CommandSuggestion] = []
    @ObservationIgnored private var selected = 0
    /// What was typed, without the inline completion.
    @ObservationIgnored private var typed = ""
    /// The address when editing began; Esc puts it back.
    @ObservationIgnored private var original = ""
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let maxRows = 7

    init(controller: BrowserWindowController) {
        self.controller = controller
        super.init()
    }

    func register(_ field: AddressTextField) {
        guard self.field !== field else { return }
        let previous = self.field
        self.field = field
        guard isEditing else { return }
        // The tabs moved to the other side mid-edit: stop editing in the old
        // pill, once SwiftUI has finished this update.
        DispatchQueue.main.async { [weak self] in
            if let previous {
                if previous.currentEditor() != nil { previous.window?.makeFirstResponder(nil) }
                previous.endEditing()
            }
            self?.end(focusPage: false)
        }
    }

    /// Edits in place when the pill is on screen; otherwise opens the command bar.
    func begin() {
        guard let controller else { return }
        guard let field, let window = field.window, window.isVisible, !field.isHiddenOrHasHiddenAncestor,
              field.bounds.width > 40 else {
            CommandBarController.shared.show(for: controller, mode: .navigate)
            return
        }
        if !isEditing {
            CommandBarController.shared.hide()
            let url = controller.state.activeTab?.url ?? ""
            original = url == "about:blank" ? "" : url
            typed = ""
            suggestions = []
            field.beginEditing(original)
            isEditing = true
            watch(window)
        }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Stops editing and shows the address again.
    func end(focusPage: Bool) {
        guard isEditing else { return }
        isEditing = false
        dropdown.hide()
        unwatch()
        suggestions = []
        if let field {
            if let window = field.window, field.currentEditor() != nil {
                window.makeFirstResponder(nil)
            }
            field.endEditing()
        }
        if focusPage { controller?.state.activeTab?.webView?.focusContent() }
    }

    /// Goes where the field says: the chosen suggestion, or the text itself.
    func commit(ask: Bool) {
        guard isEditing, let controller, let field else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = dropdown.isVisible && suggestions.indices.contains(selected) ? suggestions[selected] : nil
        end(focusPage: false)
        if ask {
            if !text.isEmpty { controller.askWinky(text) }
        } else if let chosen {
            Suggestions.perform(chosen, on: controller, inNewTab: false)
        } else if !text.isEmpty {
            controller.open(text, inNewTab: false)
        } else {
            controller.state.activeTab?.webView?.focusContent()
        }
    }

    // MARK: Suggestions

    private func refresh(completing: Bool) {
        guard let field, let editor = field.currentEditor() as? NSTextView else { return }
        let text = typed
        let result = Suggestions.build(for: text, state: controller?.state, maxRows: Self.maxRows,
                                       autocomplete: completing ? .inline : .none)
        suggestions = result.rows
        selected = 0
        // Finish a site you've been to, the rest selected so typing on replaces it.
        if let completion = result.completion, completion.count > text.count,
           completion.lowercased().hasPrefix(text.lowercased()) {
            let suffix = String(completion.dropFirst(text.count))
            let length = (editor.string as NSString).length
            editor.replaceCharacters(in: NSRange(location: length, length: 0), with: suffix)
            editor.setSelectedRange(NSRange(location: length, length: (suffix as NSString).length))
        }
        showDropdown()
    }

    private func showDropdown() {
        guard let anchor, !suggestions.isEmpty, anchor.window?.isKeyWindow == true || DebugDriver.isHeadless else {
            dropdown.hide()
            return
        }
        dropdown.show(suggestions, selected: selected, under: anchor,
                      pick: { [weak self] index in
                          self?.selected = index
                          self?.commit(ask: false)
                      },
                      hover: { [weak self] index in
                          self?.selected = index
                          self?.dropdown.select(index)
                      })
    }

    private func move(_ offset: Int) {
        guard !suggestions.isEmpty else { return }
        selected = (selected + offset + suggestions.count) % suggestions.count
        dropdown.select(selected)
    }

    private func watch(_ window: NSWindow) {
        unwatch()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dropdown.hide() }
            },
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let anchor = self.anchor else { return }
                    self.dropdown.place(under: anchor)
                }
            },
        ]
    }

    private func unwatch() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard isEditing, let field, let editor = field.currentEditor() as? NSTextView else { return }
        let text = editor.string
        let length = (text as NSString).length
        // Finish inline only while typing forward at the end, never after a delete.
        let completing = text.count > typed.count && editor.selectedRange() == NSRange(location: length, length: 0)
            && text == text.trimmingCharacters(in: .whitespaces)
        typed = text
        refresh(completing: completing)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        end(focusPage: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if dropdown.isVisible { move(1) } else { typed = textView.string; refresh(completing: false) }
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard dropdown.isVisible else { return false }
            move(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commit(ask: NSEvent.modifierFlags.contains(.command))
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            commit(ask: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // First Esc puts the address back; the next one returns to the page.
            if dropdown.isVisible || textView.string != original {
                dropdown.hide()
                suggestions = []
                typed = ""
                textView.string = original
                textView.selectAll(nil)
            } else {
                end(focusPage: true)
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab takes the inline completion.
            let range = textView.selectedRange()
            let length = (textView.string as NSString).length
            guard range.length > 0, NSMaxRange(range) == length else { return false }
            textView.setSelectedRange(NSRange(location: length, length: 0))
            typed = textView.string
            return true
        default:
            return false
        }
    }

    // MARK: Development hooks (DebugDriver)

    func debugType(_ text: String) {
        guard let editor = field?.currentEditor() as? NSTextView else { return }
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
        }
    }

    func debugKey(_ key: String) {
        guard let editor = field?.currentEditor() as? NSTextView else { return }
        let selector: Selector
        switch key {
        case "down": selector = #selector(NSResponder.moveDown(_:))
        case "up": selector = #selector(NSResponder.moveUp(_:))
        case "enter": selector = #selector(NSResponder.insertNewline(_:))
        case "tab": selector = #selector(NSResponder.insertTab(_:))
        case "delete": selector = #selector(NSResponder.deleteBackward(_:))
        default: selector = #selector(NSResponder.cancelOperation(_:))
        }
        editor.doCommand(by: selector)
    }

    var debugSummary: String {
        let text = (field?.currentEditor() as? NSTextView)?.string ?? field?.stringValue ?? "-"
        let range = (field?.currentEditor() as? NSTextView)?.selectedRange()
        let rows = dropdown.isVisible ? suggestions.prefix(Self.maxRows).map { "\($0.kind):\($0.title)" } : []
        return "address editing=\(isEditing) text=\(text) selection=\(range.map { NSStringFromRange($0) } ?? "-") "
            + "selected=\(selected) rows=\(rows) dropdown=\(dropdown.frameDescription)"
    }
}

// MARK: - The dropdown

/// Suggestions under the pill: a child window that never takes the keyboard,
/// so the field keeps typing.
@MainActor
private final class SuggestionDropdown {
    private var panel: DropdownPanel?
    private let effect = NSVisualEffectView()
    private var rows: [SuggestionRowView] = []

    private static let rowHeight: CGFloat = 36
    private static let inset: CGFloat = 6
    private static let gap: CGFloat = 6

    var isVisible: Bool { panel?.isVisible == true }
    var frameDescription: String { isVisible ? NSStringFromRect(panel?.frame ?? .zero) : "hidden" }

    func show(_ suggestions: [CommandSuggestion], selected: Int, under anchor: NSView,
              pick: @escaping (Int) -> Void, hover: @escaping (Int) -> Void) {
        guard let window = anchor.window else { return }
        let panel = self.panel ?? make()
        self.panel = panel
        rows.forEach { $0.removeFromSuperview() }
        rows = suggestions.enumerated().map { index, suggestion in
            let row = SuggestionRowView(suggestion: suggestion)
            row.onClick = { pick(index) }
            row.onHover = { hover(index) }
            row.isSelected = index == selected
            effect.addSubview(row)
            return row
        }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        place(under: anchor)
        panel.orderFront(nil)
    }

    func place(under anchor: NSView) {
        guard let panel, let window = anchor.window else { return }
        let pill = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let width = min(max(pill.width, 460), window.frame.width - 16)
        let x = max(window.frame.minX + 8, min(pill.minX, window.frame.maxX - 8 - width))
        let height = CGFloat(rows.count) * Self.rowHeight + Self.inset * 2
        panel.setFrame(NSRect(x: x, y: pill.minY - Self.gap - height, width: width, height: height), display: false)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: Self.inset, y: height - Self.inset - CGFloat(index + 1) * Self.rowHeight,
                               width: width - Self.inset * 2, height: Self.rowHeight)
        }
    }

    func select(_ index: Int) {
        for (i, row) in rows.enumerated() { row.isSelected = i == index }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func make() -> DropdownPanel {
        let panel = DropdownPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 100),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.isMovable = false
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = effect
        return panel
    }
}

private final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Suggestions (shared with the command bar)

enum Suggestions {
    struct Result {
        var rows: [CommandSuggestion]
        /// A visited site that starts with what was typed, to finish it inline ("git" → "github.com").
        var completion: String?
    }

    /// What the first row is when the text could be the start of a site you've visited.
    enum Autocomplete {
        /// That site's page you visited most (the command bar).
        case firstMatch
        /// The site itself, finished inline in the field (the address bar, typing forward).
        case inline
        /// Just the text as typed (the address bar, after deleting a completion).
        case none
    }

    @MainActor
    static func build(for raw: String, state: BrowserWindowState?, maxRows: Int, autocomplete: Autocomplete) -> Result {
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
            for tab in allTabs.sorted(by: { $0.lastActive > $1.lastActive }).prefix(5) where tab.id != state?.activeTabID {
                add(.init(kind: .tab, title: tab.displayTitle, subtitle: URLInput.display(tab.url),
                          value: "tab:\(tab.id)", hint: "Switch to Tab", tab: tab))
            }
            return Result(rows: result, completion: nil)
        }

        let resolved = URLInput.resolve(text, searchEngine: engine)
        let isSearch = resolved == engine.searchURL(for: text)
        let history = (state?.isPrivate ?? false) ? [] : HistoryStore.shared.search(text, limit: 8)

        var completion: String?
        if autocomplete == .inline, let site = siteCompletion(for: text, in: history) {
            completion = site.text
            add(.init(kind: .url, title: site.text, subtitle: "", value: site.url, hint: "Open"))
        }

        // A visited site whose host or domain starts with what you typed comes
        // first ("wiki" → en.wikipedia.org).
        let typed = text.lowercased()
        if autocomplete != .none, !text.contains(" "), let top = history.first,
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
            if seen.contains(tab.url) || tab.id == state?.activeTabID { continue }
            add(.init(kind: .tab, title: tab.displayTitle, subtitle: URLInput.display(tab.url),
                      value: "tab:\(tab.id)", hint: "Switch to Tab", tab: tab))
            seen.insert(tab.url)  // don't repeat an open tab as a history row
        }
        // Bookmarks (brought over from another browser) come before history.
        for bookmark in HistoryStore.shared.searchBookmarks(text, limit: 3) {
            if result.count >= maxRows - 3 { break }
            add(.init(kind: .bookmark, title: bookmark.title.isEmpty ? URLInput.display(bookmark.url) : bookmark.title,
                      subtitle: URLInput.display(bookmark.url), value: bookmark.url, hint: "Open"))
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
        add(.init(kind: .ask, title: text, subtitle: "Ask Winky", value: "ask:\(text)", hint: "⌘↩"))
        return Result(rows: Array(result.prefix(maxRows)), completion: completion)
    }

    /// A visited site whose address starts with what was typed: the address
    /// to finish the text with, and the URL to open.
    static func siteCompletion(for text: String, in history: [HistoryEntry]) -> (text: String, url: String)? {
        let typed = text.lowercased()
        guard !typed.isEmpty, !typed.contains(" "), !typed.contains("/") else { return nil }
        for entry in history {
            guard let parts = URLComponents(string: entry.url), let scheme = parts.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", let host = parts.host?.lowercased(), !host.isEmpty else { continue }
            let port = parts.port.map { ":\($0)" } ?? ""
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let domain = Site.registrableDomain(host)
            let candidates = [(host + port, host + port), (bare + port, host + port), (domain, domain)]
            for (candidate, address) in candidates where !candidate.isEmpty && candidate.hasPrefix(typed) {
                return (candidate, "\(scheme)://\(address)")
            }
        }
        return nil
    }

    @MainActor
    static func perform(_ suggestion: CommandSuggestion, on controller: BrowserWindowController, inNewTab: Bool) {
        switch suggestion.kind {
        case .tab:
            if let tab = suggestion.tab { AppDelegate.shared?.reveal(tab) }
        case .ask:
            controller.askWinky(suggestion.title)
        case .url, .search, .history, .bookmark:
            controller.open(suggestion.value, inNewTab: inNewTab)
        }
    }
}
