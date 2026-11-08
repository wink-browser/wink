import Foundation
import SQLite3

struct HistoryEntry: Hashable {
    let url: String
    let title: String
    let visitCount: Int
    let lastVisit: Date
}

/// Local-only browsing history (SQLite). Private windows never write here;
/// entries older than the retention window are pruned at launch.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "app.wink.history", qos: .utility)
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func open(at url: URL) {
        queue.sync {
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                db = nil
                return
            }
            exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            exec("""
                CREATE TABLE IF NOT EXISTS visits(
                  url TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', host TEXT NOT NULL DEFAULT '',
                  visit_count INTEGER NOT NULL DEFAULT 0, last_visit REAL NOT NULL DEFAULT 0);
                CREATE INDEX IF NOT EXISTS visits_host ON visits(host);
                CREATE INDEX IF NOT EXISTS visits_last ON visits(last_visit);
                """)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func isRecordable(_ url: String) -> Bool {
        (url.hasPrefix("https://") || url.hasPrefix("http://")) && url.count < 2048
    }

    func recordVisit(url: String, title: String) {
        guard Self.isRecordable(url) else { return }
        let host = Site.host(of: url)
        queue.async { [self] in
            run("""
                INSERT INTO visits(url, title, host, visit_count, last_visit) VALUES(?1, ?2, ?3, 1, ?4)
                ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + 1, last_visit = ?4,
                  title = CASE WHEN ?2 = '' THEN title ELSE ?2 END
                """, [url, title, host, Date().timeIntervalSince1970])
        }
    }

    func updateTitle(_ title: String, for url: String) {
        guard Self.isRecordable(url), !title.isEmpty else { return }
        queue.async { [self] in run("UPDATE visits SET title = ?1 WHERE url = ?2", [title, url]) }
    }

    func search(_ text: String, limit: Int = 8) -> [HistoryEntry] {
        let needle = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "")
        guard !needle.isEmpty else { return [] }
        return queue.sync {
            query("""
                SELECT url, title, visit_count, last_visit FROM visits
                WHERE host LIKE ?1 || '%' OR host LIKE 'www.' || ?1 || '%'
                   OR url LIKE '%' || ?1 || '%' OR title LIKE '%' || ?1 || '%'
                ORDER BY (host LIKE ?1 || '%' OR host LIKE 'www.' || ?1 || '%') DESC,
                         visit_count / (1.0 + (?3 - last_visit) / 86400.0) DESC
                LIMIT ?2
                """, [needle, limit, Date().timeIntervalSince1970])
        }
    }

    func recent(limit: Int = 50) -> [HistoryEntry] {
        queue.sync { query("SELECT url, title, visit_count, last_visit FROM visits ORDER BY last_visit DESC LIMIT ?1", [limit]) }
    }

    func prune(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        queue.async { [self] in run("DELETE FROM visits WHERE last_visit < ?1", [cutoff]) }
    }

    func clearAll() {
        queue.async { [self] in exec("DELETE FROM visits; VACUUM;") }
    }

    func deleteSite(_ site: String) {
        queue.async { [self] in run("DELETE FROM visits WHERE host = ?1 OR host LIKE '%.' || ?1", [site]) }
    }

    // MARK: - SQLite plumbing (call on `queue`)

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String, _ args: [Any]) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        for (index, arg) in args.enumerated() {
            let position = Int32(index + 1)
            switch arg {
            case let s as String: sqlite3_bind_text(statement, position, s, -1, transient)
            case let i as Int: sqlite3_bind_int64(statement, position, Int64(i))
            case let d as Double: sqlite3_bind_double(statement, position, d)
            default: sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ args: [Any]) {
        guard let statement = prepare(sql, args) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func query(_ sql: String, _ args: [Any]) -> [HistoryEntry] {
        guard let statement = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let url = String(cString: sqlite3_column_text(statement, 0))
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            rows.append(HistoryEntry(url: url, title: title,
                                     visitCount: Int(sqlite3_column_int64(statement, 2)),
                                     lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
        }
        return rows
    }
}
