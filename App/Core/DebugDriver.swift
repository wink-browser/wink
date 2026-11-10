import AppKit
import CoreGraphics
import WinkEngine

/// Development-only automation hooks, enabled with WINK_DEBUG_DIR=<dir>.
///   kill -USR1 <pid>  → writes window snapshots to <dir>/window-N.png
///   kill -USR2 <pid>  → runs commands listed in <dir>/commands.txt
/// Never active in normal launches.
@MainActor
final class DebugDriver {
    static let shared = DebugDriver()

    /// WINK_DEBUG_HEADLESS=1 (with WINK_DEBUG_DIR): an invisible, click-through
    /// test instance that never activates or shows windows, so automated tests
    /// can run next to the user's own Wink without disturbing them.
    nonisolated static let isHeadless: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["WINK_DEBUG_DIR"] != nil && env["WINK_DEBUG_HEADLESS"] == "1"
    }()
    private var sources: [DispatchSourceSignal] = []
    private var directory: URL?

    func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["WINK_DEBUG_DIR"] else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        for (sig, handler) in [(SIGUSR1, snapshot), (SIGUSR2, runCommands)] as [(Int32, () -> Void)] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { handler() } }
            source.resume()
            sources.append(source)
        }
        try? "\(getpid())".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        NSLog("[wink] debug driver active at %@", dir.path)
    }

    /// CGWindowListCreateImage is unavailable to new code in the macOS 26 SDK
    /// but still works for an app's own windows; resolve it at runtime.
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private lazy var createImage: CreateImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    private func snapshot() {
        if Self.isHeadless || CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            Task { await captureOffscreen() }
            return
        }
        // Occluded windows aren't painted (Chromium pauses them too), so bring
        // ours to the front visually, without taking keyboard focus.
        NSApp.windows.filter { $0.isVisible }.forEach { $0.orderFrontRegardless() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.capture() }
    }

    /// Display asleep: render the UI layer tree directly and composite a
    /// Chromium screenshot of the active tab into the content card.
    private func captureOffscreen() async {
        guard let directory else { return }
        var index = 0
        for controller in AppDelegate.shared?.windows ?? [] {
            let root = controller.root!
            let bounds = root.bounds
            let scale: CGFloat = 2
            guard let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { continue }
            context.scaleBy(x: scale, y: scale)
            root.effectiveAppearance.performAsCurrentDrawingAppearance {
                context.setFillColor(NSColor.underPageBackgroundColor.cgColor)
            }
            context.fill(CGRect(origin: .zero, size: bounds.size))
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            // render(in:) ignores masks, so the aurora paints itself.
            let outer = controller.root.outerGlow
            outer.layer?.isHidden = true
            root.layer?.render(in: context)
            outer.layer?.isHidden = false
            if outer.isLit {
                context.saveGState()
                context.translateBy(x: outer.frame.minX, y: outer.frame.minY)
                outer.drawSnapshot(in: context)
                context.restoreGState()
            }
            context.restoreGState()
            if let tab = controller.state.activeTab, tab.webView != nil,
               let jpeg = try? await tab.cdp.screenshot(maxWidth: 4000, quality: 85, pixelRatio: 2).data,
               let image = NSImage(data: jpeg)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let card = controller.root.content.frame
                let rect = CGRect(x: card.minX, y: bounds.height - card.maxY, width: card.width, height: card.height)
                context.saveGState()
                context.addPath(CGPath(roundedRect: rect, cornerWidth: Theme.contentRadius, cornerHeight: Theme.contentRadius, transform: nil))
                context.clip()
                context.draw(image, in: rect)
                context.restoreGState()
                // Overlays (prompts, glow, find bar) sit above the web content.
                context.saveGState()
                context.translateBy(x: card.minX, y: bounds.height - card.minY)
                context.scaleBy(x: 1, y: -1)
                for overlay in controller.root.content.subviews.first?.subviews ?? [] where !(overlay is WinkWebView) && !overlay.isHidden {
                    context.saveGState()
                    context.translateBy(x: overlay.frame.minX, y: overlay.frame.minY)
                    if let drawing = overlay as? SnapshotDrawing {
                        drawing.drawSnapshot(in: context)
                    } else {
                        overlay.layer?.render(in: context)
                    }
                    context.restoreGState()
                }
                context.restoreGState()
            }
            if let image = context.makeImage(),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appendingPathComponent("window-\(index).png"))
                index += 1
            }
        }
        // Other visible windows (command bar, settings): render their layers.
        let browserWindows = Set((AppDelegate.shared?.windows ?? []).compactMap { $0.window?.windowNumber })
        for window in NSApp.windows where window.isVisible && !browserWindows.contains(window.windowNumber) {
            guard let view = window.contentView, let layer = view.layer else { continue }
            view.layoutSubtreeIfNeeded()
            view.display()  // paint layer-backed AppKit controls even while the display sleeps
            let size = view.bounds.size
            guard size.width > 1, let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                                          bitsPerComponent: 8, bytesPerRow: 0,
                                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { continue }
            context.scaleBy(x: 2, y: 2)
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            }
            context.fill(CGRect(origin: .zero, size: size))
            if !view.isFlipped {
                layer.render(in: context)
            } else {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                layer.render(in: context)
            }
            // Prefer AppKit's own drawing path for AppKit windows; SwiftUI
            // content only renders through its layers.
            let isSwiftUI = String(describing: type(of: view)).hasPrefix("NSHostingView")
            if !isSwiftUI, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: directory.appendingPathComponent("window-\(index).png"))
                    index += 1
                    continue
                }
            }
            if let image = context.makeImage(),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appendingPathComponent("window-\(index).png"))
                index += 1
            }
        }
        try? "\(index)".write(to: directory.appendingPathComponent("snapshot-done"), atomically: true, encoding: .utf8)
    }

    private func capture() {
        guard let directory else { return }
        var index = 0
        for window in NSApp.windows where window.isVisible {
            let id = UInt32(window.windowNumber)
            // .optionIncludingWindow = 1 << 3, .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
            guard let image = createImage?(.null, 1 << 3, id, (1 << 0) | (1 << 3))?.takeRetainedValue() else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appendingPathComponent("window-\(index).png"))
                index += 1
            }
        }
        try? "\(index)".write(to: directory.appendingPathComponent("snapshot-done"), atomically: true, encoding: .utf8)
    }

    private func runCommands() {
        guard let directory,
              let text = try? String(contentsOf: directory.appendingPathComponent("commands.txt"), encoding: .utf8) else { return }
        var delay = 0.0
        for line in text.split(separator: "\n").map(String.init) where !line.isEmpty {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let command = parts[0]
            let argument = parts.count > 1 ? parts[1] : ""
            if command == "wait" { delay += Double(argument) ?? 1; continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.execute(command, argument)
            }
        }
    }

    private func execute(_ command: String, _ argument: String) {
        guard let app = AppDelegate.shared else { return }
        let window = app.activeWindow
        switch command {
        case "open": window?.newTab(url: argument, activate: true)
        case "navigate": window?.open(argument, inNewTab: false)
        case "commandbar": if let window { CommandBarController.shared.show(for: window, mode: .newTab) }
        case "type":
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                editor.insertText(argument, replacementRange: editor.selectedRange())
            }
        case "hide-commandbar": CommandBarController.shared.hide()
        case "query": CommandBarController.shared.debugSetQuery(argument)
        case "sidebar": window?.toggleSidebar()
        case "agent": window?.toggleAgentPanel()
        case "find": window?.showFindBar(); window?.state.findQuery = argument
        case "select": window?.selectTab(atSidebarIndex: Int(argument) ?? 0)
        case "close": window?.closeActiveTab()
        case "ask": window?.showAgentPanel(); AgentPanelModel.shared.send(argument)
        case "settings":
            if !argument.isEmpty { SettingsNavigation.shared.tab = argument }
            app.showSettings(nil)
        case "private":
            let window = app.makeWindow(isPrivate: true)
            window.newTab(url: argument, activate: true)
        case "stop-agents": AgentHub.shared.stopAll(reason: "Stopped by you")
        case "pause-agent": if let tab = window?.state.activeTab { AgentHub.shared.togglePause(for: tab) }
        case "limit": WinkSettings.shared.agentHourlyLimit = Int(argument) ?? 30
        case "confirm-mode": WinkSettings.shared.agentConfirmMode = AgentConfirmMode(rawValue: argument) ?? .oncePerSite
        case "expand-log": window?.state.agentLogExpanded.toggle()
        case "minimize-pill": WinkSettings.shared.agentPillMinimized.toggle()
        case "welcome":
            WelcomeModel.shared.step = Int(argument) ?? 0
            window?.state.welcomeVisible = true
        case "welcome-off": window?.state.welcomeVisible = false
        case "winky-bar": window?.toggleWinkyBar()
        case "winky-demo":
            // A finished exchange for visual checks (no model call).
            let model = AgentPanelModel.shared
            model.items.append(TranscriptItem(kind: .user, text: "What does this page offer, and is there a download?"))
            let read = TranscriptItem(kind: .tool, text: "", title: "mcp__wink__read_page"); read.status = .done
            let find = TranscriptItem(kind: .tool, text: "“Download”", title: "mcp__wink__find"); find.status = .done
            model.items.append(read); model.items.append(find)
            model.items.append(TranscriptItem(kind: .assistant, text: "It's the **Practice network** page: eight founders in Luxembourg, each with a **Connect** button.\n\n- No download on this page.\n- Five people are already *Pending*."))
            model.answerHidden = false
        case "winky-running": AgentPanelModel.shared.isRunning.toggle()
        case "import-window": AppDelegate.shared?.showImport(nil)
        case "update-check": UpdateCenter.shared.checkInBackground()
        case "update-state":
            try? "updates: \(UpdateCenter.shared.debugSummary) version=\(UpdateCenter.appVersion)"
                .write(to: directory!.appendingPathComponent("update.txt"), atomically: true, encoding: .utf8)
        case "escape":
            // A real Esc key press, through the app's event dispatch.
            if let nsWindow = window?.window,
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: nsWindow.windowNumber,
                                            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                            isARepeat: false, keyCode: 53) {
                NSApp.postEvent(event, atStart: false)
            }
        case "import-window-start": ImportWindow.startForTesting()
        case "import-preview":
            // Counts only, nothing decrypted: argument picks the source ("chrome"), default the first.
            let source = BrowserImport.available.first { argument.isEmpty || $0.id == argument }
            let days = WinkSettings.shared.historyRetentionDays
            Task.detached { [directory] in
                var lines = ["source=\(source?.id ?? "none")"]
                for profile in source.map(BrowserImport.profiles(of:)) ?? [] {
                    let preview = BrowserImport.preview(profile, days: days)
                    lines.append("\(profile.id): history=\(preview.history) bookmarks=\(preview.bookmarks) loginSites=\(preview.loginSites)")
                }
                try? lines.joined(separator: "\n").write(to: directory!.appendingPathComponent("import.txt"), atomically: true, encoding: .utf8)
            }
        case "import":
            // Imports from the first source (the WINK_IMPORT_TEST_ROOT fixture in tests): "logins,history,bookmarks".
            guard let source = BrowserImport.available.first, let profile = BrowserImport.profiles(of: source).first else { break }
            var what: BrowserImport.What = []
            if argument.contains("logins") { what.insert(.logins) }
            if argument.contains("history") { what.insert(.history) }
            if argument.contains("bookmarks") { what.insert(.bookmarks) }
            Task { @MainActor [directory] in
                let report = await BrowserImport.run(what.isEmpty ? .all : what, from: source, profile: profile) { _ in }
                WinkProfile.default.cookieDomains { domains in
                    let lines = ["source=\(source.id) profile=\(profile.id)",
                                 "cookies=\(report.cookies) sites=\(report.sites) trackers=\(report.trackers) history=\(report.history) bookmarks=\(report.bookmarks)",
                                 "problems=\(report.problems)",
                                 "cookie domains: \(domains.sorted().joined(separator: ", "))"]
                    try? lines.joined(separator: "\n").write(to: directory!.appendingPathComponent("import.txt"), atomically: true, encoding: .utf8)
                }
            }
        case "profile-name": Profile.shared.name = argument
        case "takeover":
            // A synthetic click in the middle of the page, as if the user grabbed the mouse.
            if let nsWindow = window?.window, let content = window?.root.content {
                let point = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: nsWindow.windowNumber, context: nil, eventNumber: 0,
                                                      clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
        case "sleep-now":
            for controller in app.windows {
                for tab in controller.state.tabs where tab.id != controller.state.activeTabID { tab.sleep() }
            }
        case "accept": app.windows.first { !$0.state.prompts.isEmpty }?.state.prompts.first?.buttons.last?.action()
        case "deny": app.windows.first { !$0.state.prompts.isEmpty }?.state.prompts.first?.buttons.first?.action()
        case "snapshot": snapshot()
        case "state":
            var lines: [String] = []
            for window in NSApp.windows {
                lines.append("window \(window.windowNumber) visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(NSStringFromRect(window.frame)) title=\(window.title) class=\(type(of: window))")
            }
            for controller in app.windows {
                let s = controller.state
                lines.append("browser window: tabs=\(s.tabs.count) active=\(s.activeTab?.displayTitle ?? "-") sidebar=\(s.sidebarVisible) fullscreen=\(s.contentFullscreen) prompts=\(s.prompts.map(\.title))")
                for tab in s.tabs {
                    lines.append("  tab \(AgentHub.shortID(tab)) asleep=\(tab.isAsleep) loading=\(tab.isLoading) owner=\(tab.agentOwnerName ?? "-") view=\(tab.webView.map { "\(NSStringFromRect($0.frame)) hidden=\($0.isHidden) super=\($0.superview != nil)" } ?? "nil") \(tab.url)")
                }
                lines.append("  root=\(NSStringFromRect(controller.root.frame)) content=\(NSStringFromRect(controller.root.content.frame))")
            }
            lines.append("blocker rules=\(WinkContentBlocker.ruleCount) cookie_controls_mode=\(WinkProfile.default.preferenceValue(forName: "profile.cookie_controls_mode") ?? "nil") webrtc=\(WinkProfile.default.preferenceValue(forName: "webrtc.ip_handling_policy") ?? "nil")")
            try? lines.joined(separator: "\n").write(to: directory!.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
        case "quit": NSApp.terminate(nil)
        default: NSLog("[wink] unknown debug command %@", command)
        }
    }
}
