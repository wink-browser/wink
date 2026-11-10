import AppKit
import Observation
import SwiftUI

/// First-run welcome, hosted by Winky: a card over the dimmed browser window.
/// Four short steps — hello, your (local) profile, a few honest choices, and
/// the agents — each with one clear action. Reopen it from Wink › Welcome.
@MainActor
@Observable
final class WelcomeModel {
    static let shared = WelcomeModel()
    var step = 0
    var defaultBrowserNote = ""
    let steps = 4
}

struct WelcomeOverlay: View {
    let controller: BrowserWindowController

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture {}  // the page beneath is not clickable while welcoming
            WelcomeCard(controller: controller)
                .padding(24)
        }
        .ignoresSafeArea()
    }
}

private struct WelcomeCard: View {
    let controller: BrowserWindowController
    @Bindable private var model = WelcomeModel.shared
    @Bindable private var settings = WinkSettings.shared
    @Bindable private var profile = Profile.shared
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            portrait
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch model.step {
                    case 0: hello
                    case 1: you
                    case 2: choices
                    default: agents
                    }
                }
                .id(model.step)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 18)),
                                        removal: .opacity.combined(with: .offset(x: -18))))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 28)
        }
        .frame(width: 780, height: 500)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.28), radius: 40, y: 18)
        .animation(.smooth(duration: 0.35), value: model.step)
    }

    // Winky, full height, on her coral paper, with her name in the corner.
    private var portrait: some View {
        Color(nsColor: Theme.coralNS)
            .frame(width: 300)
            .overlay {
                if let image = Winky.portrait {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text("Winky")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(nsColor: Theme.cobaltNS))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color(nsColor: Theme.paperNS).opacity(0.94)))
                    .padding(18)
            }
    }

    // MARK: Steps

    private var hello: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hi, I'm Winky.")
                .font(.system(size: 30, weight: .semibold))
            Text("Welcome to Wink: a private browser where AI agents work in plain sight. I'll help you settle in. It takes a minute.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                point("hand.raised", "Agents ask before they send, buy or delete anything.")
                point("eye", "You see every step they take, and can stop them any time.")
                point("lock", "No account, no tracking. Your profile stays on this Mac.")
            }
            .padding(.top, 10)
        }
    }

    private var you: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What should I call you?")
                .font(.system(size: 26, weight: .semibold))
            HStack(spacing: 16) {
                ProfileAvatar(size: 64)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Your name", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 15))
                        .focused($nameFocused)
                        .onSubmit { advance() }
                    HStack(spacing: 12) {
                        Button(profile.photo == nil ? "Add a photo…" : "Change photo…") { profile.choosePhoto() }
                            .buttonStyle(.link)
                        if profile.photo != nil {
                            Button("Remove") { profile.removePhoto() }.buttonStyle(.link)
                        }
                    }
                    .font(.system(size: 13))
                }
            }
            .padding(.top, 6)
            Text("Your profile stays on this Mac. There's no account to make.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { nameFocused = true } }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(profile.firstName.isEmpty ? "A few choices" : "A few choices, \(profile.firstName)")
                .font(.system(size: 26, weight: .semibold))
            row("Search with") {
                Picker("", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("Default browser") {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Make Wink My Default Browser") { makeDefault() }
                    if !model.defaultBrowserNote.isEmpty {
                        Text(model.defaultBrowserNote).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            if let source = BrowserImport.available.first {
                row("Your things") {
                    Button("Import from \(source.shortName)…") { AppDelegate.shared?.showImport(nil) }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Share anonymous usage counts", isOn: $settings.shareUsageCounts)
                    .toggleStyle(.switch)
                Text("Once a day: Wink's version and whether you used it this week. No name, no history, nothing about you. It tells a small team whether Wink is working for people.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("I'm one ⌘J away.")
                .font(.system(size: 26, weight: .semibold))
            Text("Ask me about any page, or give me a task, and I'll do it right beside you."
                 + (ClaudeCodeLink.shared.status == .connected ? "" : " Claude Code can drive Wink too."))
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if ClaudeCodeLink.shared.status == .connected {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Claude Code can browse with Wink", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                    Text("Wink added itself to Claude Code. Ask it to “open localhost:3000 in Wink”; Wink asks you before it browses. Turn this off in Settings › Agents.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } else if ClaudeCodeLocator.find() != nil {
                Button("Connect Claude Code") { ClaudeCodeLink.shared.connect() }
                    .disabled(ClaudeCodeLink.shared.busy)
                    .padding(.top, 4)
            } else {
                Text("To chat with me, add an Anthropic API key in Settings › Agents, or install Claude Code.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                shortcut("⌘T", "Open a site, search, or ask")
                shortcut("⌘J", "Talk to Winky")
                shortcut("⇧⌘.", "Stop every agent")
            }
            .padding(.top, 8)
        }
    }

    // MARK: Pieces

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<model.steps, id: \.self) { index in
                    Capsule()
                        .fill(index == model.step ? Color(nsColor: Theme.cobaltNS) : Color.primary.opacity(0.15))
                        .frame(width: index == model.step ? 18 : 6, height: 6)
                }
            }
            .animation(.smooth(duration: 0.3), value: model.step)
            .accessibilityLabel("Step \(model.step + 1) of \(model.steps)")
            Spacer()
            if model.step == 0 {
                Button("Skip") { finish() }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Button("Back") { model.step -= 1 }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Button(primaryTitle) { advance() }
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: Theme.cobaltNS))
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 13))
    }

    private var primaryTitle: String {
        switch model.step {
        case 0: "Let's Begin"
        case 1: profile.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Skip" : "Continue"
        case model.steps - 1: "Start Browsing"
        default: "Continue"
        }
    }

    private func advance() {
        if model.step < model.steps - 1 { model.step += 1 } else { finish() }
    }

    private func finish() {
        WinkSettings.shared.onboardingComplete = true
        controller.state.welcomeVisible = false
        model.step = 0
        if controller.state.activeTab == nil {
            DispatchQueue.main.async { CommandBarController.shared.show(for: controller, mode: .newTab) }
        }
    }

    private func makeDefault() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { error in
            DispatchQueue.main.async {
                WelcomeModel.shared.defaultBrowserNote = error == nil ? "Done. Links now open in Wink." : "macOS didn't allow the change. You can do it in System Settings."
            }
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: Theme.cobaltNS))
                .frame(width: 16)
            Text(text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
            content()
        }
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                .frame(minWidth: 44, alignment: .leading)
            Text(label).font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }
}
