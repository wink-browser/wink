import CommonCrypto
import CryptoKit
import Foundation
import Security
import SQLite3
import WinkEngine

/// Brings logins (cookies), history and bookmarks over from Chromium-family
/// browsers on this Mac: Chrome, Arc, Brave, Edge, Vivaldi and Chromium.
///
/// Everything stays on the Mac. Wink reads copies of the other browser's
/// files, and decrypts its cookies with that browser's own Keychain key,
/// which macOS asks you about first. Decrypted values only live in memory:
/// they go straight to Chromium, which encrypts them again with Wink's key.
/// Known tracker cookies are left behind.
enum BrowserImport {
    struct Source: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let shortName: String
        let bundleID: String
        let folder: URL
        let keychainService: String
    }

    struct Profile: Identifiable, Hashable, Sendable {
        let id: String  // the folder: "Default", "Profile 1", …
        let name: String
        let folder: URL
    }

    struct What: OptionSet, Sendable {
        let rawValue: Int
        static let logins = What(rawValue: 1 << 0)
        static let history = What(rawValue: 1 << 1)
        static let bookmarks = What(rawValue: 1 << 2)
        static let all: What = [.logins, .history, .bookmarks]
    }

    struct Report: Sendable {
        var cookies = 0
        var sites = 0
        var trackers = 0
        var history = 0
        var bookmarks = 0
        var problems: [String] = []
    }

    enum Failure: Error {
        case denied
        case noKey
        case unreadable(String)
    }

    /// A cookie read from the other browser, before it becomes a WinkCookie.
    struct Cookie: Sendable {
        let name, value, domain, path: String
        let secure, httpOnly: Bool
        let expires, creation, lastAccess: Date?
        let sameSite, priority: Int
    }

    // MARK: - Sources

    private static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")

    static let known: [Source] = [
        Source(id: "chrome", name: "Google Chrome", shortName: "Chrome", bundleID: "com.google.Chrome",
               folder: support.appendingPathComponent("Google/Chrome"), keychainService: "Chrome Safe Storage"),
        Source(id: "arc", name: "Arc", shortName: "Arc", bundleID: "company.thebrowser.Browser",
               folder: support.appendingPathComponent("Arc/User Data"), keychainService: "Arc Safe Storage"),
        Source(id: "brave", name: "Brave", shortName: "Brave", bundleID: "com.brave.Browser",
               folder: support.appendingPathComponent("BraveSoftware/Brave-Browser"), keychainService: "Brave Safe Storage"),
        Source(id: "edge", name: "Microsoft Edge", shortName: "Edge", bundleID: "com.microsoft.edgemac",
               folder: support.appendingPathComponent("Microsoft Edge"), keychainService: "Microsoft Edge Safe Storage"),
        Source(id: "vivaldi", name: "Vivaldi", shortName: "Vivaldi", bundleID: "com.vivaldi.Vivaldi",
               folder: support.appendingPathComponent("Vivaldi"), keychainService: "Vivaldi Safe Storage"),
        Source(id: "chromium", name: "Chromium", shortName: "Chromium", bundleID: "org.chromium.Chromium",
               folder: support.appendingPathComponent("Chromium"), keychainService: "Chromium Safe Storage"),
    ]

    /// Test hook for the debug driver: a fixture profile and its key, no Keychain.
    private static var testSource: Source? {
        let env = ProcessInfo.processInfo.environment
        guard env["WINK_DEBUG_DIR"] != nil, let root = env["WINK_IMPORT_TEST_ROOT"] else { return nil }
        return Source(id: "test", name: "Test Browser", shortName: "Test", bundleID: "",
                      folder: URL(fileURLWithPath: root), keychainService: "Test Safe Storage")
    }

    /// Browsers with data on this Mac, most likely first.
    static var available: [Source] {
        let found = known.filter { FileManager.default.fileExists(atPath: $0.folder.appendingPathComponent("Local State").path) }
        return (testSource.map { [$0] } ?? []) + found
    }

    static func profiles(of source: Source) -> [Profile] {
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: source.folder.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (folder, info) in cache {
                names[folder] = ((info as? [String: Any])?["name"] as? String) ?? folder
            }
        }
        let folders = names.isEmpty ? ["Default"] : Array(names.keys)
        return folders
            .filter { FileManager.default.fileExists(atPath: source.folder.appendingPathComponent($0).path) }
            .sorted { a, b in
                if a == "Default" || b == "Default" { return a == "Default" }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map { folder in
                let name = names[folder].flatMap { $0.isEmpty ? nil : $0 } ?? folder
                return Profile(id: folder, name: name, folder: source.folder.appendingPathComponent(folder))
            }
    }

    // MARK: - Import

    /// Imports what was asked for into Wink's own profile, history and bookmarks.
    @MainActor
    static func run(_ what: What, from source: Source, profile: Profile,
                    progress: @escaping @MainActor (String) -> Void) async -> Report {
        var report = Report()
        let days = WinkSettings.shared.historyRetentionDays

        if what.contains(.bookmarks) {
            progress("Bringing over bookmarks…")
            switch await Task.detached(operation: { Result { try readBookmarks(profile) } }).value {
            case .success(let entries): report.bookmarks = await Task.detached { HistoryStore.shared.importBookmarks(entries) }.value
            case .failure: report.problems.append("\(source.shortName)'s bookmarks couldn't be read.")
            }
        }
        if what.contains(.history) {
            progress("Bringing over history…")
            switch await Task.detached(operation: { Result { try readHistory(profile, days: days) } }).value {
            case .success(let entries): report.history = await Task.detached { HistoryStore.shared.importVisits(entries) }.value
            case .failure: report.problems.append("\(source.shortName)'s history couldn't be read.")
            }
        }
        if what.contains(.logins) {
            progress("Waiting for your OK in the macOS prompt…")
            switch await Task.detached(operation: { safeStoragePassword(for: source) }).value {
            case .failure(.denied):
                report.problems.append("Logins weren't brought over: macOS didn't get your OK to read \(source.shortName)'s key.")
            case .failure:
                report.problems.append("\(source.shortName) has no saved logins key on this Mac.")
            case .success(let password):
                progress("Bringing over logins…")
                switch await Task.detached(operation: { Result { try readCookies(profile, password: password) } }).value {
                case .failure:
                    report.problems.append("\(source.shortName)'s logins couldn't be read.")
                case .success(let read):
                    report.trackers = read.trackers
                    let cookies = read.cookies.map(\.winkCookie)
                    let (imported, _) = await withCheckedContinuation { continuation in
                        WinkProfile.default.importCookies(cookies) { imported, rejected in
                            continuation.resume(returning: (imported, rejected))
                        }
                    }
                    report.cookies = imported
                    report.sites = imported == 0 ? 0 : Set(read.cookies.map {
                        WinkContentBlocker.registrableDomain(forHost: $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain)
                    }).count
                }
            }
        }
        return report
    }

    /// What a profile holds, counted without decrypting anything (no prompt).
    struct Preview: Sendable, Equatable {
        var history = 0
        var bookmarks = 0
        var loginSites = 0
    }

    static func preview(_ profile: Profile, days: Int) -> Preview {
        var preview = Preview()
        preview.bookmarks = (try? readBookmarks(profile).filter { HistoryStore.isRecordable($0.url) }.count) ?? 0
        let history = profile.folder.appendingPathComponent("History")
        if FileManager.default.fileExists(atPath: history.path), let copy = try? SQLiteCopy(of: history) {
            withExtendedLifetime(copy) {
                guard let statement = try? copy.prepare("""
                    SELECT count(*) FROM urls WHERE hidden = 0 AND last_visit_time >= ?1
                      AND (url LIKE 'http://%' OR url LIKE 'https://%')
                    """) else { return }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, chromeTime(Date().addingTimeInterval(-Double(max(days, 1)) * 86400)))
                if sqlite3_step(statement) == SQLITE_ROW { preview.history = Int(sqlite3_column_int64(statement, 0)) }
            }
        }
        let cookies = ["Cookies", "Network/Cookies"].map { profile.folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        if let cookies, let copy = try? SQLiteCopy(of: cookies) {
            withExtendedLifetime(copy) {
                // The same cookies the import brings: first-party and unexpired.
                guard let statement = (try? copy.prepare("""
                    SELECT DISTINCT host_key FROM cookies
                    WHERE top_frame_site_key = '' AND (has_expires = 0 OR expires_utc > ?1)
                    """)) ?? (try? copy.prepare("SELECT DISTINCT host_key FROM cookies")) else { return }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_int64(statement, 1, chromeTime(Date()))
                var sites = Set<String>()
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let domain = text(statement, 0) else { continue }
                    let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                    if !isTrackerHost(host) {
                        sites.insert(WinkContentBlocker.registrableDomain(forHost: host))
                    }
                }
                preview.loginSites = sites.count
            }
        }
        return preview
    }

    // MARK: - Readers (any thread)

    static func readHistory(_ profile: Profile, days: Int) throws -> [HistoryEntry] {
        let file = profile.folder.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let copy = try SQLiteCopy(of: file)
        let cutoff = chromeTime(Date().addingTimeInterval(-Double(max(days, 1)) * 86400))
        return try withExtendedLifetime(copy) {
            let statement = try copy.prepare("""
                SELECT url, title, visit_count, last_visit_time FROM urls
                WHERE hidden = 0 AND last_visit_time >= ?1 ORDER BY last_visit_time DESC LIMIT 50000
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, cutoff)
            var rows: [HistoryEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let url = text(statement, 0), let visited = date(fromChrome: sqlite3_column_int64(statement, 3)) else { continue }
                rows.append(HistoryEntry(url: url, title: text(statement, 1) ?? "",
                                         visitCount: Int(sqlite3_column_int64(statement, 2)), lastVisit: visited))
            }
            return rows
        }
    }

    static func readBookmarks(_ profile: Profile) throws -> [BookmarkEntry] {
        let file = profile.folder.appendingPathComponent("Bookmarks")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw Failure.unreadable("Bookmarks") }
        var entries: [BookmarkEntry] = []
        func walk(_ node: [String: Any], folder: String) {
            let name = node["name"] as? String ?? ""
            if node["type"] as? String == "url", let url = node["url"] as? String {
                let added = (node["date_added"] as? String).flatMap(Int64.init).flatMap(date(fromChrome:)) ?? Date()
                entries.append(BookmarkEntry(url: url, title: name, folder: folder, added: added))
            }
            let path = node["type"] as? String == "folder" ? (folder.isEmpty ? name : "\(folder) › \(name)") : folder
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child, folder: path) }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let root = roots[key] as? [String: Any] { walk(root, folder: "") }
        }
        return entries
    }

    /// Reads and decrypts cookies. Partitioned (third-party) cookies, expired
    /// ones and known trackers stay behind.
    static func readCookies(_ profile: Profile, password: String) throws -> (cookies: [Cookie], trackers: Int) {
        let candidates = ["Cookies", "Network/Cookies"].map { profile.folder.appendingPathComponent($0) }
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return ([], 0) }
        guard let key = cookieKey(password: password) else { throw Failure.noKey }
        let copy = try SQLiteCopy(of: file)
        return try withExtendedLifetime(copy) { try readCookieRows(copy, key: key) }
    }

    private static func readCookieRows(_ copy: SQLiteCopy, key: [UInt8]) throws -> (cookies: [Cookie], trackers: Int) {
        let statement = try copy.prepare("SELECT * FROM cookies")
        defer { sqlite3_finalize(statement) }
        var column: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            column[String(cString: sqlite3_column_name(statement, index))] = index
        }
        func int(_ name: String, _ fallback: Int64 = 0) -> Int64 {
            column[name].map { sqlite3_column_int64(statement, $0) } ?? fallback
        }
        func string(_ name: String) -> String { column[name].flatMap { text(statement, $0) } ?? "" }
        func bytes(_ name: String) -> [UInt8] {
            guard let index = column[name], let pointer = sqlite3_column_blob(statement, index) else { return [] }
            return Array(UnsafeRawBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, index))))
        }

        let now = Date()
        var cookies: [Cookie] = []
        var trackers = 0
        var trackerVerdicts: [String: Bool] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard string("top_frame_site_key").isEmpty else { continue }
            let domain = string("host_key")
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let expires = int("has_expires") != 0 ? date(fromChrome: int("expires_utc")) : nil
            if let expires, expires < now { continue }
            // A cookie whose own host is on Wink's tracker list stays behind.
            // (The lookup walks up to parent domains, never down, so a login
            // on google.com is kept even though some *.google.com hosts are listed.)
            let isTracker: Bool
            if let known = trackerVerdicts[host] {
                isTracker = known
            } else {
                isTracker = isTrackerHost(host)
                trackerVerdicts[host] = isTracker
            }
            if isTracker { trackers += 1; continue }
            let encrypted = bytes("encrypted_value")
            guard let value = encrypted.isEmpty ? string("value") : decrypt(encrypted, key: key, domain: domain) else { continue }
            cookies.append(Cookie(name: string("name"), value: value, domain: domain,
                                  path: string("path").isEmpty ? "/" : string("path"),
                                  secure: int("is_secure") != 0, httpOnly: int("is_httponly") != 0,
                                  expires: expires, creation: date(fromChrome: int("creation_utc")),
                                  lastAccess: date(fromChrome: int("last_access_utc")),
                                  sameSite: Int(int("samesite", -1)), priority: Int(int("priority", 1))))
        }
        return (cookies, trackers)
    }

    /// On Wink's tracker list. No first party is given: the engine never
    /// blocks a site's own requests, and this asks about the host itself.
    private static func isTrackerHost(_ host: String) -> Bool {
        WinkContentBlocker.shouldBlockURL("https://\(host)/", firstPartyURL: nil)
    }

    // MARK: - Keys and crypto

    /// The browser's "… Safe Storage" password. macOS asks the user first.
    static func safeStoragePassword(for source: Source) -> Result<String, Failure> {
        if source.id == "test" {
            return ProcessInfo.processInfo.environment["WINK_IMPORT_TEST_KEY"].map { .success($0) } ?? .failure(.noKey)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: source.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else { return .failure(.noKey) }
            return .success(password)
        case errSecItemNotFound:
            return .failure(.noKey)
        default:
            return .failure(.denied)  // Deny, Cancel, or a locked keychain
        }
    }

    /// Chromium on macOS: PBKDF2-SHA1 of the Safe Storage password, 1003 rounds.
    static func cookieKey(password: String) -> [UInt8]? {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        return status == kCCSuccess ? key : nil
    }

    /// "v10" + AES-128-CBC with a 16-space IV. Since Chrome 130 the plaintext
    /// starts with the SHA-256 of the cookie's domain, which is checked and dropped.
    static func decrypt(_ blob: [UInt8], key: [UInt8], domain: String) -> String? {
        guard blob.count > 3, blob[0] == 0x76, blob[1] == 0x31, blob[2] == 0x30 else { return nil }
        let cipher = Array(blob[3...])
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var plain = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var length = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, cipher, cipher.count, &plain, plain.count, &length)
        guard status == kCCSuccess else { return nil }
        var value = Array(plain[..<length])
        if value.count >= 32, value[..<32].elementsEqual(SHA256.hash(data: Data(domain.utf8))) {
            value.removeFirst(32)
        }
        return String(bytes: value, encoding: .utf8)
    }

    // MARK: - Helpers

    /// Microseconds since 1601-01-01 UTC, Chromium's clock.
    static func date(fromChrome microseconds: Int64) -> Date? {
        microseconds > 0 ? Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600) : nil
    }

    static func chromeTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    /// The other browser keeps its databases open, so Wink reads a private
    /// copy (with any journal) and deletes it afterwards.
    private final class SQLiteCopy {
        let db: OpaquePointer
        private let folder: URL

        init(of file: URL) throws {
            let manager = FileManager.default
            folder = manager.temporaryDirectory.appendingPathComponent("wink-import-\(UUID().uuidString)")
            try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let copy = folder.appendingPathComponent(file.lastPathComponent)
            do {
                try manager.copyItem(at: file, to: copy)
                for suffix in ["-journal", "-wal"] where manager.fileExists(atPath: file.path + suffix) {
                    try? manager.copyItem(atPath: file.path + suffix, toPath: copy.path + suffix)
                }
            } catch {
                try? manager.removeItem(at: folder)
                throw Failure.unreadable(file.lastPathComponent)
            }
            var handle: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
                sqlite3_close(handle)
                try? manager.removeItem(at: folder)
                throw Failure.unreadable(file.lastPathComponent)
            }
            db = handle
        }

        func prepare(_ sql: String) throws -> OpaquePointer? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.unreadable(sql) }
            return statement
        }

        deinit {
            sqlite3_close_v2(db)
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

extension BrowserImport.Cookie {
    var winkCookie: WinkCookie {
        let cookie = WinkCookie()
        cookie.name = name
        cookie.value = value
        cookie.domain = domain
        cookie.path = path
        cookie.secure = secure
        cookie.httpOnly = httpOnly
        cookie.expires = expires
        cookie.creation = creation
        cookie.lastAccess = lastAccess
        cookie.sameSite = sameSite
        cookie.priority = priority
        return cookie
    }
}
