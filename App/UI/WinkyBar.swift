import AppKit
import SwiftUI

/// Winky, on the page: a floating prompt bar at the bottom of the web content
/// (⌘J) and, above it, a card with her latest answer. It shares the
/// conversation with the sidebar panel (⌥⌘J), which remains for long chats.
/// While Winky works the bar becomes her status line, with Pause and Stop.
struct WinkyBarView: View {
    let state: BrowserWindowState
    let controller: BrowserWindowController
    /// Reports the natural height so the host can size itself to the content
    /// (clicks outside the bar and card reach the page).
    let onHeight: (CGFloat) -> Void

    @Bindable private var model = AgentPanelModel.shared
    @FocusState private var focused: Bool
    @State private var stepsOpen = false

    var body: some View {
        VStack(spacing: 10) {
            if let exchange = model.latestExchange, !model.answerHidden {
                answerCard(exchange)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            bar
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(HeightKey.self) { height in
            MainActor.assumeIsolated { onHeight(height) }
        }
        .animation(.smooth(duration: 0.25), value: model.answerHidden)
        .animation(.smooth(duration: 0.25), value: model.isRunning)
        .onChange(of: model.barFocusToken) { focused = true }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    // MARK: The bar

    private var bar: some View {
        HStack(alignment: .center, spacing: 10) {
            WinkyAvatar(size: 28)
            if model.isRunning {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Winky").font(.system(size: 12, weight: .semibold))
                    Text(statusLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 8)
                if let tab = state.activeTab, AgentHub.shared.controller(of: tab) != nil {
                    let paused = AgentHub.shared.controller(of: tab)?.isPaused ?? false
                    QuietIconButton(symbol: paused ? "play.fill" : "pause.fill", help: paused ? "Resume" : "Pause") {
                        AgentHub.shared.togglePause(for: tab)
                    }
                }
                StopButton { AgentHub.shared.stopAll(reason: "Stopped by you") }
            } else {
                TextField(placeholder, text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { send() }
                    .onExitCommand { close() }
                Button { send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSend ? Color(nsColor: Theme.cobaltNS) : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Ask (↩)")
            }
            QuietIconButton(symbol: "xmark", help: "Close (Esc)") { close() }
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.auroraBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
    }

    private var placeholder: String {
        let page = state.activeTab.map { $0.url.isEmpty ? "" : " about this page" } ?? ""
        return "Ask Winky\(page)…"
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusLine: String {
        if let tab = state.activeTab, tab.agentActive, let action = tab.agentAction { return action }
        return "Thinking…"
    }

    // MARK: The answer card

    private func answerCard(_ exchange: AgentPanelModel.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(exchange.question)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                QuietIconButton(symbol: "sidebar.right", help: "Continue in the sidebar (⌥⌘J)") {
                    model.answerHidden = true
                    state.winkyBarVisible = false
                    controller.showAgentPanel()
                }
                QuietIconButton(symbol: "xmark", help: "Hide answer") { model.answerHidden = true }
            }
            if !exchange.steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Button { stepsOpen.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: stepsOpen ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Text("\(exchange.steps.count) step\(exchange.steps.count == 1 ? "" : "s")")
                            if let last = exchange.steps.last, !stepsOpen {
                                Text("· \(last.title)").lineLimit(1).truncationMode(.tail)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    if stepsOpen {
                        ForEach(Array(exchange.steps.suffix(12).enumerated()), id: \.offset) { _, step in
                            HStack(spacing: 7) {
                                Image(systemName: step.symbol).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                                Text(step.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if !exchange.answer.isEmpty {
                ScrollView {
                    MarkdownText(text: exchange.answer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            } else if model.isRunning {
                Text("Working on it…").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if let error = exchange.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Color(nsColor: .systemOrange)).lineLimit(4)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }

    // MARK: Actions

    private func send() {
        guard canSend else { return }
        model.answerHidden = false
        stepsOpen = false
        model.send(model.draft)
    }

    private func close() {
        state.winkyBarVisible = false
        state.activeTab?.webView?.focusContent()
    }

    private struct HeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}
