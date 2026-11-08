import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WinkEngine

struct SidebarView: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController
    @State private var dragging: UUID?

    var body: some View {
        VStack(spacing: 0) {
            AddressPill(state: state, controller: controller)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    if !state.pinnedTabs.isEmpty {
                        PinnedGrid(state: state, controller: controller, dragging: $dragging)
                            .padding(.bottom, 8)
                    }
                    ForEach(state.userTabs) { tab in
                        TabRow(tab: tab, isActive: tab.id == state.activeTabID, controller: controller)
                            .onDrag {
                                dragging = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, state: state,
                                                                           controller: controller, dragging: $dragging))
                    }
                    NewTabRow(controller: controller)

                    if !state.agentTabs.isEmpty {
                        AgentTabsSection(state: state, controller: controller)
                            .padding(.top, 14)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            SidebarFooter(state: state, controller: controller)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Address pill

struct AddressPill: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController
    @State private var hovering = false

    var body: some View {
        let tab = state.activeTab
        HStack(spacing: 6) {
            if state.isPrivate {
                Text("Private")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
                    .help("Private window: nothing is saved, and agents can't see these tabs")
            }
            if let tab, tab.url.hasPrefix("http://"), !ContentBlockerService.isLocal(tab.url) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .help("Not secure: this page is not using HTTPS")
            }
            Text(tab.map { URLInput.display($0.url) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Search or enter address")
                .font(.system(size: 12.5))
                .foregroundStyle(tab == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let tab, tab.url.hasPrefix("http") {
                ShieldButton(tab: tab, state: state)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.09 : 0.06)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { CommandBarController.shared.show(for: controller, mode: .navigate) }
        .help("Search or enter address (⌘L)")
    }
}

struct ShieldButton: View {
    let tab: Tab
    let state: BrowserWindowState
    @State private var showing = false

    var body: some View {
        let down = WinkSettings.shared.isShieldsDown(for: tab.host_)
        Button { showing.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: down ? "shield.slash" : "shield.lefthalf.filled")
                    .font(.system(size: 11))
                if tab.blockedCount > 0 && !down {
                    Text("\(tab.blockedCount)").font(.system(size: 10.5, weight: .medium).monospacedDigit())
                }
            }
            .foregroundStyle(down ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ShieldsPopover(tab: tab)
        }
        .help("Privacy protections")
    }
}

struct ShieldsPopover: View {
    let tab: Tab

    var body: some View {
        let settings = WinkSettings.shared
        let site = Site.registrableDomain(tab.host_)
        let down = settings.isShieldsDown(for: tab.host_)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(site).font(.system(size: 14, weight: .semibold))
                    Text(down ? "Protections are off for this site" : "Protections are on")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { !down },
                    set: { on in ContentBlockerService.shared.setShields(on, for: tab.host_); tab.reload() }))
                .toggleStyle(.switch).labelsHidden()
            }
            Divider()
            stat("Trackers & ads blocked on this page", "\(tab.blockedCount)")
            stat("Blocked this session", "\(PrivacyStats.shared.blockedThisSession)")
            stat("Third-party cookies", settings.blockThirdPartyCookies ? "Blocked" : "Allowed")
            stat("HTTPS upgrades", settings.httpsUpgrades ? "On" : "Off")
            stat("Global Privacy Control", settings.globalPrivacyControl ? "Sent" : "Off")
            if !tab.lastBlockedHost.isEmpty {
                Text("Last blocked: \(tab.lastBlockedHost)")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Button("Forget This Site…") { ContentBlockerService.shared.forget(site: site, tab: tab) }
                .controlSize(.small)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tabs

struct FaviconView: View {
    let tab: Tab

    var body: some View {
        Group {
            if tab.isLoading && tab.favicon == nil {
                ProgressView().controlSize(.mini).scaleEffect(0.8)
            } else if let favicon = tab.favicon {
                Image(nsImage: favicon).resizable().interpolation(.high)
            } else {
                Image(systemName: tab.isPrivate ? "eyeglasses" : "globe")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(tab.isAsleep ? 0.55 : 1)
    }
}

struct TabRow: View {
    let tab: Tab
    let isActive: Bool
    let controller: BrowserWindowController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            FaviconView(tab: tab)
            Text(tab.displayTitle)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
                .foregroundStyle(tab.isAsleep && !isActive ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 2)
            if tab.agentActive || tab.agentOwnerID != nil {
                EyeMark(width: 17, blinking: tab.agentActive)
                    .help(tab.agentActive ? "An agent is working here" : "Opened by an agent")
            }
            if tab.sharedWithAgents {
                Image(systemName: "person.2.wave.2").font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Shared with agents")
            }
            if tab.isCapturingMedia {
                Image(systemName: "record.circle").font(.system(size: 10)).foregroundStyle(.red)
            }
            if tab.isAudioMuted {
                Image(systemName: "speaker.slash.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if hovering {
                Button { controller.closeTab(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .fill(isActive ? Theme.rowSelected : (hovering ? Theme.rowHover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { controller.select(tab) }
        .contextMenu { TabContextMenu(tab: tab, controller: controller) }
        .help(tab.url)
    }
}

struct TabContextMenu: View {
    let tab: Tab
    let controller: BrowserWindowController

    var body: some View {
        Button("Reload") { tab.reload() }
        Button("Duplicate") { controller.duplicate(tab) }
        Button(tab.isPinned ? "Unpin" : "Pin") { controller.togglePin(tab) }
        Button(tab.isAudioMuted ? "Unmute" : "Mute") { tab.isAudioMuted.toggle() }
        Divider()
        Button(tab.sharedWithAgents ? "Stop Sharing with Agents" : "Share with Agents") {
            tab.sharedWithAgents.toggle()
        }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url, forType: .string)
        }
        Divider()
        Button("Close Other Tabs") { controller.closeOtherTabs(except: tab) }
        Button("Close Tab") { controller.closeTab(tab) }
    }
}

struct TabDropDelegate: DropDelegate {
    let target: Tab
    let state: BrowserWindowState
    let controller: BrowserWindowController
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target.id,
              let tab = state.tabs.first(where: { $0.id == dragging }) else { return }
        withAnimation(.easeOut(duration: 0.15)) { controller.moveTab(tab, before: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct NewTabRow: View {
    let controller: BrowserWindowController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 16)
            Text("New Tab").font(.system(size: 13))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: Theme.rowHeight)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovering ? Theme.rowHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { CommandBarController.shared.show(for: controller, mode: .newTab) }
    }
}

struct PinnedGrid: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController
    @Binding var dragging: UUID?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(state.pinnedTabs) { tab in
                PinnedTile(tab: tab, isActive: tab.id == state.activeTabID, controller: controller)
                    .onDrag {
                        dragging = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, state: state,
                                                                   controller: controller, dragging: $dragging))
            }
        }
    }
}

struct PinnedTile: View {
    let tab: Tab
    let isActive: Bool
    let controller: BrowserWindowController
    @State private var hovering = false

    var body: some View {
        FaviconView(tab: tab)
            .scaleEffect(1.1)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Theme.rowSelected : Color.primary.opacity(hovering ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.35) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { controller.select(tab) }
            .contextMenu { TabContextMenu(tab: tab, controller: controller) }
            .help(tab.displayTitle)
    }
}

struct AgentTabsSection: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController

    var body: some View {
        let groups = Dictionary(grouping: state.agentTabs) { $0.agentOwnerName ?? "Agent" }
        ForEach(groups.keys.sorted(), id: \.self) { owner in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    EyeMark(width: 16)
                    Text(owner.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Close All") { groups[owner]?.forEach { controller.closeTab($0) } }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).padding(.bottom, 2)
                ForEach(groups[owner] ?? []) { tab in
                    TabRow(tab: tab, isActive: tab.id == state.activeTabID, controller: controller)
                }
            }
        }
    }
}

// MARK: - Footer

struct SidebarFooter: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController
    @State private var showDownloads = false

    var body: some View {
        let hub = AgentHub.shared
        let downloads = DownloadManager.shared
        HStack(spacing: 4) {
            Button { controller.toggleAgentPanel() } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(hub.connectedClientNames.isEmpty ? Color.secondary.opacity(0.4) : Color.green)
                        .frame(width: 6, height: 6)
                    Text(hub.connectedClientNames.isEmpty ? "Agents" : hub.connectedClientNames.joined(separator: ", "))
                        .font(.system(size: 12)).lineLimit(1)
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(state.agentPanelVisible ? Theme.rowSelected : .clear))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Agents (⌘J)")

            Spacer()

            if !downloads.items.isEmpty {
                Button { showDownloads.toggle() } label: {
                    Image(systemName: downloads.hasActive ? "arrow.down.circle.dotted" : "arrow.down.circle")
                        .font(.system(size: 13))
                        .symbolEffect(.pulse, isActive: downloads.hasActive)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .popover(isPresented: $showDownloads, arrowEdge: .top) { DownloadsPopover() }
                .help("Downloads")
            }
            Button { AppDelegate.shared?.showSettings(nil) } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}

struct DownloadsPopover: View {
    var body: some View {
        let manager = DownloadManager.shared
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") { manager.clearFinished() }.buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(manager.items.prefix(8)) { item in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                        .resizable().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.fileName).font(.system(size: 12)).lineLimit(1)
                        if item.isActive {
                            ProgressView(value: item.fraction).controlSize(.small)
                        } else {
                            Text(item.isComplete ? ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file)
                                 : (item.isCanceled ? "Canceled" : "Failed"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if item.isComplete {
                        Button { manager.reveal(item) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if item.isComplete { manager.open(item) } }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
