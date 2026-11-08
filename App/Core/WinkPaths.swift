import Foundation

/// File-system layout. Everything Wink stores lives under
/// ~/Library/Application Support/Wink and is readable by the current user only.
///
/// A build with another bundle id (a side-by-side dev build) keeps its data
/// in its own folder; `WINK_HOME` overrides the location for test runs.
final class WinkPaths: @unchecked Sendable {
    static let shared = WinkPaths()

    let appSupport: URL
    /// Chromium root cache path; every profile lives below it.
    let userData: URL
    let defaultProfile: URL
    /// Session, history, settings that Wink (not Chromium) owns.
    let state: URL
    /// Private runtime directory for the agent (MCP) socket.
    let runDirectory: URL
    let mcpSocket: URL
    let logs: URL

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "app.wink.browser"
        let folder = bundleID == "app.wink.browser" ? "Wink" : bundleID
        if let home = ProcessInfo.processInfo.environment["WINK_HOME"], !home.isEmpty {
            appSupport = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            appSupport = base.appendingPathComponent(folder, isDirectory: true)
        }
        userData = appSupport.appendingPathComponent("Profiles", isDirectory: true)
        defaultProfile = userData.appendingPathComponent("Default", isDirectory: true)
        state = appSupport.appendingPathComponent("State", isDirectory: true)
        runDirectory = appSupport.appendingPathComponent("run", isDirectory: true)
        mcpSocket = runDirectory.appendingPathComponent("mcp.sock")
        logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(folder)", isDirectory: true)
    }

    func prepare() {
        let fm = FileManager.default
        for url in [appSupport, userData, defaultProfile, state, runDirectory, logs] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        // Tighten permissions even if the directories pre-existed.
        for url in [appSupport, runDirectory] {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    var bundledBlocklist: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("blocklist/domains.txt")
    }

    /// The agent socket's path. `WINK_MCP_SOCKET` overrides it for test runs
    /// (kept verbatim: a relative path dodges the 104-byte sun_path limit).
    var mcpSocketPath: String {
        ProcessInfo.processInfo.environment["WINK_MCP_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? mcpSocket.path
    }

    var mcpBridgeExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/wink-mcp")
    }
}
