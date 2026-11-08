import Foundation
import WinkEngine

enum Site {
    /// eTLD+1, e.g. "news.bbc.co.uk" -> "bbc.co.uk".
    static func registrableDomain(_ host: String) -> String {
        WinkContentBlocker.registrableDomain(forHost: host.lowercased())
    }

    static func host(of urlString: String) -> String {
        URLComponents(string: urlString)?.host?.lowercased() ?? ""
    }
}

enum URLInput {
    /// Turns omnibox text into a URL: explicit URLs, bare hostnames, local
    /// addresses, or a search on the user's search engine.
    static func resolve(_ raw: String, searchEngine: SearchEngine) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        let lower = text.lowercased()
        let explicitSchemes = ["http://", "https://", "file://", "about:", "view-source:", "data:", "chrome://", "blob:"]
        if explicitSchemes.contains(where: { lower.hasPrefix($0) }) { return text }

        if text.contains(" ") { return searchEngine.searchURL(for: text) }

        if lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1") || lower.hasPrefix("[::1]") ||
            lower.hasPrefix("0.0.0.0") {
            return "http://" + text
        }
        // host:port (e.g. "myapp.test:3000", "192.168.1.10:8080") — keep http for local dev.
        if let colon = text.firstIndex(of: ":"), Int(text[text.index(after: colon)...].prefix { $0.isNumber }) != nil {
            return "http://" + text
        }
        if looksLikeHost(text) { return "https://" + text }
        return searchEngine.searchURL(for: text)
    }

    static func looksLikeHost(_ text: String) -> Bool {
        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        guard hostPart.contains("."), !hostPart.hasPrefix("."), !hostPart.hasSuffix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:"))
        guard hostPart.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let tld = hostPart.split(separator: ".").last.map(String.init) ?? ""
        let tldLetters = tld.split(separator: ":").first.map(String.init) ?? tld
        return tldLetters.count >= 2 && tldLetters.allSatisfy { $0.isLetter } || isIPv4(hostPart)
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ":").first?.split(separator: ".") ?? []
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// Compact, human-friendly display ("github.com/anthropics").
    static func display(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString), let host = components.host else {
            return urlString
        }
        var display = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = components.path
        if path.count > 1 { display += path }
        return display
    }
}
