import AppKit
import Observation
import SwiftUI
import WinkEngine

/// Focus requests from AppKit into SwiftUI text fields.
@MainActor
@Observable
final class UIFocus {
    static let shared = UIFocus()
    var find = 0
}

struct EmptyStateView: View {
    let controller: BrowserWindowController

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityLabel("Wink")
            VStack(spacing: 8) {
                shortcut("⌘T", "Open or search")
                shortcut("⌘J", "Ask Wink")
                shortcut("⌘S", "Toggle sidebar")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { CommandBarController.shared.show(for: controller, mode: .newTab) }
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.6)))
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

struct ProgressBarView: View {
    let state: BrowserWindowState

    var body: some View {
        GeometryReader { proxy in
            let progress = max(0.08, state.activeTab?.progress ?? 0)
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: proxy.size.width * progress, height: 2)
                .animation(.easeOut(duration: 0.25), value: progress)
        }
    }
}

struct StatusBubbleView: View {
    let state: BrowserWindowState

    var body: some View {
        let text = state.activeTab?.statusText ?? ""
        HStack {
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            Spacer(minLength: 0)
        }
        .padding(.leading, 6).padding(.bottom, 6)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

/// The agent's presence on the page: who is working, what it is doing, and
/// the controls to pause or stop it. Collapses to a breathing orb.
struct AgentPillView: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController

    var body: some View {
        let settings = WinkSettings.shared
        if let tab = state.activeTab {
            let hub = AgentHub.shared
            let session = hub.controller(of: tab)
            let paused = session?.isPaused ?? false
            let name = hub.controllerName(for: tab) ?? "Agent"
            if settings.agentPillMinimized {
                Button { settings.agentPillMinimized = false } label: {
                    EyeMark(width: 26, blinking: !paused)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().strokeBorder(Theme.hairline))
                        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("\(name) is working here. Click for details.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    EyeMark(width: 28, blinking: !paused)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.system(size: 12, weight: .semibold))
                        Text(status(tab, session))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 6)
                    if let count = session?.actionCount, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .help("\(count) steps so far")
                    }
                    QuietIconButton(symbol: paused ? "play.fill" : "pause.fill",
                                    help: paused ? "Resume" : "Pause (you can also just click into the page)") {
                        hub.togglePause(for: tab)
                    }
                    StopButton { hub.stopAll(reason: "Stopped by you") }
                    QuietIconButton(symbol: state.agentLogExpanded ? "chevron.down" : "chevron.up",
                                    help: state.agentLogExpanded ? "Hide activity" : "Show activity") {
                        state.agentLogExpanded.toggle()
                    }
                }
                .padding(.leading, 11).padding(.trailing, 8)
                .frame(height: 44)
                .background(Capsule(style: .continuous).fill(.regularMaterial))
                .overlay(Capsule(style: .continuous).strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
            }
        }
    }

    private func status(_ tab: Tab, _ session: AgentSession?) -> String {
        if let reason = session?.pauseReason { return reason == "You took over" ? "Paused — you took over" : reason }
        return tab.agentAction ?? "Thinking…"
    }
}

/// Recent steps for the tab in view, above the pill.
struct AgentLogView: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController

    var body: some View {
        if let tab = state.activeTab {
            let hub = AgentHub.shared
            let entries = hub.recentActivity(for: tab, limit: 8)
            let session = hub.controller(of: tab)
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("Activity").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if session?.trusted == true {
                            Button("Conversation") { controller.showAgentPanel() }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .help("Open the agent panel (⌘J)")
                        }
                        QuietIconButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Shrink to a dot") {
                            state.agentLogExpanded = false
                            WinkSettings.shared.agentPillMinimized = true
                        }
                    }
                    .padding(.leading, 14).padding(.trailing, 8).padding(.top, 9).padding(.bottom, 4)
                    if entries.isEmpty {
                        Text("Nothing yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    ForEach(entries) { entry in
                        HStack(spacing: 9) {
                            Image(systemName: entry.symbol)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(entry.failed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                                .frame(width: 16)
                            Text(entry.description)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if entry.consequential {
                                Circle().fill(Color(nsColor: Theme.auroraNS[4])).frame(width: 5, height: 5)
                                    .help("Sent, bought, deleted or connected something for you")
                            }
                            Spacer(minLength: 8)
                            Text(Self.ago(entry.date, now: context.date))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4.5)
                    }
                }
                .padding(.bottom, 8)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                .padding(.horizontal, 1)
            }
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

/// A small round icon button that brightens on hover.
struct QuietIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct StopButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Stop")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemRed))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(Color(nsColor: .systemRed).opacity(hovering ? 0.18 : 0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Stop all agents (⇧⌘.)")
    }
}

struct FindBarView: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Find in page", text: $state.findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { controller.find(state.findQuery, forward: !NSEvent.modifierFlags.contains(.shift), next: true) }
                .onChange(of: state.findQuery) { _, query in controller.find(query) }
            if let tab = state.activeTab, !state.findQuery.isEmpty {
                Text("\(tab.findActiveMatch)/\(tab.findMatches)")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { controller.find(state.findQuery, forward: false, next: true) } label: {
                Image(systemName: "chevron.up")
            }.buttonStyle(.borderless)
            Button { controller.find(state.findQuery, forward: true, next: true) } label: {
                Image(systemName: "chevron.down")
            }.buttonStyle(.borderless)
            Button { controller.closeFindBar() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(2)
        .onAppear { focused = true }
        .onChange(of: UIFocus.shared.find) { _, _ in focused = true }
    }
}

struct PromptStackView: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController

    var body: some View {
        VStack(spacing: 8) {
            ForEach(state.prompts.prefix(2)) { prompt in
                PromptCard(prompt: prompt)
            }
        }
        .padding(4)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct PromptCard: View {
    let prompt: PromptRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Group {
                    if prompt.isAgent {
                        EyeMark(width: 26, blinking: true)
                    } else {
                        Image(systemName: prompt.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 26, height: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !prompt.message.isEmpty {
                        Text(prompt.message).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer()
                ForEach(Array(prompt.buttons.enumerated()), id: \.offset) { _, button in
                    if button.role == .primary {
                        Button(button.title, action: button.action)
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                    } else if button.role == .cancel {
                        Button(button.title, action: button.action).controlSize(.small)
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button(button.title, action: button.action).controlSize(.small)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
        .padding(.horizontal, 2)
    }
}

struct PageFailureView: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController

    var body: some View {
        let tab = state.activeTab
        VStack(spacing: 14) {
            Image(systemName: tab?.hasCrashed == true ? "exclamationmark.triangle" : "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(tab?.hasCrashed == true ? "This page stopped working" : "Can’t open this page")
                .font(.system(size: 17, weight: .semibold))
            if let failure = tab?.loadFailure, tab?.hasCrashed != true {
                Text(URLInput.display(failure.url)).font(.system(size: 13)).foregroundStyle(.secondary)
                Text(failure.description.isEmpty ? "Error \(failure.code)" : failure.description)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Button("Try Again") { controller.reload() }
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
