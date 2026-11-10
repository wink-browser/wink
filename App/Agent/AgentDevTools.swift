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
