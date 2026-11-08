import AppKit
import Observation
import Security

/// Once a day Wink asks wink.minnebo.ai for the newest version, so it can
/// offer updates. Unless the user switches "Share anonymous usage counts"
/// off, the same request carries a few anonymous flags (first check today /
/// this week / this month / ever, the install week, app and macOS version)
/// that let the founder count active installs. No identifier, browsing data
/// or profile detail is ever sent, and nothing is sent from dev builds.
@MainActor
@Observable
final class UpdateCenter {
    static let shared = UpdateCenter()

    struct Release: Decodable, Equatable {
        let version: String
        let url: String
        let notes: String?
    }

    /// A newer release than the running one, once a check found it.
    private(set) var available: Release?
    private(set) var lastChecked: Date?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let defaults = UserDefaults.standard

    static let endpoint = URL(string: "https://wink.minnebo.ai/api/ping")!

    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

    /// Only Developer ID–signed builds check in; ad-hoc dev builds stay silent
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

    func start() {
        guard Self.isReleaseBuild, !DebugDriver.isHeadless || ProcessInfo.processInfo.environment["WINK_UPDATE_TEST"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer?.tolerance = 300
    }

    /// At most one request per UTC day, unless `force` (the menu command).
    func checkIfDue(force: Bool = false, completion: ((Release?) -> Void)? = nil) {
        guard force || WinkSettings.shared.checkForUpdates else { completion?(nil); return }
        let now = Date()
        let day = Self.utcDay(now)
        if !force && defaults.string(forKey: "updates.lastDay") == day { completion?(available); return }

        var items = [URLQueryItem(name: "v", value: Self.appVersion),
                     URLQueryItem(name: "os", value: Self.macOSVersion)]
        let counted = WinkSettings.shared.shareUsageCounts && !force
        let week = Self.isoWeek(now)
        let month = String(day.prefix(7))
        let installWeek = defaults.string(forKey: "updates.installWeek") ?? week
        if counted {
            items += [
                URLQueryItem(name: "c", value: "1"),
                URLQueryItem(name: "d", value: "1"),
                URLQueryItem(name: "w", value: defaults.string(forKey: "updates.countedWeek") == week ? "0" : "1"),
                URLQueryItem(name: "m", value: defaults.string(forKey: "updates.countedMonth") == month ? "0" : "1"),
                URLQueryItem(name: "f", value: defaults.bool(forKey: "updates.countedEver") ? "0" : "1"),
                URLQueryItem(name: "woi", value: installWeek),
            ]
        } else {
            items.append(URLQueryItem(name: "c", value: "0"))
        }
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Wink/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral)  // no cookies, no cache
        session.dataTask(with: request) { data, response, _ in
            let release = (response as? HTTPURLResponse)?.statusCode == 200
                ? data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) } : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let release else { completion?(nil); return }
                    self.lastChecked = Date()
                    if !force { self.defaults.set(day, forKey: "updates.lastDay") }  // a manual check never uses up the daily one
                    if self.defaults.string(forKey: "updates.installWeek") == nil {
                        self.defaults.set(installWeek, forKey: "updates.installWeek")
                    }
                    if counted {
                        self.defaults.set(week, forKey: "updates.countedWeek")
                        self.defaults.set(month, forKey: "updates.countedMonth")
                        self.defaults.set(true, forKey: "updates.countedEver")
                    }
                    self.available = Self.isNewer(release.version, than: Self.appVersion) ? release : nil
                    completion?(release)
                }
            }
        }.resume()
    }

    /// Wink › Check for Updates…
    func checkNow() {
        checkIfDue(force: true) { release in
            let alert = NSAlert()
            if let release, Self.isNewer(release.version, than: Self.appVersion) {
                alert.messageText = "Wink \(release.version) is available"
                alert.informativeText = "You have \(Self.appVersion). Download the new version and drag it to Applications."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { self.download() }
            } else {
                alert.messageText = release == nil ? "Couldn't check for updates" : "Wink is up to date"
                alert.informativeText = release == nil ? "Check your connection and try again." : "You have the newest version, \(Self.appVersion)."
                alert.runModal()
            }
        }
    }

    func download() {
        guard let url = URL(string: available?.url ?? "https://wink.minnebo.ai/download") else { return }
        NSWorkspace.shared.open(url)
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

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
