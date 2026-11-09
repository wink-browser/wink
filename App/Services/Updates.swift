import AppKit
import Observation
import Security
import Sparkle

/// Keeps Wink up to date, with Sparkle. Release builds ask wink.minnebo.ai for
/// the newest version once a day (on the first launch of each UTC day, and
/// daily while open). An update downloads in the background, is verified
/// (Wink's EdDSA signature and Apple's code signature) and installs when Wink
/// quits; the sidebar offers "Restart to update" in the meantime.
///
/// Unless "Share anonymous usage counts" is off, the first check of each UTC
/// day adds a few anonymous flags to that request (first check today / this
/// week / this month / ever, the install week, app and macOS version) so the
/// founder can count active installs. No identifier, browsing data or profile
/// detail is ever sent, and dev builds never check.
@MainActor
@Observable
final class UpdateCenter: NSObject {
    static let shared = UpdateCenter()

    /// A downloaded, verified update waiting to install (the sidebar shows it).
    private(set) var readyVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// What the request in flight counted, recorded once the feed has loaded.
    @ObservationIgnored private var counting: (day: String, week: String, month: String, installWeek: String)?

    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

    /// Only Developer ID–signed builds update; ad-hoc dev builds stay silent
    /// (WINK_UPDATE_TEST=1 overrides for testing).
    static let isReleaseBuild: Bool = {
        if ProcessInfo.processInfo.environment["WINK_UPDATE_TEST"] == "1" { return true }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return false }
        return dictionary[kSecCodeInfoTeamIdentifier as String] is String
    }()

    /// Test hook: the update test serves its own feed (only with the debug driver).
    nonisolated private static let testFeed: String? = {
        let env = ProcessInfo.processInfo.environment
        return env["WINK_DEBUG_DIR"] != nil ? env["WINK_UPDATE_FEED"] : nil
    }()

    var isActive: Bool { controller != nil }

    func start() {
        let testing = ProcessInfo.processInfo.environment["WINK_UPDATE_TEST"] == "1"
        guard Self.isReleaseBuild, !DebugDriver.isHeadless || testing, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        applySettings()
        controller.startUpdater()
        // Sparkle checks every 24 hours; the first launch of a new UTC day
        // checks too, so each day Wink is used is counted once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfNewDay() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfNewDay() }
        }
        timer?.tolerance = 300
    }

    /// Settings › Privacy › Updates.
    func applySettings() {
        guard let updater = controller?.updater else { return }
        let on = WinkSettings.shared.checkForUpdates
        updater.automaticallyChecksForUpdates = on
        updater.automaticallyDownloadsUpdates = on
    }

    /// Wink › Check for Updates…: Sparkle's window, with progress and notes.
    func checkNow() {
        if let controller {
            controller.checkForUpdates(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "This build doesn't update itself"
        alert.informativeText = "Development builds of Wink don't check for updates. The release from wink.minnebo.ai does."
        alert.runModal()
    }

    /// The sidebar's "Restart to update": installs now and reopens Wink.
    func installAndRelaunch() {
        installNow?()
    }

    /// A quiet check, as the schedule makes (also used by the debug driver).
    func checkInBackground() {
        guard let updater = controller?.updater, !updater.sessionInProgress else { return }
        updater.checkForUpdatesInBackground()
    }

    var debugSummary: String {
        "active=\(isActive) ready=\(readyVersion ?? "-") checkedDay=\(defaults.string(forKey: "updates.checkedDay") ?? "-")"
    }

    private func checkIfNewDay() {
        guard WinkSettings.shared.checkForUpdates, defaults.string(forKey: "updates.checkedDay") != Self.utcDay(Date()) else { return }
        checkInBackground()
    }

    /// The query items added to the feed request.
    private func feedQuery() -> [(String, String)] {
        let now = Date()
        let day = Self.utcDay(now), week = Self.isoWeek(now), month = String(day.prefix(7))
        var items = [("v", Self.appVersion), ("os", Self.macOSVersion)]
        // 0.3 and earlier recorded the day of their (counted) daily ping as lastDay.
        let countedDay = defaults.string(forKey: "updates.countedDay") ?? defaults.string(forKey: "updates.lastDay")
        guard WinkSettings.shared.shareUsageCounts, countedDay != day else {
            counting = nil
            return items + [("c", "0")]
        }
        let installWeek = defaults.string(forKey: "updates.installWeek") ?? week
        counting = (day, week, month, installWeek)
        return items + [
            ("c", "1"),
            ("d", "1"),
            ("w", defaults.string(forKey: "updates.countedWeek") == week ? "0" : "1"),
            ("m", defaults.string(forKey: "updates.countedMonth") == month ? "0" : "1"),
            ("f", defaults.bool(forKey: "updates.countedEver") ? "0" : "1"),
            ("woi", installWeek),
        ]
    }

    private func feedLoaded() {
        defaults.set(Self.utcDay(Date()), forKey: "updates.checkedDay")
        guard let counted = counting else { return }
        counting = nil
        defaults.set(counted.day, forKey: "updates.countedDay")
        defaults.set(counted.week, forKey: "updates.countedWeek")
        defaults.set(counted.month, forKey: "updates.countedMonth")
        defaults.set(true, forKey: "updates.countedEver")
        if defaults.string(forKey: "updates.installWeek") == nil {
            defaults.set(counted.installWeek, forKey: "updates.installWeek")
        }
    }

    // MARK: - Helpers

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func isoWeek(_ date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }
}

// Sparkle calls its delegate on the main thread.
extension UpdateCenter: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        Self.testFeed
    }

    nonisolated func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] {
        MainActor.assumeIsolated { feedQuery().map { ["key": $0.0, "value": $0.1] } }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        MainActor.assumeIsolated { feedLoaded() }
    }

    /// A downloaded update waits for quit; the sidebar offers to install it now.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            readyVersion = version
            installNow = immediateInstallHandler
        }
        return true
    }
}
