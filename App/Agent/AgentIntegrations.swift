import AppKit
import Observation

/// The user's login-shell environment. Apps launched from Finder get a
/// minimal PATH; CLI agents like Claude Code need the real one.
enum ShellEnvironment {
    nonisolated(unsafe) private static var cached: [String: String]?
    private static let lock = NSLock()

    static func environment() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '%s' \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               path.contains("/") {
                env["PATH"] = path
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        var parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in extras where !parts.contains(extra) { parts.append(extra) }
        env["PATH"] = parts.joined(separator: ":")
        cached = env
        return env
    }

    /// Runs a command with the login environment; returns its status and output.
    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

/// Wink's browser tools in Claude Code.
///
/// The installed Wink adds itself to Claude Code's MCP servers (user scope)
/// when it launches, so every Claude Code session can browse with it: no
/// setup step. `wink-mcp` opens Wink only when an agent actually uses a tool,
/// and Wink still asks before a new agent may browse.
///
/// Wink never re-adds itself after the user removes it (here or with
/// `claude mcp remove`), and it repairs a registration that points at a copy
/// of Wink that has moved or been deleted.
@MainActor
@Observable
final class ClaudeCodeLink {
    static let shared = ClaudeCodeLink()

    enum Status: Equatable {
        case unknown
        /// No Claude Code on this Mac.
        case notInstalled
        case connected
        case notConnected
        /// Claude Code uses another copy of Wink (the path of its bridge).
        case otherCopy(String)
    }

    private(set) var status: Status = .unknown
    private(set) var busy = false

    @ObservationIgnored private let defaults = UserDefaults.standard
    /// "added" once Wink is in Claude Code; "declined" after the user removed it.
    private static let stateKey = "claudeCode.link"

    var bridgePath: String { WinkPaths.shared.mcpBridgeExecutable.path }
    var addCommand: String { "claude mcp add --scope user wink -- \"\(bridgePath)\"" }

    /// The installed release links itself: Developer ID–signed, in an
    /// Applications folder (not on the disk image, not a dev build). Tests opt
    /// in with WINK_CLAUDE_LINK_TEST=1 and a throwaway CLAUDE_CONFIG_DIR.
    static var linksAutomatically: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["WINK_CLAUDE_LINK_TEST"] == "1" { return !(env["CLAUDE_CONFIG_DIR"] ?? "").isEmpty }
        guard Bundle.main.bundleIdentifier == "app.wink.browser", !DebugDriver.isHeadless,
              UpdateCenter.isDeveloperIDSigned else { return false }
        let folder = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder == "/Applications" || folder == "\(home)/Applications"
    }

    // MARK: Launch

    /// Called at launch: adds Wink to Claude Code unless it's there, or the
    /// user took it out.
    func linkAtLaunch() {
        guard Self.linksAutomatically, WinkSettings.shared.mcpServerEnabled else {
            refresh()
            return
        }
        let state = defaults.string(forKey: Self.stateKey)
        let claude = ClaudeCodeLocator.find()
        let bridge = bridgePath
        Task.detached(priority: .utility) {
            var outcome: String? = state
            switch Self.registeredCommand() {
            case bridge?:
                outcome = "added"
            case let command?:
                // Re-point only a stale registration of Wink's own bridge;
                // another live copy, or someone else's "wink", stays as it is.
                let staleWink = command.hasSuffix("/Contents/MacOS/wink-mcp") && !FileManager.default.fileExists(atPath: command)
                if staleWink, state != "declined", let claude, Self.add(claude, bridge).status == 0 { outcome = "added" }
            case nil:
                if state == "added" {
                    outcome = "declined"  // the user removed it from Claude Code
                } else if state != "declined", let claude, Self.add(claude, bridge).status == 0 {
                    outcome = "added"
                    NSLog("[wink] added Wink to Claude Code's MCP servers")
                }
            }
            let result = outcome
            await MainActor.run {
                if let result { self.defaults.set(result, forKey: Self.stateKey) }
                self.refresh()
            }
        }
    }

    // MARK: Settings

    func refresh() {
        let registered = Self.registeredCommand()
        let installed = ClaudeCodeLocator.find() != nil || registered != nil
        switch registered {
        case bridgePath?: status = .connected
        case let command? where command.hasSuffix("/Contents/MacOS/wink-mcp")
            && FileManager.default.fileExists(atPath: command): status = .otherCopy(command)
        default: status = installed ? .notConnected : .notInstalled
        }
    }

    /// Adds this Wink to Claude Code (Settings, the Welcome window, the menu).
    func connect(announce: Bool = false) {
        guard let claude = ClaudeCodeLocator.find() else {
            let alert = NSAlert()
            alert.messageText = "Claude Code isn't installed"
            alert.informativeText = "Install Claude Code and Wink connects to it by itself. Or, once it's installed, run:\n\n\(addCommand)"
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn { Self.copy(addCommand) }
            return
        }
        busy = true
        let bridge = bridgePath
        Task.detached(priority: .userInitiated) {
            let result = Self.add(claude, bridge)
            await MainActor.run {
                self.busy = false
                if result.status == 0 { self.defaults.set("added", forKey: Self.stateKey) }
                self.refresh()
                if result.status != 0 {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't connect Claude Code"
                    alert.informativeText = result.output.isEmpty ? "claude exited with status \(result.status)." : result.output
                    alert.alertStyle = .warning
                    alert.runModal()
                } else if announce {
                    let alert = NSAlert()
                    alert.messageText = "Claude Code can use Wink"
                    alert.informativeText = "Start a new Claude Code session and ask it to use Wink, e.g. “open localhost:3000 in Wink and check the console for errors”."
                    alert.runModal()
                }
            }
        }
    }

    /// Takes Wink out of Claude Code, for good (until the user adds it back).
    func disconnect() {
        defaults.set("declined", forKey: Self.stateKey)
        guard let claude = ClaudeCodeLocator.find() else {
            refresh()
            return
        }
        busy = true
        Task.detached(priority: .userInitiated) {
            _ = ShellEnvironment.run(claude, ["mcp", "remove", "--scope", "user", "wink"])
            await MainActor.run {
                self.busy = false
                self.refresh()
            }
        }
    }

    func copyAddCommand() { Self.copy(addCommand) }

    // MARK: Claude Code's configuration

    /// The command of Claude Code's user-scope "wink" server, if there is one,
    /// read from its config file (read only: changes go through `claude`).
    nonisolated static func registeredCommand() -> String? {
        let env = ProcessInfo.processInfo.environment
        let folder = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(".claude.json")),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = config["mcpServers"] as? [String: Any],
              let wink = servers["wink"] as? [String: Any] else { return nil }
        return wink["command"] as? String ?? ""
    }

    nonisolated private static func add(_ claude: String, _ bridge: String) -> (status: Int32, output: String) {
        _ = ShellEnvironment.run(claude, ["mcp", "remove", "--scope", "user", "wink"])
        return ShellEnvironment.run(claude, ["mcp", "add", "--scope", "user", "wink", "--", bridge])
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
enum AgentIntegrations {
    /// Wink › Connect Claude Code…
    static func connectClaudeCode() {
        ClaudeCodeLink.shared.connect(announce: true)
    }
}
