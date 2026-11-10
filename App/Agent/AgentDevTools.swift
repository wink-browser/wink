import AVFoundation
import AppKit
import ImageIO

/// Network mocks and offline mode for one tab, through the DevTools Fetch and
/// Network domains. Only requests matching a mock are intercepted, so the rest
/// of the page loads at full speed.
@MainActor
final class NetworkMocks {
    struct Mock {
        let pattern: String
        let block: Bool
        let status: Int
        let body: String
        let contentType: String
        var hits = 0
    }

    private weak var tab: Tab?
    private(set) var mocks: [Mock] = []
    private(set) var offline = false
    private var listening = false

    init(tab: Tab) {
        self.tab = tab
    }

    /// `pattern` matches when it occurs in the URL; `*` matches anything.
    func add(_ mock: Mock) async throws {
        mocks.removeAll { $0.pattern == mock.pattern }
        mocks.append(mock)
        try await apply()
    }

    func clear() async throws {
        mocks.removeAll()
        try await apply()
    }

    func setOffline(_ value: Bool) async throws {
        guard let tab else { return }
        offline = value
        _ = try await tab.cdp.send("Network.emulateNetworkConditions", [
            "offline": value, "latency": 0, "downloadThroughput": -1, "uploadThroughput": -1,
        ])
    }

    /// Re-applies after the tab's DevTools session was reset (sleep, crash).
    func restore() async {
        if !mocks.isEmpty { try? await apply() }
        if offline { try? await setOffline(true) }
    }

    private func apply() async throws {
        guard let tab else { return }
        let cdp = tab.cdp
        if !listening {
            listening = true
            cdp.on("Fetch.requestPaused") { [weak self] params in
                guard let self else { return }
                Task { @MainActor in await self.paused(params) }
            }
        }
        if mocks.isEmpty {
            _ = try? await cdp.send("Fetch.disable")
            return
        }
        let patterns = mocks.map { ["urlPattern": Self.glob($0.pattern), "requestStage": "Request"] }
        _ = try await cdp.send("Fetch.enable", ["patterns": patterns])
    }

    private func paused(_ params: [String: Any]) async {
        guard let tab, let id = params["requestId"] as? String else { return }
        let url = (params["request"] as? [String: Any])?["url"] as? String ?? ""
        guard let index = mocks.lastIndex(where: { Self.matches($0.pattern, url) }) else {
            _ = try? await tab.cdp.send("Fetch.continueRequest", ["requestId": id])
            return
        }
        mocks[index].hits += 1
        let mock = mocks[index]
        if mock.block {
            _ = try? await tab.cdp.send("Fetch.failRequest", ["requestId": id, "errorReason": "BlockedByClient"])
            return
        }
        let headers: [[String: String]] = [
            ["name": "Content-Type", "value": mock.contentType],
            ["name": "Access-Control-Allow-Origin", "value": "*"],
            ["name": "Cache-Control", "value": "no-store"],
        ]
        _ = try? await tab.cdp.send("Fetch.fulfillRequest", [
            "requestId": id, "responseCode": mock.status, "responseHeaders": headers,
            "body": Data(mock.body.utf8).base64EncodedString(),
        ])
    }

    /// DevTools URL patterns: `*` any run, `?` one character, and the pattern
    /// must match the whole URL, so a plain fragment becomes `*fragment*`.
    static func glob(_ pattern: String) -> String {
        pattern.contains("*") ? pattern : "*\(pattern)*"
    }

    static func matches(_ pattern: String, _ url: String) -> Bool {
        guard pattern.contains("*") else { return url.contains(pattern) }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var rest = Substring(url)
        for (i, part) in parts.enumerated() where !part.isEmpty {
            guard let range = rest.range(of: part) else { return false }
            if i == 0 && range.lowerBound != rest.startIndex { return false }
            rest = rest[range.upperBound...]
        }
        return parts.last?.isEmpty == true || rest.isEmpty
    }
}

/// Records what a tab shows as an H.264 movie.
@MainActor
final class TabRecorder {
    private weak var tab: Tab?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var start: Double?
    private var last: Double = 0
    private(set) var url: URL?
    private(set) var frames = 0
    var isRecording: Bool { loop != nil }

    init(tab: Tab) {
        self.tab = tab
    }

    private var loop: Task<Void, Never>?

    /// Captures the tab about five times a second. Screenshots work on tabs
    /// in the background (which don't paint, so a screencast gets nothing).
    func begin(to url: URL) async throws {
        guard let tab, writer == nil, loop == nil else { return }
        self.url = url
        frames = 0
        start = nil
        let first = try await tab.cdp.screenshot(maxWidth: 1600, quality: 72)
        append(first.data, at: Date().timeIntervalSince1970)
        loop = Task { @MainActor [weak self, weak tab] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, let tab, !Task.isCancelled else { return }
                if let shot = try? await tab.cdp.screenshot(maxWidth: 1600, quality: 72) {
                    self.append(shot.data, at: Date().timeIntervalSince1970)
                }
            }
        }
    }

    /// Stops and finishes the movie. Returns its file, or nil if no frame came.
    func end() async -> URL? {
        loop?.cancel()
        loop = nil
        guard let writer, let input else {
            self.writer = nil
            return nil
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: max(last - (start ?? last), 0.1) + 0.5, preferredTimescale: 600))
        await writer.finishWriting()
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        return writer.status == .completed ? url : nil
    }

    private func append(_ jpeg: Data, at time: Double) {
        guard let url, let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let width = image.width & ~1, height = image.height & ~1
        if writer == nil {
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
            guard writer.canAdd(input) else { return }
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            start = time
        }
        guard let input, let adaptor, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let seconds = max(time - (start ?? time), last - (start ?? time) + 0.001)
        last = (start ?? time) + seconds
        if adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) { frames += 1 }
    }
}

/// A step-by-step record of what agents did in a tab: every tool call with its
/// result, a screenshot after each action, and the console messages and
/// network requests that happened during it. Saved as one self-contained HTML
/// page (no scripts) that opens in any browser.
@MainActor
final class TabTrace {
    struct Step {
        let index: Int
        let at: TimeInterval
        let duration: TimeInterval
        let tool: String
        let args: String
        let result: String
        let isError: Bool
        let screenshot: Data?
        let console: [ConsoleEntry]
        let requests: [AgentInstruments.Request]
    }

    let started = Date()
    let agent: String
    let url: String
    private(set) var steps: [Step] = []
    private var mark: Date

    init(agent: String, url: String) {
        self.agent = agent
        self.url = url
        mark = started
    }

    func add(tool: String, args: String, result: AgentToolResult, began: Date, screenshot: Data?, tab: Tab) {
        let now = Date()
        let console = tab.console.elements.filter { $0.timestamp >= mark && $0.timestamp <= now }
        let requests = tab.instruments.requests.filter { $0.started >= mark && $0.started <= now }
        steps.append(Step(index: steps.count + 1, at: began.timeIntervalSince(started), duration: now.timeIntervalSince(began),
                          tool: tool, args: args, result: result.summary, isError: result.isError,
                          screenshot: screenshot, console: console, requests: requests))
        mark = now
    }

    func html() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let total = steps.last.map { $0.at + $0.duration } ?? 0
        let errors = steps.filter(\.isError).count
        var out = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Wink trace · \(esc(agent))</title>
        <style>
        :root{--ink:#12151f;--cobalt:#065fb1;--paper:#f6efe0;--line:#d9cfba;--bad:#b3261e}
        body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.5 -apple-system,system-ui,sans-serif}
        header{padding:28px 32px 20px;border-bottom:1px solid var(--line)}
        h1{margin:0;font-size:20px;font-weight:600;color:var(--cobalt);letter-spacing:.02em}
        header p{margin:6px 0 0;color:#555}
        main{padding:12px 32px 48px;max-width:1100px}
        details{border:1px solid var(--line);background:#fffdf8;margin:12px 0;border-radius:6px}
        summary{cursor:pointer;padding:10px 14px;display:flex;gap:14px;align-items:baseline;list-style:none}
        summary::-webkit-details-marker{display:none}
        .n{color:#999;font-variant-numeric:tabular-nums;min-width:2.5em}.t{color:#999;font-variant-numeric:tabular-nums;min-width:5.5em}
        .tool{font-weight:600;color:var(--cobalt)}.args{color:#555;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}
        .err .tool{color:var(--bad)}
        .body{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1.1fr);gap:16px;padding:0 14px 14px}
        pre{margin:0;white-space:pre-wrap;word-break:break-word;font:12.5px/1.45 ui-monospace,Menlo,monospace;background:#f3ecdc;padding:10px;border-radius:4px}
        img{width:100%;border:1px solid var(--line);border-radius:4px}
        h3{font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:#777;margin:12px 0 6px}
        .bad{color:var(--bad)}
        @media (max-width:760px){.body{grid-template-columns:1fr}main,header{padding-inline:16px}}
        </style></head><body>
        <header><h1>Wink trace</h1><p>\(esc(agent)) · \(esc(url)) · \(steps.count) step\(steps.count == 1 ? "" : "s") in \(String(format: "%.1f", total)) s\(errors > 0 ? " · \(errors) failed" : "") · recorded \(esc(DateFormatter.localizedString(from: started, dateStyle: .medium, timeStyle: .medium)))</p></header><main>
        """
        for step in steps {
            out += "<details\(step.isError ? " class=\"err\"" : "")\(step.index <= 3 ? " open" : "")><summary><span class=\"n\">\(step.index)</span><span class=\"t\">+\(String(format: "%.2f", step.at)) s</span><span class=\"tool\">\(esc(step.tool))</span><span class=\"args\">\(esc(step.args))</span><span class=\"t\">\(String(format: "%.2f", step.duration)) s</span></summary><div class=\"body\"><div><h3>Result</h3><pre>\(esc(String(step.result.prefix(6000))))</pre>"
            if !step.console.isEmpty {
                out += "<h3>Console</h3><pre>" + step.console.map { entry in
                    let line = esc("[\(entry.level == .error ? "error" : entry.level == .warning ? "warning" : "log")] \(entry.message.prefix(400))")
                    return entry.level == .error ? "<span class=\"bad\">\(line)</span>" : line
                }.joined(separator: "\n") + "</pre>"
            }
            if !step.requests.isEmpty {
                out += "<h3>Network</h3><pre>" + step.requests.prefix(60).map { r in
                    let status = r.status.map(String.init) ?? r.failure ?? "…"
                    let line = esc("\(r.method) \(status) \(r.url.prefix(160))")
                    return (r.failure != nil || (r.status ?? 0) >= 400) ? "<span class=\"bad\">\(line)</span>" : line
                }.joined(separator: "\n") + "</pre>"
            }
            out += "</div><div>"
            if let shot = step.screenshot {
                out += "<h3>After</h3><img alt=\"The page after step \(step.index)\" src=\"data:image/jpeg;base64,\(shot.base64EncodedString())\">"
            }
            out += "</div></div></details>\n"
        }
        return out + "</main></body></html>\n"
    }
}
