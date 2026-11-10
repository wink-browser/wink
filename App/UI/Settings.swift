import AppKit
import SwiftUI
import WinkEngine

@MainActor
enum SettingsWindow {
    static func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Wink Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        return window
    }
}

/// Which Settings tab shows (so other places can open a specific one).
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var tab = "general"
}

struct SettingsView: View {
    @Bindable private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("privacy")
            AgentSettings().tabItem { Label("Agents", systemImage: "sparkles") }.tag("agents")
            PerformanceSettings().tabItem { Label("Performance", systemImage: "gauge.with.dots.needle.67percent") }.tag("performance")
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 640, height: 560)
    }
}

struct GeneralSettings: View {
    @Bindable var settings = WinkSettings.shared
    @Bindable var profile = Profile.shared
    @State private var defaultBrowserMessage = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ProfileAvatar(size: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Name", text: $profile.name, prompt: Text("Your name"))
                        HStack(spacing: 12) {
                            Button(profile.photo == nil ? "Add Photo…" : "Change Photo…") { profile.choosePhoto() }
                            if profile.photo != nil { Button("Remove Photo") { profile.removePhoto() } }
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Profile")
            } footer: {
                Text("Your profile stays on this Mac; there is no account. Winky uses your first name when you chat with her.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Search engine", selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Reopen tabs from last session", isOn: $settings.restoreSession)
            LabeledContent("Default browser") {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Make Wink the Default Browser") { makeDefault() }
                    if !defaultBrowserMessage.isEmpty {
                        Text(defaultBrowserMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func makeDefault() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            DispatchQueue.main.async {
                defaultBrowserMessage = error == nil ? "Wink is now your default browser." : "Could not change the default browser."
            }
        }
    }
}

struct PrivacySettings: View {
    @Bindable var settings = WinkSettings.shared
    @State private var newSite = ""

    var body: some View {
        Form {
            Section {
                Toggle("Block trackers and ads", isOn: $settings.blockTrackers)
                Toggle("Upgrade connections to HTTPS", isOn: $settings.httpsUpgrades)
                Toggle("Block third-party cookies", isOn: $settings.blockThirdPartyCookies)
                Toggle("Send Global Privacy Control", isOn: $settings.globalPrivacyControl)
                Toggle("Search suggestions while typing", isOn: $settings.searchSuggestions)
                    .help("Off by default: suggestions send every keystroke to your search engine.")
            } footer: {
                Text("\(WinkContentBlocker.ruleCount) blocking rules loaded. Wink never sends your browsing data anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Update Wink automatically", isOn: $settings.checkForUpdates)
                    .onChange(of: settings.checkForUpdates) { UpdateCenter.shared.applySettings() }
                Toggle("Share anonymous usage counts", isOn: $settings.shareUsageCounts)
                    .disabled(!settings.checkForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("Once a day Wink asks wink.minnebo.ai for the newest version, sending only Wink's and macOS's version. Updates are signed, verified, and installed when you quit. With usage counts on, the first check each day also says whether it's your first today, this week or this month. No identifier, history or profile detail is ever sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Picker("Keep history for", selection: $settings.historyRetentionDays) {
                    Text("1 day").tag(1); Text("1 week").tag(7); Text("1 month").tag(30)
                    Text("3 months").tag(90); Text("1 year").tag(365); Text("Forever").tag(0)
                }
                Button("Clear Browsing Data…") { PrivacyActions.clearBrowsingData() }
            }
            Section("Protections turned off") {
                if settings.shieldsDownSites.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(settings.shieldsDownSites, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button("Remove") { ContentBlockerService.shared.setShields(true, for: site) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.blockTrackers) { ContentBlockerService.shared.apply() }
        .onChange(of: settings.httpsUpgrades) { ContentBlockerService.shared.apply() }
        .onChange(of: settings.globalPrivacyControl) { ContentBlockerService.shared.apply() }
        .onChange(of: settings.blockThirdPartyCookies) {
            ContentBlockerService.shared.applyProfilePreferences(to: [WinkProfile.default])
        }
    }
}

struct AgentSettings: View {
    @Bindable var settings = WinkSettings.shared
    @State private var apiKey = ""
    @State private var apiKeySaved = Keychain.read("anthropic-api-key") != nil
    @State private var newProtected = ""
    @State private var claudeCodeStatus = ""

    var body: some View {
        Form {
            Section("Built-in agent") {
                Picker("Agent", selection: $settings.agentEngine) {
                    ForEach(AgentEngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.agentEngine == .claudeAPI {
                    TextField("Model", text: $settings.claudeModel)
                    HStack {
                        SecureField(apiKeySaved ? "API key saved in Keychain" : "Anthropic API key", text: $apiKey)
                        Button(apiKeySaved && apiKey.isEmpty ? "Remove" : "Save") {
                            if apiKey.isEmpty {
                                Keychain.delete("anthropic-api-key"); apiKeySaved = false
                            } else {
                                apiKeySaved = Keychain.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                                             account: "anthropic-api-key")
                                apiKey = ""
                            }
                        }
                    }
                } else {
                    TextField("Claude Code path", text: $settings.claudeCodePath, prompt: Text(ClaudeCodeLocator.find() ?? "claude"))
                    TextField("Working directory", text: $settings.claudeCodeWorkingDirectory)
                }
            }
            Section {
                Toggle("Let agents connect to Wink (MCP)", isOn: $settings.mcpServerEnabled)
                    .onChange(of: settings.mcpServerEnabled) { AgentHub.shared.restartServer() }
                ClaudeCodeLinkRow()
            } header: {
                Text("External agents")
            } footer: {
                Text("Agents connect through a private socket only you can reach, and Wink opens when one starts browsing. Wink asks before any new agent can browse, and agents only see tabs they open or that you share.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Before an agent sends, buys, deletes or connects", selection: $settings.agentConfirmMode) {
                    Text("Ask once per site").tag(AgentConfirmMode.oncePerSite)
                    Text("Ask every time").tag(AgentConfirmMode.always)
                    Text("Don't ask").tag(AgentConfirmMode.never)
                }
                Picker("Check in after", selection: $settings.agentHourlyLimit) {
                    Text("10 per site per hour").tag(10)
                    Text("30 per site per hour").tag(30)
                    Text("100 per site per hour").tag(100)
                    Text("Never").tag(0)
                }
                Toggle("Pause agents when I click or type in their page", isOn: $settings.agentPauseOnTakeover)
                Toggle("Show the agent's cursor and highlights", isOn: $settings.agentShowCursor)
            } header: {
                Text("Guardrails")
            } footer: {
                Text("Wink enforces these itself, whatever the agent was told. Sites can restrict accounts that send too many invitations or messages, so the hourly check-in also protects you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Agent safeguards") {
                Picker("Agent tabs use", selection: $settings.agentBrowsingProfile) {
                    Text("A private, signed-out profile").tag(AgentBrowsingProfile.isolated)
                    Text("My profile and logins").tag(AgentBrowsingProfile.shared)
                }
                Toggle("Allow agents to run JavaScript in pages", isOn: $settings.allowAgentJavaScript)
                    .onChange(of: settings.allowAgentJavaScript) { AgentHub.shared.refreshHandshake() }
                ForEach(settings.agentProtectedSites, id: \.self) { site in
                    HStack {
                        Image(systemName: "lock.shield").foregroundStyle(.secondary)
                        Text(site)
                        Spacer()
                        Button("Remove") { settings.agentProtectedSites.removeAll { $0 == site } }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Never let agents use…", text: $newProtected, prompt: Text("e.g. mybank.com"))
                    Button("Add") {
                        let site = newProtected.trimmingCharacters(in: .whitespaces).lowercased()
                        if !site.isEmpty && !settings.agentProtectedSites.contains(site) { settings.agentProtectedSites.append(site) }
                        newProtected = ""
                    }
                }
                if !settings.trustedAgentClients.isEmpty {
                    ForEach(settings.trustedAgentClients, id: \.self) { client in
                        HStack {
                            Text("Always allowed: \(client)")
                            Spacer()
                            Button("Revoke") { settings.trustedAgentClients.removeAll { $0 == client } }.buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PerformanceSettings: View {
    @Bindable var settings = WinkSettings.shared

    var body: some View {
        Form {
            Picker("Put inactive tabs to sleep after", selection: $settings.tabSleepMinutes) {
                Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("30 minutes").tag(30)
                Text("1 hour").tag(60); Text("4 hours").tag(240); Text("Never").tag(0)
            }
            Text("Sleeping tabs use no memory or CPU. They keep their place and reload when you select them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
            Text("wink").font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Chromium \(WinkRuntime.chromiumVersion)").font(.caption).foregroundStyle(.secondary)
            Text("Engine \(WinkRuntime.engineVersion)").font(.caption2).foregroundStyle(.tertiary)
            Button("Check for Updates…") { UpdateCenter.shared.checkNow() }
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Settings › Agents: whether Claude Code has Wink's browser tools.
struct ClaudeCodeLinkRow: View {
    @Bindable private var link = ClaudeCodeLink.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Claude Code can browse with Wink", isOn: Binding(
                get: { link.status == .connected },
                set: { $0 ? link.connect() : link.disconnect() }))
                .disabled(link.busy || link.status == .notInstalled || !WinkSettings.shared.mcpServerEnabled)
            HStack(spacing: 8) {
                Text(detail)
                Spacer(minLength: 0)
                Button("Copy Setup Command") { link.copyAddCommand() }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { link.refresh() }
    }

    private var detail: String {
        switch link.status {
        case .connected: "In Claude Code's MCP servers, for every project. Try “open localhost:3000 in Wink”."
        case .otherCopy(let path): "Claude Code uses the Wink at \((path as NSString).deletingLastPathComponent.replacingOccurrences(of: "/Contents/MacOS", with: "")). Turn on to use this one."
        case .notInstalled: "Install Claude Code and Wink connects to it by itself."
        case .notConnected, .unknown: "Off. Turn on to add Wink to Claude Code's MCP servers."
        }
    }
}

/// Finds the user's Claude Code CLI.
enum ClaudeCodeLocator {
    static func find() -> String? {
        let configured = WinkSettings.shared.claudeCodePath
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) { return configured }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
