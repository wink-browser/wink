import AppKit
import Observation
import SwiftUI

/// File › Import from Another Browser…: brings logins, history and bookmarks
/// over from Chrome, Arc, Brave, Edge or Vivaldi on this Mac.
@MainActor
enum ImportWindow {
    private static var window: NSWindow?
    private static var model: ImportModel?

    static func show() {
        if model == nil || model?.isFinished == true {
            let fresh = ImportModel()
            model = fresh
            if window == nil {
                let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
                                       styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                created.title = "Import"
                created.titlebarAppearsTransparent = true
                created.isReleasedWhenClosed = false
                if DebugDriver.isHeadless {  // a hidden test instance never shows windows
                    created.alphaValue = 0
                    created.ignoresMouseEvents = true
                }
                window = created
            }
            window?.contentView = NSHostingView(rootView: ImportView(model: fresh) { window?.close() })
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        AppDelegate.activate()
    }

    /// Debug driver: presses Import in the open window.
    static func startForTesting() { model?.start() }
}

@MainActor
@Observable
final class ImportModel {
    enum Phase: Equatable {
        case choosing
        case running(String)
        case done
    }

    let sources = BrowserImport.available
    var sourceID: String {
        didSet { loadProfiles() }
    }
    private(set) var profiles: [BrowserImport.Profile] = []
    var profileID = "" {
        didSet { refreshPreview() }
    }
    private(set) var preview: BrowserImport.Preview?
    var logins = true
    var history = true
    var bookmarks = true
    private(set) var phase: Phase = .choosing
    private(set) var report = BrowserImport.Report()

    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init() {
        sourceID = sources.first?.id ?? ""
        loadProfiles()
    }

    var source: BrowserImport.Source? { sources.first { $0.id == sourceID } }
    var profile: BrowserImport.Profile? { profiles.first { $0.id == profileID } }
    var isFinished: Bool { phase == .done }
    var canImport: Bool { profile != nil && (logins || history || bookmarks) && phase == .choosing }

    private func loadProfiles() {
        profiles = source.map(BrowserImport.profiles(of:)) ?? []
        profileID = profiles.first?.id ?? ""
    }

    private func refreshPreview() {
        previewTask?.cancel()
        preview = nil
        guard let profile else { return }
        let days = WinkSettings.shared.historyRetentionDays
        previewTask = Task {
            let counted = await Task.detached { BrowserImport.preview(profile, days: days) }.value
            if !Task.isCancelled { preview = counted }
        }
    }

    func start() {
        guard canImport, let source, let profile else { return }
        var what: BrowserImport.What = []
        if logins { what.insert(.logins) }
        if history { what.insert(.history) }
        if bookmarks { what.insert(.bookmarks) }
        phase = .running("Starting…")
        Task {
            report = await BrowserImport.run(what, from: source, profile: profile) { [weak self] step in
                self?.phase = .running(step)
            }
            phase = .done
        }
    }
}

struct ImportView: View {
    @Bindable var model: ImportModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 22)
            if model.sources.isEmpty {
                Text("There's no Chrome, Arc, Brave, Edge or Vivaldi on this Mac to import from.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack { Spacer(); Button("Close", action: close).keyboardShortcut(.defaultAction) }
            } else if model.phase == .done {
                results
                Spacer()
                HStack { Spacer(); primary("Done", action: close) }
            } else {
                choices
                Spacer(minLength: 16)
                footer
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: 500, height: 420)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            sourceIcon
            VStack(alignment: .leading, spacing: 3) {
                Text("Bring your things over")
                    .font(.system(size: 20, weight: .semibold))
                Text("Read from this Mac. Nothing leaves it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let id = model.source?.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 44, height: 44)
        } else {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 24, weight: .light))
                .frame(width: 44, height: 44)
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.sources.count > 1 || model.profiles.count > 1 {
                HStack(spacing: 12) {
                    if model.sources.count > 1 {
                        Picker("From", selection: $model.sourceID) {
                            ForEach(model.sources) { Text($0.name).tag($0.id) }
                        }
                        .fixedSize()
                    }
                    if model.profiles.count > 1 {
                        Picker("Profile", selection: $model.profileID) {
                            ForEach(model.profiles) { Text($0.name).tag($0.id) }
                        }
                        .fixedSize()
                    }
                }
                .font(.system(size: 13))
                .disabled(model.phase != .choosing)
            }
            VStack(alignment: .leading, spacing: 14) {
                option($model.logins, "Logins", count: model.preview.map { counted($0.loginSites, "site", "sites") },
                       detail: "Stay signed in to your sites. macOS will ask to let Wink use “\(model.source?.keychainService ?? "Safe Storage")”: enter your Mac password and choose Allow.")
                option($model.history, "History", count: model.preview.map { counted($0.history, "page", "pages") },
                       detail: "The last \(WinkSettings.shared.historyRetentionDays) days, so ⌘T knows your sites.")
                option($model.bookmarks, "Bookmarks", count: model.preview.map { $0.bookmarks.formatted() },
                       detail: "Find them from ⌘T.")
            }
            .disabled(model.phase != .choosing)
        }
    }

    private func option(_ isOn: Binding<Bool>, _ title: String, count: String?, detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    if let count {
                        Text(count).font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        }
        .toggleStyle(.checkbox)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if case .running(let step) = model.phase {
                ProgressView().controlSize(.small)
                Text(step).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
            } else {
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                primary("Import", action: model.start)
                    .disabled(!model.canImport)
            }
        }
        .font(.system(size: 13))
    }

    private var results: some View {
        let report = model.report
        return VStack(alignment: .leading, spacing: 12) {
            if model.logins, report.cookies > 0 {
                result("Signed in to \(counted(report.sites, "site", "sites"))",
                       report.trackers > 0 ? "\(counted(report.trackers, "tracker cookie", "tracker cookies")) stayed behind." : nil)
            }
            if model.history, report.history > 0 { result("\(counted(report.history, "page", "pages")) of history", nil) }
            if model.bookmarks, report.bookmarks > 0 { result(counted(report.bookmarks, "bookmark", "bookmarks"), "Find them from ⌘T.") }
            ForEach(report.problems, id: \.self) { problem in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color(nsColor: .systemOrange))
                    Text(problem).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if report.cookies == 0 && report.history == 0 && report.bookmarks == 0 && report.problems.isEmpty {
                Text("There was nothing new to bring over.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private func result(_ title: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: Theme.cobaltNS))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
    }

    private func counted(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count.formatted()) \(count == 1 ? one : many)"
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(Color(nsColor: Theme.cobaltNS))
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}
