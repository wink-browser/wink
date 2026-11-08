import AppKit
import SwiftUI
import WinkEngine

/// The rounded "card" that hosts web content plus its overlays.
///
/// Live tabs keep their Chromium view as a hidden subview so switching is
/// instant; Chromium sees hidden views as backgrounded and throttles them.
@MainActor
final class ContentContainerView: NSView {
    unowned let controller: BrowserWindowController
    private let clip = FlippedView()
    private let emptyHost: NSHostingView<EmptyStateView>
    private let progressHost: PassthroughHostingView<ProgressBarView>
    private let statusHost: PassthroughHostingView<StatusBubbleView>
    /// Aurora inside the card while an agent works (the outer half lives in
    /// BrowserRootView, behind the card).
    let glow = AuroraGlowView(placement: .inner)
    weak var outerGlow: AuroraGlowView?
    /// The agent's cursor, highlights and page effects.
    let agentOverlay = AgentOverlayView(frame: .zero)
    private let findHost: NSHostingView<FindBarView>
    private let promptHost: NSHostingView<PromptStackView>
    private let agentPillHost: NSHostingView<AgentPillView>
    private let agentLogHost: NSHostingView<AgentLogView>
    /// Winky's prompt bar and answer card, floating over the page (⌘J).
    private var winkyBarHost: NSHostingView<WinkyBarView>!
    private var winkyBarHeight: CGFloat = 60
    private let failureHost: NSHostingView<PageFailureView>
    private var loop: ObservationLoop?
    private var fullBleed = false

    private var state: BrowserWindowState { controller.state }

    init(controller: BrowserWindowController) {
        self.controller = controller
        let state = controller.state
        emptyHost = NSHostingView(rootView: EmptyStateView(controller: controller))
        progressHost = PassthroughHostingView(rootView: ProgressBarView(state: state))
        statusHost = PassthroughHostingView(rootView: StatusBubbleView(state: state))
        findHost = NSHostingView(rootView: FindBarView(state: state, controller: controller))
        promptHost = NSHostingView(rootView: PromptStackView(state: state, controller: controller))
        agentPillHost = NSHostingView(rootView: AgentPillView(state: state, controller: controller))
        agentLogHost = NSHostingView(rootView: AgentLogView(state: state, controller: controller))
        failureHost = NSHostingView(rootView: PageFailureView(state: state, controller: controller))
        super.init(frame: .zero)

        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        clip.wantsLayer = true
        clip.layer?.cornerRadius = Theme.contentRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        clip.layer?.borderWidth = 0.5
        addSubview(clip)

        for overlay in [emptyHost, failureHost, glow, agentOverlay, progressHost, statusHost, findHost,
                        promptHost, agentLogHost, agentPillHost] as [NSView] {
            overlay.isHidden = true
            clip.addSubview(overlay)
        }
        // Overlays float over the page; the titlebar's safe area must not
        // push them down (that is what misaligned the old glow).
        for host in [emptyHost, failureHost, progressHost, statusHost, findHost, promptHost, agentLogHost, agentPillHost] as [NSView] {
            (host as? any SafeAreaIgnoring)?.ignoreSafeArea()
        }
        agentOverlay.isHidden = false
        winkyBarHost = NSHostingView(rootView: WinkyBarView(state: state, controller: controller) { [weak self] height in
            guard let self, height > 0, abs(height - self.winkyBarHeight) > 0.5 else { return }
            self.winkyBarHeight = height
            self.needsLayout = true
        })
        winkyBarHost.safeAreaRegions = []
        winkyBarHost.isHidden = true
        clip.addSubview(winkyBarHost)
        updateAppearance()

        loop = ObservationLoop(track: { [weak self] in
            guard let self else { return }
            _ = self.state.activeTabID
            _ = self.state.findBarVisible
            _ = self.state.prompts.count
            _ = self.state.agentLogExpanded
            _ = self.state.winkyBarVisible
            _ = WinkSettings.shared.agentPillMinimized
            if self.state.agentLogExpanded { _ = AgentHub.shared.activity.count }
            if let tab = self.state.activeTab {
                _ = tab.isLoading; _ = tab.statusText; _ = tab.agentAction; _ = tab.agentActive
                _ = tab.hasCrashed; _ = tab.loadFailure
                _ = AgentHub.shared.controller(of: tab)?.isPaused
            }
        }, onChange: { [weak self] in self?.updateOverlays() })
        updateOverlays()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setFullBleed(_ value: Bool) {
        guard value != fullBleed else { return }
        fullBleed = value
        clip.layer?.cornerRadius = value ? 0 : Theme.contentRadius
        clip.layer?.borderWidth = value ? 0 : 0.5
        layer?.shadowOpacity = value ? 0 : 0.12
        glow.cornerRadius = value ? 0 : Theme.contentRadius
        updateOverlays()
    }

    func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            clip.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
            clip.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    // MARK: - Web views

    /// Ensures the tab has a live Chromium view inside this card.
    func attach(_ tab: Tab, visible: Bool) {
        let view = tab.ensureWebView(frame: clip.bounds)
        if view.superview !== clip {
            view.frame = clip.bounds
            view.autoresizingMask = [.width, .height]
            clip.addSubview(view, positioned: .below, relativeTo: emptyHost)
        }
        view.isHidden = !visible
    }

    func show(_ tab: Tab?) {
        for case let view as WinkWebView in clip.subviews where view !== tab?.webView {
            view.isHidden = true
        }
        if let tab { attach(tab, visible: true) }
        agentOverlay.hideAll()
        updateOverlays()
    }

    func focusFindField() {
        UIFocus.shared.find += 1
    }

    /// True while typing in the Winky bar (its field editor lives inside the host).
    var winkyBarHasFocus: Bool {
        guard let host = winkyBarHost, !host.isHidden, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: host)
    }

    // MARK: - Overlays

    private func updateOverlays() {
        let tab = state.activeTab
        emptyHost.isHidden = tab != nil
        progressHost.isHidden = tab?.isLoading != true
        statusHost.isHidden = (tab?.statusText ?? "").isEmpty
        let agentHere = tab.map { AgentHub.shared.isControlled($0) } ?? false
        let paused = tab.flatMap { AgentHub.shared.controller(of: $0) }?.isPaused ?? false
        glow.setLit(agentHere, dimmed: paused)
        outerGlow?.setLit(agentHere && !fullBleed, dimmed: paused)
        // With the Winky bar open, Winky's own work shows in the bar instead of the pill.
        let winkyWorking = tab.flatMap { AgentHub.shared.controller(of: $0) }?.trusted ?? false
        let barShowsIt = state.winkyBarVisible && (winkyWorking || !agentHere)
        agentPillHost.isHidden = !agentHere || barShowsIt
        agentLogHost.isHidden = !agentHere || barShowsIt || !state.agentLogExpanded || WinkSettings.shared.agentPillMinimized
        winkyBarHost?.isHidden = !state.winkyBarVisible
        if !agentHere { agentOverlay.hideAll() }
        findHost.isHidden = !state.findBarVisible || tab == nil
        promptHost.isHidden = state.prompts.isEmpty
        failureHost.isHidden = !(tab?.hasCrashed == true || tab?.loadFailure != nil)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        clip.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.contentRadius,
                                   cornerHeight: Theme.contentRadius, transform: nil)
        let b = clip.bounds
        emptyHost.frame = b
        failureHost.frame = b
        glow.frame = b
        agentOverlay.frame = b
        progressHost.frame = NSRect(x: 0, y: 0, width: b.width, height: 3)
        let statusWidth = min(560, b.width * 0.6)
        statusHost.frame = NSRect(x: 0, y: b.height - 30, width: statusWidth, height: 30)
        let findWidth: CGFloat = 340
        findHost.frame = NSRect(x: b.width - findWidth - 10, y: 10, width: findWidth, height: 44)
        let promptWidth = min(460, b.width - 24)
        let promptHeight = max(60, min(b.height - 24, promptHost.fittingSize.height))
        promptHost.frame = NSRect(x: (b.width - promptWidth) / 2, y: 14, width: promptWidth, height: promptHeight)
        if WinkSettings.shared.agentPillMinimized {
            agentPillHost.frame = NSRect(x: b.width - 56, y: b.height - 56, width: 44, height: 44)
        } else {
            let pillWidth = min(460, b.width - 32)
            agentPillHost.frame = NSRect(x: (b.width - pillWidth) / 2, y: b.height - 60, width: pillWidth, height: 46)
            let logHeight = min(b.height * 0.55, max(80, agentLogHost.fittingSize.height))
            agentLogHost.frame = NSRect(x: (b.width - pillWidth) / 2, y: agentPillHost.frame.minY - logHeight - 6,
                                        width: pillWidth, height: logHeight)
        }
        let barWidth = min(640, b.width - 48)
        winkyBarHost?.frame = NSRect(x: (b.width - barWidth) / 2, y: b.height - winkyBarHeight - 16,
                                     width: barWidth, height: winkyBarHeight)
        // Another agent's pill stacks above the open Winky bar instead of under it.
        if let bar = winkyBarHost, !bar.isHidden, !agentPillHost.isHidden, !WinkSettings.shared.agentPillMinimized {
            agentPillHost.frame.origin.y = bar.frame.minY - agentPillHost.frame.height - 8
            agentLogHost.frame.origin.y = agentPillHost.frame.minY - agentLogHost.frame.height - 6
        }
        for case let view as WinkWebView in clip.subviews { view.frame = b }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Hosting views used as overlays opt out of the window's titlebar safe area.
@MainActor
protocol SafeAreaIgnoring {
    func ignoreSafeArea()
}

extension NSHostingView: SafeAreaIgnoring {
    func ignoreSafeArea() {
        safeAreaRegions = []
    }
}
