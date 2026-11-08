import AppKit
import WinkEngine

/// Keeps the engine's network protections in sync with the user's settings.
@MainActor
final class ContentBlockerService {
    static let shared = ContentBlockerService()

    func start() {
        apply()
        if let rules = WinkPaths.shared.bundledBlocklist, FileManager.default.fileExists(atPath: rules.path) {
            WinkContentBlocker.loadRules(fromFile: rules.path) { count in
                NSLog("[wink] content blocker ready: %ld rules", count)
            }
        }
    }

    func apply() {
        let settings = WinkSettings.shared
        WinkContentBlocker.blockingEnabled = settings.blockTrackers
        WinkContentBlocker.httpsUpgradesEnabled = settings.httpsUpgrades
        WinkContentBlocker.globalPrivacyControlEnabled = settings.globalPrivacyControl
        WinkContentBlocker.setAllowlistedSites(settings.shieldsDownSites)
    }

    /// Applies cookie preferences to live profiles after a settings change.
    func applyProfilePreferences(to profiles: [WinkProfile]) {
        for profile in profiles {
            for (name, value) in PrivacyPreferences.chromiumPreferences(for: WinkSettings.shared) {
                var error: NSString?
                _ = profile.setPreference(name, value: value, error: &error)
            }
        }
    }

    func setShields(_ on: Bool, for host: String) {
        let site = Site.registrableDomain(host)
        var sites = WinkSettings.shared.shieldsDownSites
        if on { sites.removeAll { $0 == site } } else if !sites.contains(site) { sites.append(site) }
        WinkSettings.shared.shieldsDownSites = sites
        apply()
    }

    /// Deletes everything Wink knows about a site: cookies, storage, history.
    func forget(site: String, tab: Tab) {
        let alert = NSAlert()
        alert.messageText = "Forget \(site)?"
        alert.informativeText = "Wink will delete this site's cookies, storage, cache and history. You'll be signed out."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        tab.profile.deleteCookies(forDomain: site) { _ in }
        HistoryStore.shared.deleteSite(site)
        Task { @MainActor in
            for origin in ["https://\(site)", "https://www.\(site)", "http://\(site)"] {
                _ = try? await tab.cdp.send("Storage.clearDataForOrigin", ["origin": origin, "storageTypes": "all"])
            }
            tab.reload()
        }
    }

    static func isLocal(_ url: String) -> Bool {
        let host = Site.host(of: url)
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host.hasSuffix(".local")
            || host.hasSuffix(".test") || !host.contains(".")
    }
}
