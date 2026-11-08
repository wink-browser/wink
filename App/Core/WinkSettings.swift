import Foundation
import Observation

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo, kagi, brave, startpage, ecosia, google, bing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .kagi: "Kagi"
        case .brave: "Brave Search"
        case .startpage: "Startpage"
        case .ecosia: "Ecosia"
        case .google: "Google"
        case .bing: "Bing"
        }
    }

    func searchURL(for query: String) -> String {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/?q=\(q)"
        case .kagi: return "https://kagi.com/search?q=\(q)"
        case .brave: return "https://search.brave.com/search?q=\(q)"
        case .startpage: return "https://www.startpage.com/do/search?q=\(q)"
        case .ecosia: return "https://www.ecosia.org/search?q=\(q)"
        case .google: return "https://www.google.com/search?q=\(q)"
        case .bing: return "https://www.bing.com/search?q=\(q)"
        }
    }
}

enum AgentEngineKind: String, CaseIterable, Identifiable {
    /// Wink's built-in agent talking to the Anthropic API with the user's key.
    case claudeAPI
    /// The user's local Claude Code CLI, with Wink attached as an MCP server.
    case claudeCode

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claudeAPI: "Claude"
        case .claudeCode: "Claude Code"
        }
    }
}

enum AgentBrowsingProfile: String, CaseIterable, Identifiable {
    /// Agent-opened tabs get a fresh in-memory profile: no cookies, no logins.
    case isolated
    /// Agent-opened tabs share the user's profile (signed-in sessions).
    case shared

    var id: String { rawValue }
}

/// When Wink asks before an agent sends, buys, deletes, or connects.
enum AgentConfirmMode: String, CaseIterable, Identifiable {
    /// Ask the first time per site; the answer lasts for that agent session.
    case oncePerSite
    case always
    case never

    var id: String { rawValue }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}

/// User preferences, persisted to UserDefaults. Defaults are privacy-first.
@Observable
final class WinkSettings: @unchecked Sendable {
    static let shared = WinkSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    // General
    var searchEngine: SearchEngine { didSet { save(searchEngine.rawValue, "searchEngine") } }
    var restoreSession: Bool { didSet { save(restoreSession, "restoreSession") } }
    var sidebarVisible: Bool { didSet { save(sidebarVisible, "sidebarVisible") } }
    var sidebarWidth: Double { didSet { save(sidebarWidth, "sidebarWidth") } }
    var agentPanelWidth: Double { didSet { save(agentPanelWidth, "agentPanelWidth") } }

    // Privacy
    var blockTrackers: Bool { didSet { save(blockTrackers, "blockTrackers") } }
    var httpsUpgrades: Bool { didSet { save(httpsUpgrades, "httpsUpgrades") } }
    var globalPrivacyControl: Bool { didSet { save(globalPrivacyControl, "globalPrivacyControl") } }
    var blockThirdPartyCookies: Bool { didSet { save(blockThirdPartyCookies, "blockThirdPartyCookies") } }
    var searchSuggestions: Bool { didSet { save(searchSuggestions, "searchSuggestions") } }
    var shieldsDownSites: [String] { didSet { save(shieldsDownSites, "shieldsDownSites") } }
    var historyRetentionDays: Int { didSet { save(historyRetentionDays, "historyRetentionDays") } }

    // Performance
    /// Minutes of inactivity before a background tab is put to sleep (0 = never).
    var tabSleepMinutes: Int { didSet { save(tabSleepMinutes, "tabSleepMinutes") } }

    // Agents
    var agentEngine: AgentEngineKind { didSet { save(agentEngine.rawValue, "agentEngine") } }
    var claudeModel: String { didSet { save(claudeModel, "claudeModel") } }
    var claudeCodePath: String { didSet { save(claudeCodePath, "claudeCodePath") } }
    var claudeCodeWorkingDirectory: String { didSet { save(claudeCodeWorkingDirectory, "claudeCodeWorkingDirectory") } }
    var mcpServerEnabled: Bool { didSet { save(mcpServerEnabled, "mcpServerEnabled") } }
    var agentBrowsingProfile: AgentBrowsingProfile { didSet { save(agentBrowsingProfile.rawValue, "agentBrowsingProfile") } }
    var allowAgentJavaScript: Bool { didSet { save(allowAgentJavaScript, "allowAgentJavaScript") } }
    /// Sites agents may never read or act on (banking, password managers, ...).
    var agentProtectedSites: [String] { didSet { save(agentProtectedSites, "agentProtectedSites") } }
    /// MCP clients the user chose to always allow (by client name).
    var trustedAgentClients: [String] { didSet { save(trustedAgentClients, "trustedAgentClients") } }
    /// Guardrail: confirm consequential actions (send, buy, delete, connect).
    var agentConfirmMode: AgentConfirmMode { didSet { save(agentConfirmMode.rawValue, "agentConfirmMode") } }
    /// Guardrail: check in with the user after this many consequential actions
    /// on one site within an hour (0 = never).
    var agentHourlyLimit: Int { didSet { save(agentHourlyLimit, "agentHourlyLimit") } }
    /// Clicking or typing into a page an agent is driving pauses the agent.
    var agentPauseOnTakeover: Bool { didSet { save(agentPauseOnTakeover, "agentPauseOnTakeover") } }
    /// Show the agent's cursor and target highlights on the page.
    var agentShowCursor: Bool { didSet { save(agentShowCursor, "agentShowCursor") } }
    /// The on-page activity pill is collapsed to its orb.
    var agentPillMinimized: Bool { didSet { save(agentPillMinimized, "agentPillMinimized") } }

    private init() {
        let d = UserDefaults.standard
        searchEngine = SearchEngine(rawValue: d.string(forKey: "searchEngine") ?? "") ?? .duckDuckGo
        restoreSession = d.object(forKey: "restoreSession") as? Bool ?? true
        sidebarVisible = d.object(forKey: "sidebarVisible") as? Bool ?? true
        sidebarWidth = d.object(forKey: "sidebarWidth") as? Double ?? 248
        agentPanelWidth = d.object(forKey: "agentPanelWidth") as? Double ?? 380

        blockTrackers = d.object(forKey: "blockTrackers") as? Bool ?? true
        httpsUpgrades = d.object(forKey: "httpsUpgrades") as? Bool ?? true
        globalPrivacyControl = d.object(forKey: "globalPrivacyControl") as? Bool ?? true
        blockThirdPartyCookies = d.object(forKey: "blockThirdPartyCookies") as? Bool ?? true
        searchSuggestions = d.object(forKey: "searchSuggestions") as? Bool ?? false
        shieldsDownSites = d.stringArray(forKey: "shieldsDownSites") ?? []
        historyRetentionDays = d.object(forKey: "historyRetentionDays") as? Int ?? 90

        tabSleepMinutes = d.object(forKey: "tabSleepMinutes") as? Int ?? 30

        agentEngine = AgentEngineKind(rawValue: d.string(forKey: "agentEngine") ?? "") ?? .claudeCode
        claudeModel = d.string(forKey: "claudeModel") ?? "claude-opus-5-5"
        claudeCodePath = d.string(forKey: "claudeCodePath") ?? ""
        claudeCodeWorkingDirectory = d.string(forKey: "claudeCodeWorkingDirectory")
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        mcpServerEnabled = d.object(forKey: "mcpServerEnabled") as? Bool ?? true
        agentBrowsingProfile = AgentBrowsingProfile(rawValue: d.string(forKey: "agentBrowsingProfile") ?? "") ?? .isolated
        allowAgentJavaScript = d.object(forKey: "allowAgentJavaScript") as? Bool ?? false
        agentProtectedSites = d.stringArray(forKey: "agentProtectedSites") ?? [
            "1password.com", "bitwarden.com", "lastpass.com", "dashlane.com", "proton.me",
        ]
        trustedAgentClients = d.stringArray(forKey: "trustedAgentClients") ?? []
        agentConfirmMode = AgentConfirmMode(rawValue: d.string(forKey: "agentConfirmMode") ?? "") ?? .oncePerSite
        agentHourlyLimit = d.object(forKey: "agentHourlyLimit") as? Int ?? 30
        agentPauseOnTakeover = d.object(forKey: "agentPauseOnTakeover") as? Bool ?? true
        agentShowCursor = d.object(forKey: "agentShowCursor") as? Bool ?? true
        agentPillMinimized = d.object(forKey: "agentPillMinimized") as? Bool ?? false
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    func isShieldsDown(for host: String) -> Bool {
        let site = Site.registrableDomain(host)
        return shieldsDownSites.contains(site)
    }

    func isAgentProtected(host: String) -> Bool {
        let site = Site.registrableDomain(host)
        return agentProtectedSites.contains { site == $0 || host.hasSuffix("." + $0) || host == $0 }
    }
}
