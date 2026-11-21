import AppKit
import SwiftUI
import WinkEngine

// The address bar. At rest it says where you are, centred: a lock, the site in
// the primary ink, the path in a quieter one (a search shows its words). Click
// anywhere on it, or press ⌘L, and it becomes a field in place: the address
// selected, a site you have visited finished inline as you type, and
// suggestions dropping down right under it. ⌘T still opens the command bar for
// a new tab.
//
// The bar is AppKit, not SwiftUI. With tabs on top it sits in the titlebar,
// where AppKit hands a click on a SwiftUI view to window dragging; and a
// SwiftUI tap on top of the field's own click ended the edit it had just begun.

// MARK: - The bar

@MainActor
final class AddressBarView: NSView {
    /// As tall as a tab, so the bar and the tab strip under it read as one set.
    static let height: CGFloat = 30

    /// The tab placement this bar is shown in. Only the bar on screen edits.
    let placement: TabPlacement
    let field = AddressTextField()
    private unowned let controller: BrowserWindowController
    private let searchIcon = NSImageView()
    private let shieldHost: NSHostingView<AddressShieldSlot>
    private let privateHost: PassthroughHostingView<PrivateBadge>
    private var loop: ObservationLoop?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var wasEditing = false
    private var privateTip: NSView.ToolTipTag?

    private static let padding: CGFloat = 10
    /// The shield and its count, at the end of the bar.
    private static let shieldWidth: CGFloat = 30
    /// "Private", at the start of the bar in a private window.
    private static let privateWidth: CGFloat = 56
    /// One line of 13 pt text, centred on the bar.
    private static let lineHeight: CGFloat = 17

    init(controller: BrowserWindowController, placement: TabPlacement) {
        self.controller = controller
        self.placement = placement
        shieldHost = NSHostingView(rootView: AddressShieldSlot(state: controller.state))
        privateHost = PassthroughHostingView(rootView: PrivateBadge())
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
        searchIcon.contentTintColor = .tertiaryLabelColor
        // The bar sits in the titlebar; its safe area must not push the badges down.
        shieldHost.safeAreaRegions = []
        privateHost.safeAreaRegions = []
        for view in [searchIcon, field, privateHost, shieldHost] as [NSView] { addSubview(view) }

        loop = ObservationLoop(track: { [weak self] in
            guard let self else { return }
            _ = self.controller.addressEditor.isEditing
            _ = WinkSettings.shared.tabPlacement
            _ = self.controller.state.activeTab?.url
        }, onChange: { [weak self] in self?.refresh() })
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The placement on screen is this bar's: it is the one that edits.
    private var owns: Bool { WinkSettings.shared.tabPlacement == placement }
    private var isEditingHere: Bool { owns && controller.addressEditor.isEditing }

    private func refresh() {
        let editor = controller.addressEditor
        field.editor = owns ? editor : nil
        field.delegate = owns ? editor : nil
        if owns { editor.attach(self) }
        field.show(AddressDisplay.text(for: controller.state.activeTab?.url ?? ""))
        let editing = isEditingHere
        toolTip = editing ? nil : "Search or enter address (⌘L)"
        if editing != wasEditing {
            wasEditing = editing
            // The address at rest and the field cross-fade.
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            layer?.add(fade, forKey: "editing")
        }
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        let editing = isEditingHere
        let isWeb = controller.state.activeTab?.url.hasPrefix("http") ?? false
        let showShield = !editing && isWeb
        let showPrivate = !editing && controller.state.isPrivate
        searchIcon.isHidden = !editing
        shieldHost.isHidden = !showShield
        privateHost.isHidden = !showPrivate

        let pad = Self.padding
        let height = bounds.height
        let lineY = ((height - Self.lineHeight) / 2).rounded()
        if editing {
            let icon: CGFloat = 16
            searchIcon.frame = NSRect(x: pad, y: ((height - icon) / 2).rounded(), width: icon, height: icon)
            let x = pad + icon + 6
            field.frame = NSRect(x: x, y: lineY, width: max(0, bounds.width - x - pad), height: Self.lineHeight)
        } else {
            let leading = pad + (showPrivate ? Self.privateWidth : 0) + 4
            let trailing = pad + (showShield ? Self.shieldWidth : 0) + 4
            // A wide bar keeps equal room on both sides, so the address sits on
            // its centre; a narrow one (the sidebar's) gives the address all it can.
            let wide = bounds.width >= 360
            let left = wide ? max(leading, trailing) : leading
            let right = wide ? max(leading, trailing) : trailing
            field.frame = NSRect(x: left, y: lineY, width: max(0, bounds.width - left - right), height: Self.lineHeight)
        }
        privateHost.frame = NSRect(x: pad - 2, y: ((height - 20) / 2).rounded(), width: Self.privateWidth, height: 20)
        shieldHost.frame = NSRect(x: bounds.width - pad - Self.shieldWidth, y: ((height - 22) / 2).rounded(),
                                  width: Self.shieldWidth, height: 22)
        if let privateTip { removeToolTip(privateTip) }
        privateTip = showPrivate
            ? addToolTip(privateHost.frame, owner: "Private window: nothing is saved, and agents can't see these tabs" as NSString,
                         userData: nil)
            : nil
    }

    // MARK: Drawing

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let editing = isEditingHere
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill = editing
            ? NSColor.textBackgroundColor.withAlphaComponent(dark ? 0.55 : 1)
            : NSColor.labelColor.withAlphaComponent(hovering ? 0.085 : 0.055)
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = editing ? 1.5 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Mouse

    // A click anywhere on the bar edits: it never drags the window, and the
    // first click on an inactive window counts too, as in Safari.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard owns else { return }
        controller.addressEditor.begin(selectingAll: !isEditingHere)
    }

    override func resetCursorRects() {
        if owns && !isEditingHere { addCursorRect(field.frame, cursor: .iBeam) }
    }

    // At rest, a right click offers the address, and to go where the clipboard says.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard owns, !isEditingHere else { return super.menu(for: event) }
        let menu = NSMenu()
        let url = controller.state.activeTab?.url ?? ""
        if !url.isEmpty, url != "about:blank" {
            menu.addItem(withTitle: "Copy Link", action: #selector(copyLink), keyEquivalent: "").target = self
        }
        if let text = Self.pasteboardText {
            let engine = WinkSettings.shared.searchEngine
            let isSearch = URLInput.resolve(text, searchEngine: engine) == engine.searchURL(for: text)
            menu.addItem(withTitle: isSearch ? "Paste and Search" : "Paste and Go", action: #selector(pasteAndGo),
                         keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Edit Address", action: #selector(editAddress), keyEquivalent: "").target = self
        return menu
    }

    private static var pasteboardText: String? {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty || text.count > 2048 ? nil : text
    }

    @objc private func copyLink() {
        guard let url = controller.state.activeTab?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc private func pasteAndGo() {
        guard let text = Self.pasteboardText else { return }
        controller.open(text, inNewTab: false)
    }

    @objc private func editAddress() {
        controller.addressEditor.begin()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// The bar inside SwiftUI (the sidebar).
struct AddressBar: NSViewRepresentable {
    let controller: BrowserWindowController
    let placement: TabPlacement

    func makeNSView(context: Context) -> AddressBarView {
        AddressBarView(controller: controller, placement: placement)
    }

    func updateNSView(_ view: AddressBarView, context: Context) {}
}

/// The privacy shield at the end of the bar, for the page on screen.
struct AddressShieldSlot: View {
    let state: BrowserWindowState

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let tab = state.activeTab { ShieldButton(tab: tab, state: state) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PrivateBadge: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Private")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.purple)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.purple.opacity(0.15)))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // A click here edits; it never drags the window, and it counts on an inactive window too.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // The first click takes the whole address, as in Safari; once editing,
        // clicks place the caret and select as in any field.
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
/// suggestions drop down under the bar.
@MainActor
@Observable
final class AddressEditor: NSObject, NSTextFieldDelegate {
    private(set) var isEditing = false

    @ObservationIgnored private weak var controller: BrowserWindowController?
    /// The bar on screen (the sidebar's or the top bar's).
    @ObservationIgnored private weak var bar: AddressBarView?
    private var field: AddressTextField? { bar?.field }
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

    func attach(_ bar: AddressBarView) {
        guard self.bar !== bar else { return }
        let previous = self.bar
        self.bar = bar
        guard isEditing else { return }
        // The tabs moved to the other side mid-edit: stop editing in the old
        // bar, once this update has finished.
        DispatchQueue.main.async { [weak self] in
            if let previous {
                if previous.field.currentEditor() != nil { previous.window?.makeFirstResponder(nil) }
                previous.field.endEditing()
            }
            self?.end(focusPage: false)
        }
    }

    /// Edits in place when the bar is on screen; otherwise opens the command bar.
    /// Asking again while editing keeps the edit (⌘L selects the address again).
    func begin(selectingAll: Bool = true) {
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
        // Take the keyboard only if the field hasn't got it: making it first
        // responder again would end the edit and start a new one.
        if field.currentEditor() == nil { window.makeFirstResponder(field) }
        if selectingAll { field.currentEditor()?.selectAll(nil) }
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
        guard let anchor = bar, !suggestions.isEmpty, anchor.window?.isKeyWindow == true || DebugDriver.isHeadless else {
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
                    guard let self, let anchor = self.bar else { return }
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

/// Suggestions under the bar: a child window that never takes the keyboard,
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
        let bar = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let width = min(max(bar.width, 460), window.frame.width - 16)
        let x = max(window.frame.minX + 8, min(bar.minX, window.frame.maxX - 8 - width))
        let height = CGFloat(rows.count) * Self.rowHeight + Self.inset * 2
        panel.setFrame(NSRect(x: x, y: bar.minY - Self.gap - height, width: width, height: height), display: false)
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

        // A site's front page reads the same with or without its last slash.
        func key(_ value: String) -> String { value.hasSuffix("/") ? String(value.dropLast()) : value }
        func add(_ suggestion: CommandSuggestion) {
            guard !seen.contains(key(suggestion.value)) else { return }
            seen.insert(key(suggestion.value))
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
            // Never the page you're on: switching to it, or opening it again, goes nowhere.
            if let open = allTabs.first(where: { $0.url == top.url && $0.id != state?.activeTabID }) {
                add(.init(kind: .tab, title: open.displayTitle, subtitle: URLInput.display(open.url),
                          value: "tab:\(open.id)", hint: "Switch to Tab", tab: open))
                seen.insert(key(open.url))
            } else if top.url != state?.activeTab?.url {
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
            if seen.contains(key(tab.url)) || tab.id == state?.activeTabID { continue }
            add(.init(kind: .tab, title: tab.displayTitle, subtitle: URLInput.display(tab.url),
                      value: "tab:\(tab.id)", hint: "Switch to Tab", tab: tab))
            seen.insert(key(tab.url))  // don't repeat an open tab as a history row
        }
        // Bookmarks (brought over from another browser) come before history.
        for bookmark in HistoryStore.shared.searchBookmarks(text, limit: 3) {
            if result.count >= maxRows - 3 { break }
            add(.init(kind: .bookmark, title: bookmark.title.isEmpty ? URLInput.display(bookmark.url) : bookmark.title,
                      subtitle: URLInput.display(bookmark.url), value: bookmark.url, hint: "Open"))
        }
        for entry in history where entry.url != state?.activeTab?.url {
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
