import AppKit
import WinkEngine

@MainActor
enum PrivacyActions {
    /// Clears cookies, cache, auth, history and favicons for the default profile.
    static func clearBrowsingData() {
        let alert = NSAlert()
        alert.messageText = "Clear browsing data?"
        alert.informativeText = "Deletes history, cookies, site data, cached files and saved favicons. You will be signed out of websites."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        WinkProfile.default.clearBrowsingData(.all) {}
        HistoryStore.shared.clearAll()
        FaviconCache.shared.clear()
        // Local storage / IndexedDB are wiped per open origin; the rest of the
        // profile's site storage is removed on next launch.
        UserDefaults.standard.set(true, forKey: "wipeSiteStorageOnLaunch")
        for tab in AppDelegate.shared?.allTabs ?? [] where tab.webView != nil {
            Task { _ = try? await tab.cdp.send("Storage.clearDataForOrigin",
                                               ["origin": originOf(tab.url), "storageTypes": "all"]) }
        }
    }

    static func originOf(_ url: String) -> String {
        guard let components = URLComponents(string: url), let scheme = components.scheme, let host = components.host else {
            return url
        }
        return components.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// Runs before the engine starts: completes a pending full wipe.
    static func performPendingWipe(paths: WinkPaths) {
        guard UserDefaults.standard.bool(forKey: "wipeSiteStorageOnLaunch") else { return }
        UserDefaults.standard.removeObject(forKey: "wipeSiteStorageOnLaunch")
        let fm = FileManager.default
        for name in ["Local Storage", "IndexedDB", "Service Worker", "Session Storage", "Shared Storage",
                     "File System", "WebStorage", "blob_storage"] {
            try? fm.removeItem(at: paths.defaultProfile.appendingPathComponent(name))
        }
    }
}
