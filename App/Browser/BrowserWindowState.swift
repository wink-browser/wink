import AppKit
import Observation
import WinkEngine

/// A pending decision shown as a small card above the page: site permission
/// requests and agent consent requests share this one surface.
@MainActor
final class PromptRequest: Identifiable {
    struct Button {
        enum Role { case primary, normal, cancel }
        let title: String
        let role: Role
        let action: () -> Void
    }

    let id = UUID()
    let symbol: String
    let title: String
    let message: String
    let isAgent: Bool
    let tabID: UUID?
    let buttons: [Button]

    init(symbol: String, title: String, message: String, isAgent: Bool = false, tabID: UUID?, buttons: [Button]) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.isAgent = isAgent
        self.tabID = tabID
        self.buttons = buttons
    }
}

@MainActor
@Observable
final class BrowserWindowState {
    var tabs: [Tab] = []
    var activeTabID: UUID?
    let isPrivate: Bool
    var sidebarVisible: Bool
    var sidebarPeeking = false
    var agentPanelVisible = false
    var contentFullscreen = false
    var findBarVisible = false
    var findQuery = ""
    var prompts: [PromptRequest] = []
    /// The agent pill's activity log is open.
    var agentLogExpanded = false
    /// Winky's welcome card is showing over this window.
    var welcomeVisible = false
    var shieldsPopoverVisible = false
    var downloadsPopoverVisible = false

    @ObservationIgnored let privateProfile: WinkProfile?

    init(isPrivate: Bool, sidebarVisible: Bool = WinkSettings.shared.sidebarVisible) {
        self.isPrivate = isPrivate
        self.sidebarVisible = sidebarVisible
        privateProfile = isPrivate ? WinkProfile.ephemeralProfile(withName: "Private") : nil
    }

    var activeTab: Tab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    var visibleTabs: [Tab] { tabs.filter { !$0.isClosing && !$0.closeRequested } }
    var pinnedTabs: [Tab] { visibleTabs.filter { $0.isPinned } }
    var userTabs: [Tab] { visibleTabs.filter { !$0.isPinned && $0.agentOwnerID == nil } }
    var agentTabs: [Tab] { visibleTabs.filter { !$0.isPinned && $0.agentOwnerID != nil } }

    /// Tabs in the order they appear in the sidebar (for ⌘1…⌘9 / ⌃Tab).
    var orderedTabs: [Tab] { pinnedTabs + userTabs + agentTabs }

    var defaultProfile: WinkProfile { privateProfile ?? WinkProfile.default }
}
