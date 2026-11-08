import AppKit
import Observation
import WinkEngine

// MARK: - Favicons

/// Memory + disk favicon cache keyed by host. Never populated from private tabs.
final class FaviconCache: @unchecked Sendable {
    static let shared = FaviconCache()

    private let memory = NSCache<NSString, NSImage>()
    private let directory = WinkPaths.shared.state.appendingPathComponent("Favicons", isDirectory: true)
    private let ioQueue = DispatchQueue(label: "app.wink.favicons", qos: .utility)

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 512
    }

    private func file(for host: String) -> URL {
        let safe = host.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent(safe + ".png")
    }

    func image(for host: String) -> NSImage? {
        guard !host.isEmpty else { return nil }
        if let image = memory.object(forKey: host as NSString) { return image }
        guard let image = NSImage(contentsOf: file(for: host)) else { return nil }
        memory.setObject(image, forKey: host as NSString)
        return image
    }

    func store(_ image: NSImage, for host: String) {
        guard !host.isEmpty else { return }
        memory.setObject(image, forKey: host as NSString)
        let target = file(for: host)
        ioQueue.async {
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: target, options: .atomic)
        }
    }

    func clear() {
        memory.removeAllObjects()
        ioQueue.async { [directory] in
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Downloads

@MainActor
@Observable
final class DownloadItem: Identifiable {
    let id: UInt32
    var fileName: String
    var path: String
    var received: Int64 = 0
    var total: Int64 = 0
    var speed: Int64 = 0
    var isComplete = false
    var isFailed = false
    var isCanceled = false
    let started = Date()

    init(id: UInt32, fileName: String, path: String) {
        self.id = id
        self.fileName = fileName
        self.path = path
    }

    var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    var isActive: Bool { !isComplete && !isFailed && !isCanceled }
}

@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    var items: [DownloadItem] = []
    var hasActive: Bool { items.contains { $0.isActive } }

    func destination(for info: WinkDownloadInfo) -> String? {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var name = info.suggestedFileName.isEmpty ? "download" : info.suggestedFileName
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        var target = downloads.appendingPathComponent(name)
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            counter += 1
            target = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
        }
        items.insert(DownloadItem(id: info.identifier, fileName: target.lastPathComponent, path: target.path), at: 0)
        return target.path
    }

    func update(_ info: WinkDownloadInfo) {
        guard let item = items.first(where: { $0.id == info.identifier }) else { return }
        let wasComplete = item.isComplete
        item.received = info.receivedBytes
        item.total = info.totalBytes
        item.speed = info.currentSpeed
        item.isComplete = info.complete
        item.isCanceled = info.canceled
        item.isFailed = info.interrupted && !info.complete
        if !info.fullPath.isEmpty { item.path = info.fullPath }
        if item.isComplete && !wasComplete {
            // Bounce the Dock's Downloads stack, like Safari does.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"),
                                                         object: item.path)
        }
    }

    func reveal(_ item: DownloadItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func open(_ item: DownloadItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
    }

    func clearFinished() {
        items.removeAll { !$0.isActive }
    }
}

// MARK: - Privacy stats

@MainActor
@Observable
final class PrivacyStats {
    static let shared = PrivacyStats()

    var blockedThisSession = 0
    private(set) var topHosts: [String: Int] = [:]

    func recordBlocked(host: String) {
        blockedThisSession += 1
        guard !host.isEmpty else { return }
        topHosts[Site.registrableDomain(host), default: 0] += 1
    }

    var ranked: [(host: String, count: Int)] {
        topHosts.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) }
    }
}

// MARK: - Session persistence

struct SessionSnapshot: Codable {
    struct TabState: Codable {
        var id: UUID
        var url: String
        var title: String
        var pinned: Bool
    }

    struct WindowState: Codable {
        var frame: String?
        var sidebarVisible: Bool
        var activeTabID: UUID?
        var tabs: [TabState]
    }

    var windows: [WindowState]
}

@MainActor
final class SessionStore {
    static let shared = SessionStore()

    private let file = WinkPaths.shared.state.appendingPathComponent("session.json")
    private var pendingSave: DispatchWorkItem?
    var snapshotProvider: (() -> SessionSnapshot)?

    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let snapshot = snapshotProvider?(),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// MARK: - Tab sleeping (memory)

/// Discards background tabs that have been idle for a while. A sleeping tab
/// keeps its place, title and favicon and reloads instantly when selected.
@MainActor
final class TabSleeper {
    static let shared = TabSleeper()

    private var timer: Timer?
    var windowsProvider: (() -> [BrowserWindowState])?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        timer?.tolerance = 15
    }

    func sweep() {
        let minutes = WinkSettings.shared.tabSleepMinutes
        guard minutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        for window in windowsProvider?() ?? [] {
            for tab in window.tabs where tab.id != window.activeTabID && !tab.isAsleep {
                guard tab.lastActive < cutoff, !tab.isCapturingMedia, !tab.agentActive,
                      tab.agentOwnerID == nil, !tab.isLoading else { continue }
                Task { @MainActor in
                    // Keep tabs that are audibly playing media awake.
                    let playing = try? await tab.cdp.evaluateAgent("__wink.mediaPlaying()")
                    if (playing as? Bool) != true { tab.sleep() }
                }
            }
        }
    }
}
