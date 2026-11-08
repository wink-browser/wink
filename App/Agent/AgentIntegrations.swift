import AppKit

/// The user's login-shell environment. Apps launched from Finder get a
/// minimal PATH; CLI agents like Claude Code need the real one.
enum ShellEnvironment {
    nonisolated(unsafe) private static var cached: [String: String]?

    static func environment() -> [String: String] {
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
}

@MainActor
enum AgentIntegrations {
    static var bridgePath: String { WinkPaths.shared.mcpBridgeExecutable.path }

    static var claudeCodeAddCommand: String {
        "claude mcp add --scope user wink -- \"\(bridgePath)\""
    }

    /// Registers Wink as an MCP server in Claude Code (user scope), after
    /// asking the user — it edits Claude Code's configuration.
    static func connectClaudeCode() {
        guard let claude = ClaudeCodeLocator.find() else {
            let alert = NSAlert()
            alert.messageText = "Claude Code isn't installed"
            alert.informativeText = "Install Claude Code, then run:\n\n\(claudeCodeAddCommand)"
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn { copy(claudeCodeAddCommand) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Connect Claude Code to Wink?"
        alert.informativeText = """
        Wink will add itself to Claude Code's MCP servers for your user account by running:

        \(claudeCodeAddCommand)

        Claude Code can then ask to use your browser from any project. Wink still asks you before an agent browses, and agents only see tabs they open or you share.
        """
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn: copy(claudeCodeAddCommand); return
        default: return
        }
        _ = run(claude, ["mcp", "remove", "--scope", "user", "wink"])
        let (status, output) = run(claude, ["mcp", "add", "--scope", "user", "wink", "--", bridgePath])
        let result = NSAlert()
        if status == 0 {
            result.messageText = "Claude Code is connected"
            result.informativeText = "Start a new Claude Code session and ask it to use Wink, e.g. “open localhost:3000 in Wink and check the console for errors”."
        } else {
            result.messageText = "Couldn't connect Claude Code"
            result.informativeText = output.isEmpty ? "claude exited with status \(status)." : output
            result.alertStyle = .warning
        }
        result.runModal()
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ShellEnvironment.environment()
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
