import AppKit
import Observation
import SwiftUI

/// Re-runs `onChange` whenever anything read inside `track` changes.
@MainActor
final class ObservationLoop {
    private let track: () -> Void
    private let onChange: () -> Void
    private var active = true

    init(track: @escaping () -> Void, onChange: @escaping () -> Void) {
        self.track = track
        self.onChange = onChange
        observe()
    }

    private func observe() {
        guard active else { return }
        withObservationTracking(track) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.active else { return }
                self.onChange()
                self.observe()
            }
        }
    }

    func cancel() { active = false }
}

/// A hosting view that never takes mouse events (decorative overlays).
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Root of a browser window. Manual frame layout keeps resizing cheap and
/// predictable around the Chromium view.
@MainActor
final class BrowserRootView: NSView {
    unowned let controller: BrowserWindowController
    private let background = NSVisualEffectView()
    private let sidebarContainer = FlippedView()
    private let sidebarPeekBackground = NSVisualEffectView()
    private let header: SidebarHeaderView
    private let sidebarHost: NSHostingView<SidebarView>
    let content: ContentContainerView
    /// The aurora's spill onto the window around the card (behind it).
    let outerGlow = AuroraGlowView(placement: .outer)
    private let agentHost: NSHostingView<AgentPanelView>
    private let sidebarResizer = ResizeHandleView()
    private let agentResizer = ResizeHandleView()
    private var loop: ObservationLoop?
    private var trackingArea: NSTrackingArea?

    private var state: BrowserWindowState { controller.state }
    private var settings: WinkSettings { WinkSettings.shared }

    init(controller: BrowserWindowController) {
        self.controller = controller
        header = SidebarHeaderView(controller: controller)
        sidebarHost = NSHostingView(rootView: SidebarView(state: controller.state, controller: controller))
        content = ContentContainerView(controller: controller)
        agentHost = NSHostingView(rootView: AgentPanelView(model: AgentPanelModel.shared, window: controller))
        super.init(frame: .zero)

        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        addSubview(background)

        sidebarPeekBackground.material = .popover
        sidebarPeekBackground.blendingMode = .withinWindow
        sidebarPeekBackground.state = .active
        sidebarPeekBackground.wantsLayer = true
        sidebarPeekBackground.layer?.cornerRadius = 12
        sidebarPeekBackground.layer?.masksToBounds = true
        sidebarPeekBackground.isHidden = true

        sidebarContainer.wantsLayer = true
        sidebarContainer.addSubview(sidebarPeekBackground)
        sidebarContainer.addSubview(header)
        sidebarContainer.addSubview(sidebarHost)

        addSubview(outerGlow)
        addSubview(content)
        addSubview(agentHost)
        addSubview(sidebarContainer)  // above content so the peeking sidebar overlays it
        content.outerGlow = outerGlow

        sidebarResizer.onDrag = { [weak self] delta in
            guard let self else { return }
            self.settings.sidebarWidth = min(Theme.sidebarMaxWidth, max(Theme.sidebarMinWidth, self.settings.sidebarWidth + delta))
            self.needsLayout = true
        }
        agentResizer.onDrag = { [weak self] delta in
            guard let self else { return }
            self.settings.agentPanelWidth = min(Theme.agentPanelMaxWidth, max(Theme.agentPanelMinWidth, self.settings.agentPanelWidth - delta))
            self.needsLayout = true
        }
        addSubview(sidebarResizer)
        addSubview(agentResizer)

        loop = ObservationLoop(track: { [weak self] in
            guard let self else { return }
            _ = self.state.sidebarVisible
            _ = self.state.sidebarPeeking
            _ = self.state.agentPanelVisible
            _ = self.state.contentFullscreen
        }, onChange: { [weak self] in
            self?.needsLayout = true
            self?.controller.updateTrafficLights()
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutPanes()
    }

    func animateLayout() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            layoutPanes(animated: true)
        }
    }

    private func layoutPanes(animated: Bool = false) {
        let bounds = self.bounds
        background.frame = bounds
        let inset = Theme.contentInset
        let sidebarWidth = CGFloat(settings.sidebarWidth)
        let agentWidth = CGFloat(settings.agentPanelWidth)

        func place(_ view: NSView, _ frame: NSRect) {
            if animated { view.animator().frame = frame } else { view.frame = frame }
        }

        if state.contentFullscreen {
            place(content, bounds)
            outerGlow.frame = bounds
            content.setFullBleed(true)
            sidebarContainer.isHidden = true
            agentHost.isHidden = true
            sidebarResizer.isHidden = true
            agentResizer.isHidden = true
            return
        }
        content.setFullBleed(false)

        let sidebarShown = state.sidebarVisible
        let peeking = !sidebarShown && state.sidebarPeeking
        let left = sidebarShown ? sidebarWidth : inset
        let right = state.agentPanelVisible ? bounds.width - agentWidth : bounds.width - inset
        let card = NSRect(x: left, y: inset, width: max(120, right - left), height: max(80, bounds.height - inset * 2))
        place(content, card)
        place(outerGlow, card.insetBy(dx: -outerGlow.spill, dy: -outerGlow.spill))

        sidebarContainer.isHidden = !(sidebarShown || peeking)
        let sidebarFrame = peeking
            ? NSRect(x: 4, y: 4, width: sidebarWidth, height: bounds.height - 8)
            : NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        place(sidebarContainer, sidebarFrame)
        sidebarPeekBackground.isHidden = !peeking
        sidebarPeekBackground.frame = sidebarContainer.bounds
        sidebarContainer.shadow = peeking ? {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 18
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            return shadow
        }() : nil
        header.frame = NSRect(x: 0, y: 0, width: sidebarFrame.width, height: Theme.titlebarHeight)
        sidebarHost.frame = NSRect(x: 0, y: Theme.titlebarHeight, width: sidebarFrame.width,
                                   height: sidebarFrame.height - Theme.titlebarHeight)

        agentHost.isHidden = !state.agentPanelVisible
        place(agentHost, NSRect(x: bounds.width - agentWidth, y: 0, width: agentWidth, height: bounds.height))

        sidebarResizer.isHidden = !sidebarShown
        sidebarResizer.frame = NSRect(x: sidebarWidth - 4, y: 0, width: 8, height: bounds.height)
        agentResizer.isHidden = !state.agentPanelVisible
        agentResizer.frame = NSRect(x: bounds.width - agentWidth - 4, y: 0, width: 8, height: bounds.height)
    }

    func focusAgentComposer() {
        AgentPanelModel.shared.focusToken += 1
    }

    // MARK: - Hover-to-peek sidebar

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard !state.sidebarVisible, !state.contentFullscreen else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if !state.sidebarPeeking && x <= 6 {
            state.sidebarPeeking = true
        } else if state.sidebarPeeking && x > CGFloat(settings.sidebarWidth) + 24 {
            state.sidebarPeeking = false
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        content.updateAppearance()
    }
}

/// Top of the sidebar: traffic-light gutter, sidebar toggle and navigation.
/// AppKit (not SwiftUI) so window dragging behaves exactly like a titlebar.
@MainActor
final class SidebarHeaderView: NSView {
    unowned let controller: BrowserWindowController
    private var loop: ObservationLoop?
    private let back = SidebarHeaderView.button("chevron.left", "Back (⌘[)")
    private let forward = SidebarHeaderView.button("chevron.right", "Forward (⌘])")
    private let reload = SidebarHeaderView.button("arrow.clockwise", "Reload (⌘R)")
    private let toggle = SidebarHeaderView.button("sidebar.left", "Toggle Sidebar (⌘S)")

    init(controller: BrowserWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        let drag = WindowDragView()
        drag.autoresizingMask = [.width, .height]
        addSubview(drag)
        for button in [toggle, back, forward, reload] { addSubview(button) }
        toggle.target = self; toggle.action = #selector(toggleSidebar)
        back.target = self; back.action = #selector(goBack)
        forward.target = self; forward.action = #selector(goForward)
        reload.target = self; reload.action = #selector(reloadOrStop)
        loop = ObservationLoop(track: { [weak self] in
            guard let tab = self?.controller.state.activeTab else { return }
            _ = tab.canGoBack; _ = tab.canGoForward; _ = tab.isLoading
        }, onChange: { [weak self] in self?.refresh() })
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    private static func button(_ symbol: String, _ tooltip: String) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.setButtonType(.momentaryChange)
        return button
    }

    override func layout() {
        super.layout()
        let size: CGFloat = 26
        let y = (Theme.titlebarHeight - size) / 2 - 2
        toggle.frame = NSRect(x: 76, y: y, width: size, height: size)
        reload.frame = NSRect(x: bounds.width - 8 - size, y: y, width: size, height: size)
        forward.frame = NSRect(x: reload.frame.minX - size, y: y, width: size, height: size)
        back.frame = NSRect(x: forward.frame.minX - size, y: y, width: size, height: size)
    }

    private func refresh() {
        let tab = controller.state.activeTab
        back.isEnabled = tab?.canGoBack ?? false
        forward.isEnabled = tab?.canGoForward ?? false
        let symbol = tab?.isLoading == true ? "xmark" : "arrow.clockwise"
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        reload.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        reload.toolTip = tab?.isLoading == true ? "Stop (⌘.)" : "Reload (⌘R)"
    }

    @objc private func toggleSidebar() { controller.toggleSidebar() }
    @objc private func goBack() { controller.goBack() }
    @objc private func goForward() { controller.goForward() }
    @objc private func reloadOrStop() {
        if controller.state.activeTab?.isLoading == true { controller.stopLoading() } else { controller.reload() }
    }
}

/// Behaves like a titlebar: drag moves the window, double-click zooms.
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            return
        }
        window?.performDrag(with: event)
    }
}

/// Invisible vertical splitter used to resize the sidebar / agent panel.
final class ResizeHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX)
        lastX = x
    }
}
