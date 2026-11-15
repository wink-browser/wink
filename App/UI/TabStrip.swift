import AppKit
import SwiftUI

// Tabs on top (Settings › General › Tabs): the window's chrome is two rows
// above the page instead of a sidebar beside it. The first row is the top bar:
// traffic lights, navigation, the address centred, and the tools. The second
// is the tab strip. Empty space in either row drags the window.

/// The first row: navigation, the address, the tools.
/// AppKit (not SwiftUI) so the space between them drags the window like a titlebar.
@MainActor
final class TopBarView: NSView {
    unowned let controller: BrowserWindowController
    private let back = SidebarHeaderView.button("chevron.left", "Back (⌘[)")
    private let forward = SidebarHeaderView.button("chevron.right", "Forward (⌘])")
    private let reload = SidebarHeaderView.button("arrow.clockwise", "Reload (⌘R)")
    private let address: NSHostingView<AddressPill>
    private let tools: NSHostingView<TopBarTools>
    private var loop: ObservationLoop?

    /// Where the navigation starts: just right of the traffic lights.
    static let navigationX: CGFloat = 80

    init(controller: BrowserWindowController) {
        self.controller = controller
        address = NSHostingView(rootView: AddressPill(state: controller.state, controller: controller))
        tools = NSHostingView(rootView: TopBarTools(state: controller.state, controller: controller))
        super.init(frame: .zero)
        let drag = WindowDragView()
        drag.autoresizingMask = [.width, .height]
        addSubview(drag)
        for button in [back, forward, reload] { addSubview(button) }
        // The address and tools sit in the titlebar; its safe area must not push them down.
        address.safeAreaRegions = []
        tools.safeAreaRegions = []
        addSubview(address)
        addSubview(tools)
        back.target = self; back.action = #selector(goBack)
        forward.target = self; forward.action = #selector(goForward)
        reload.target = self; reload.action = #selector(reloadOrStop)
        loop = ObservationLoop(track: { [weak self] in
            // What changes the tools' width: who is connected, downloads, a ready update.
            _ = AgentHub.shared.connectedClientNames
            _ = DownloadManager.shared.items.isEmpty
            _ = UpdateCenter.shared.readyVersion
            guard let tab = self?.controller.state.activeTab else { return }
            _ = tab.canGoBack; _ = tab.canGoForward; _ = tab.isLoading
        }, onChange: { [weak self] in
            self?.refresh()
            // SwiftUI redraws the tools on its next pass; measure them after it.
            DispatchQueue.main.async { self?.needsLayout = true }
        })
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        // Same line as the sidebar's header, which lines up with the traffic lights.
        let size: CGFloat = 26
        let y = (bounds.height - size) / 2 - 2
        back.frame = NSRect(x: Self.navigationX, y: y, width: size, height: size)
        forward.frame = NSRect(x: back.frame.maxX, y: y, width: size, height: size)
        reload.frame = NSRect(x: forward.frame.maxX, y: y, width: size, height: size)

        let toolsWidth = ceil(tools.fittingSize.width)
        tools.frame = NSRect(x: bounds.width - 12 - toolsWidth, y: y - 2, width: toolsWidth, height: 30)

        // The address is centred on the window, as wide as it can be up to 600,
        // and fills the gap instead when centring would leave it too narrow.
        let pillHeight: CGFloat = 32
        let pillY = (bounds.height - pillHeight) / 2 - 2
        let left = reload.frame.maxX + 16
        let right = tools.frame.minX - 16
        let half = min(300, bounds.midX - left, right - bounds.midX)
        address.frame = half >= 150
            ? NSRect(x: bounds.midX - half, y: pillY, width: half * 2, height: pillHeight)
            : NSRect(x: left, y: pillY, width: max(0, right - left), height: pillHeight)
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

    @objc private func goBack() { controller.goBack() }
    @objc private func goForward() { controller.goForward() }
    @objc private func reloadOrStop() {
        if controller.state.activeTab?.isLoading == true { controller.stopLoading() } else { controller.reload() }
    }
}

/// The sidebar footer's controls, at the end of the top bar.
struct TopBarTools: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController

    var body: some View {
        HStack(spacing: 6) {
            AgentsButton(state: state, controller: controller, maxWidth: 200)
            BrowserToolButtons()
        }
        .frame(height: 30)
    }
}

/// The tab strip's host. Past the last tab, clicks fall through to the
/// window-dragging view behind it.
final class TabStripHostingView<Content: View>: NSHostingView<Content> {
    var interactiveWidth: CGFloat = .greatestFiniteMagnitude

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard local.x <= interactiveWidth else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - The tab strip

/// Tab widths, worked out once for the strip and for its host.
@MainActor
struct TabStripLayout {
    static let spacing: CGFloat = 4
    static let tabHeight: CGFloat = 30
    static let pinnedWidth: CGFloat = 38
    static let newTabWidth: CGFloat = 30
    static let dividerWidth: CGFloat = 9
    static let minTabWidth: CGFloat = 44
    static let maxTabWidth: CGFloat = 240

    /// The width every tab gets: an equal share of the strip, between the min and the max.
    let tabWidth: CGFloat
    /// How far the strip's content reaches; past it, the strip drags the window.
    let contentWidth: CGFloat

    init(state: BrowserWindowState, width: CGFloat) {
        let pinned = CGFloat(state.pinnedTabs.count)
        let groups = AgentTabGroup.groups(state.agentTabs)
        let flexible = CGFloat(state.userTabs.count + state.agentTabs.count)
        var fixed = pinned * Self.pinnedWidth + Self.newTabWidth
        var items = pinned + 1 + flexible
        if !groups.isEmpty {
            fixed += Self.dividerWidth + groups.reduce(0) { $0 + StripGroupChip.width(for: $1.owner) }
            items += 1 + CGFloat(groups.count)
        }
        let gaps = max(0, items - 1) * Self.spacing
        if flexible > 0 {
            let share = ((width - fixed - gaps) / flexible).rounded(.down)
            tabWidth = min(Self.maxTabWidth, max(Self.minTabWidth, share))
        } else {
            tabWidth = 0
        }
        contentWidth = min(width, fixed + gaps + flexible * tabWidth)
    }
}

struct TabStripView: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController
    /// Reports how far the tabs reach, so the host can let the rest drag the window.
    let onContentWidth: (CGFloat) -> Void
    @State private var dragging: UUID?

    var body: some View {
        GeometryReader { proxy in
            let layout = TabStripLayout(state: state, width: proxy.size.width)
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TabStripLayout.spacing) {
                        ForEach(state.pinnedTabs) { tab in
                            StripPinnedTab(tab: tab, isActive: tab.id == state.activeTabID, controller: controller)
                                .id(tab.id)
                                .modifier(TabReordering(tab: tab, state: state, controller: controller, dragging: $dragging))
                        }
                        ForEach(state.userTabs) { tab in
                            StripTab(tab: tab, isActive: tab.id == state.activeTabID, width: layout.tabWidth,
                                     controller: controller)
                                .id(tab.id)
                                .modifier(TabReordering(tab: tab, state: state, controller: controller, dragging: $dragging))
                        }
                        StripNewTabButton(controller: controller)
                        let groups = AgentTabGroup.groups(state.agentTabs)
                        if !groups.isEmpty {
                            Rectangle().fill(Theme.hairline)
                                .frame(width: 1, height: 16)
                                .padding(.horizontal, (TabStripLayout.dividerWidth - 1) / 2)
                            ForEach(groups) { group in
                                StripGroupChip(group: group, controller: controller)
                                ForEach(group.tabs) { tab in
                                    StripTab(tab: tab, isActive: tab.id == state.activeTabID, width: layout.tabWidth,
                                             controller: controller)
                                        .id(tab.id)
                                }
                            }
                        }
                    }
                    .frame(height: proxy.size.height)
                }
                .onChange(of: state.activeTabID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(id) }
                }
            }
            .preference(key: ContentWidthKey.self, value: layout.contentWidth)
        }
        .onPreferenceChange(ContentWidthKey.self) { width in
            MainActor.assumeIsolated { onContentWidth(width) }
        }
    }

    private struct ContentWidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

/// Drag a tab onto another to move it there, as in the sidebar.
private struct TabReordering: ViewModifier {
    let tab: Tab
    let state: BrowserWindowState
    let controller: BrowserWindowController
    @Binding var dragging: UUID?

    func body(content: Content) -> some View {
        content
            .onDrag {
                dragging = tab.id
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, state: state, controller: controller,
                                                           dragging: $dragging))
    }
}

struct StripTab: View {
    let tab: Tab
    let isActive: Bool
    let width: CGFloat
    let controller: BrowserWindowController
    @State private var hovering = false

    var body: some View {
        // Narrow tabs keep only their icon, centred.
        let compact = width < 84
        HStack(spacing: 7) {
            if compact {
                Spacer(minLength: 0)
                FaviconView(tab: tab)
                Spacer(minLength: 0)
            } else {
                FaviconView(tab: tab)
                Text(tab.displayTitle)
                    .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                    .foregroundStyle(tab.isAsleep && !isActive ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if width >= 150 { TabBadges(tab: tab) }
                if hovering { TabCloseButton(tab: tab, controller: controller) }
            }
        }
        .padding(.horizontal, compact ? 4 : 8)
        .frame(width: width, height: TabStripLayout.tabHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(isActive ? Theme.rowSelected : (hovering ? Theme.rowHover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.select(tab) }
        .contextMenu { TabContextMenu(tab: tab, controller: controller) }
        .help(tab.displayTitle)
    }
}

struct StripPinnedTab: View {
    let tab: Tab
    let isActive: Bool
    let controller: BrowserWindowController
    @State private var hovering = false

    var body: some View {
        FaviconView(tab: tab)
            .frame(width: TabStripLayout.pinnedWidth, height: TabStripLayout.tabHeight)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(isActive ? Theme.rowSelected : Color.primary.opacity(hovering ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.35) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { controller.select(tab) }
            .contextMenu { TabContextMenu(tab: tab, controller: controller) }
            .help(tab.displayTitle)
    }
}

struct StripNewTabButton: View {
    let controller: BrowserWindowController
    @State private var hovering = false

    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: TabStripLayout.newTabWidth, height: TabStripLayout.tabHeight)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(hovering ? Theme.rowHover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { CommandBarController.shared.show(for: controller, mode: .newTab) }
            .help("New Tab (⌘T)")
            .accessibilityLabel("New Tab")
            .accessibilityAddTraits(.isButton)
    }
}

/// An agent's name before its tabs; hovering offers to close them all.
struct StripGroupChip: View {
    let group: AgentTabGroup
    let controller: BrowserWindowController
    @State private var hovering = false

    /// Fixed per name (long names truncate), so the strip can share out the rest before drawing.
    @MainActor
    static func width(for owner: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let name = (owner.uppercased() as NSString).size(withAttributes: [.font: font]).width
        return 6 + 16 + 5 + min(120, ceil(name)) + 5 + 16 + 4
    }

    var body: some View {
        HStack(spacing: 5) {
            EyeMark(width: 16)
            Text(group.owner.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button { group.tabs.forEach { controller.closeTab($0) } } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help("Close \(group.owner)'s tabs")
        }
        .padding(.leading, 6).padding(.trailing, 4)
        .frame(width: Self.width(for: group.owner), height: TabStripLayout.tabHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close All") { group.tabs.forEach { controller.closeTab($0) } }
        }
        .help("Tabs \(group.owner) opened")
    }
}
