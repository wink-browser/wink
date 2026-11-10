import AppKit
import ImageIO
import WinkEngine

struct CDPError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
    /// The page navigated or the tab slept while the command was in flight.
    var isLostContext: Bool {
        message.contains("context") || message.contains("Cannot find") || message.contains("closed or put to sleep")
    }
}

/// Chrome DevTools Protocol channel for one tab.
///
/// Messages go straight into the tab's browser via CEF (SendDevToolsMessage) —
/// no remote-debugging port is ever opened, so nothing else on the machine
/// can attach to the user's browser. Agent scripts run in a private isolated
/// world: they share the DOM with the page but the page cannot see or tamper
/// with them.
@MainActor
final class CDPSession {
    private weak var tab: Tab?
    private weak var boundView: WinkWebView?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingMethods: [Int: String] = [:]
    private var isolatedContextID: Int?
    /// Isolated world that already has PageScripts.library installed.
    private var libraryContextID: Int?
    private var eventListeners: [String: [UUID: ([String: Any]) -> Void]] = [:]

    init(tab: Tab) {
        self.tab = tab
    }

    /// Fails in-flight commands (tab slept/closed) and forgets cached state.
    func reset() {
        let waiting = pending
        pending.removeAll()
        pendingMethods.removeAll()
        waiting.values.forEach { $0.resume(throwing: CDPError(message: "The tab was closed or put to sleep.")) }
        isolatedContextID = nil
        libraryContextID = nil
        boundView = nil
        tab?.instruments.cdpReset()
    }

    /// A JavaScript dialog blocks the page, so input commands in flight never
    /// return until it's answered: stop waiting for them (their late replies
    /// are ignored) so the agent can be told about the dialog.
    func releaseBlockedInput() {
        for (id, method) in pendingMethods where method.hasPrefix("Input.") || method == "Runtime.evaluate" {
            pendingMethods.removeValue(forKey: id)
            if method == "Runtime.evaluate" {
                pending.removeValue(forKey: id)?.resume(throwing: CDPError(message: "A JavaScript dialog is open."))
            } else {
                pending.removeValue(forKey: id)?.resume(returning: [:])
            }
        }
    }

    func invalidateIsolatedWorld() {
        isolatedContextID = nil
        libraryContextID = nil
    }

    // MARK: - Commands

    func send(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard let tab else { throw CDPError(message: "Tab no longer exists.") }
        guard let view = tab.webView else { throw CDPError(message: "Tab is asleep; activate it first.") }
        if view.hasBrowser == false {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in tab.whenBrowserReady { c.resume() } }
        }
        bind(view)

        let id = nextID
        nextID += 1
        var message: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { message["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: message)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            pendingMethods[id] = method
            if !view.sendDevToolsMessage(data) {
                pending.removeValue(forKey: id)
                pendingMethods.removeValue(forKey: id)
                continuation.resume(throwing: CDPError(message: "Could not reach the page (\(method))."))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                self.pendingMethods.removeValue(forKey: id)
                waiting.resume(throwing: CDPError(message: "\(method) timed out after \(Int(timeout))s."))
            }
        }
    }

    private func bind(_ view: WinkWebView) {
        guard boundView !== view else { return }
        boundView = view
        isolatedContextID = nil
        libraryContextID = nil
        view.devToolsResultHandler = { [weak self] id, success, data in
            self?.handleResult(id: id, success: success, data: data)
        }
    }

    private func handleResult(id: Int, success: Bool, data: Data) {
        pendingMethods.removeValue(forKey: id)
        guard let continuation = pending.removeValue(forKey: id) else { return }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if success {
            continuation.resume(returning: object)
        } else {
            continuation.resume(throwing: CDPError(message: object["message"] as? String ?? "DevTools error"))
        }
    }

    // MARK: - Events

    func handleEvent(method: String, params: Data) {
        guard let listeners = eventListeners[method], !listeners.isEmpty else { return }
        let object = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any] ?? [:]
        listeners.values.forEach { $0(object) }
    }

    @discardableResult
    func on(_ method: String, _ handler: @escaping ([String: Any]) -> Void) -> UUID {
        let token = UUID()
        eventListeners[method, default: [:]][token] = handler
        tab?.webView?.devToolsEventsEnabled = true
        return token
    }

    func off(_ method: String, _ token: UUID) {
        eventListeners[method]?.removeValue(forKey: token)
        if eventListeners.values.allSatisfy({ $0.isEmpty }) { tab?.webView?.devToolsEventsEnabled = false }
    }

    // MARK: - JavaScript

    /// Evaluates `expression` in Wink's isolated world with the agent library
    /// (`__wink`) available. The ~25 KB library is sent once per document, not
    /// with every call.
    func evaluateAgent(_ expression: String, awaitPromise: Bool = true, timeout: TimeInterval = 30) async throws -> Any? {
        let contextID = try await isolatedContext()
        let needsLibrary = libraryContextID != contextID
        let source = needsLibrary ? PageScripts.library + ";\n" + expression : expression
        do {
            let value = try await evaluate(source, contextID: contextID, awaitPromise: awaitPromise, timeout: timeout)
            libraryContextID = contextID
            return value
        } catch let error as CDPError where error.isLostContext || error.message.contains("__wink is not defined") {
            // The document changed under us: new world, fresh library.
            isolatedContextID = nil
            libraryContextID = nil
            let fresh = try await isolatedContext()
            let value = try await evaluate(PageScripts.library + ";\n" + expression, contextID: fresh, awaitPromise: awaitPromise, timeout: timeout)
            libraryContextID = fresh
            return value
        } catch {
            if needsLibrary { libraryContextID = contextID }  // the library ran; the expression threw
            throw error
        }
    }

    private func evaluate(_ expression: String, contextID: Int, awaitPromise: Bool, timeout: TimeInterval = 30) async throws -> Any? {
        let result = try await send("Runtime.evaluate", [
            "expression": expression,
            "contextId": contextID,
            "returnByValue": true,
            "awaitPromise": awaitPromise,
        ], timeout: timeout)
        if let details = result["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            let text = exception?["description"] as? String ?? details["text"] as? String ?? "Script error"
            // "Error: Element e12 is no longer…" → "Element e12 is no longer…"
            throw CDPError(message: text.components(separatedBy: "\n    at ").first?
                .replacingOccurrences(of: "Error: ", with: "", options: .anchored) ?? text)
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    /// A remote object handle for what `expression` returns in the agent's
    /// world (e.g. a DOM node for DOM.setFileInputFiles).
    func agentObjectID(_ expression: String) async throws -> String {
        _ = try await evaluateAgent("1")  // the library is installed
        let contextID = try await isolatedContext()
        let result = try await send("Runtime.evaluate", ["expression": expression, "contextId": contextID, "returnByValue": false])
        if let details = result["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            let text = exception?["description"] as? String ?? details["text"] as? String ?? "Script error"
            throw CDPError(message: text.components(separatedBy: "\n    at ").first?
                .replacingOccurrences(of: "Error: ", with: "", options: .anchored) ?? text)
        }
        guard let id = (result["result"] as? [String: Any])?["objectId"] as? String else {
            throw CDPError(message: "No element.")
        }
        return id
    }

    /// Evaluates in the page's own (main) world. Only for the explicitly
    /// permitted `evaluate` tool — agents normally stay in the isolated world.
    func evaluateInPage(_ expression: String) async throws -> Any? {
        let result = try await send("Runtime.evaluate", [
            "expression": expression, "returnByValue": true, "awaitPromise": true,
        ])
        if let details = result["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            throw CDPError(message: exception?["description"] as? String ?? details["text"] as? String ?? "Script error")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    private func isolatedContext() async throws -> Int {
        if let isolatedContextID { return isolatedContextID }
        let tree = try await send("Page.getFrameTree")
        guard let frameTree = tree["frameTree"] as? [String: Any],
              let frame = frameTree["frame"] as? [String: Any],
              let frameID = frame["id"] as? String else {
            throw CDPError(message: "Page has no main frame yet.")
        }
        let world = try await send("Page.createIsolatedWorld", [
            "frameId": frameID, "worldName": "wink-agent", "grantUniveralAccess": false,
        ])
        guard let contextID = world["executionContextId"] as? Int else {
            throw CDPError(message: "Could not create an isolated world.")
        }
        isolatedContextID = contextID
        libraryContextID = nil
        return contextID
    }

    // MARK: - Input (trusted events, like a real user)

    func click(x: Double, y: Double, button: String = "left", clickCount: Int = 1) async throws {
        try await moveMouse(x: x, y: y)
        for count in 1...max(1, clickCount) {
            _ = try await send("Input.dispatchMouseEvent", [
                "type": "mousePressed", "x": x, "y": y, "button": button, "clickCount": count,
            ])
            _ = try await send("Input.dispatchMouseEvent", [
                "type": "mouseReleased", "x": x, "y": y, "button": button, "clickCount": count,
            ])
        }
    }

    /// Presses at `from`, moves to `to` and releases. HTML5 drag and drop is
    /// intercepted and replayed as drag events; pointer-based libraries see
    /// the mouse moves.
    func drag(from: CGPoint, to: CGPoint) async throws {
        final class Box { var data: [String: Any]? }
        let box = Box()
        _ = try? await send("Input.setInterceptDrags", ["enabled": true])
        let token = on("Input.dragIntercepted") { box.data = $0["data"] as? [String: Any] }
        defer { off("Input.dragIntercepted", token) }
        try await moveMouse(x: from.x, y: from.y)
        _ = try await send("Input.dispatchMouseEvent", ["type": "mousePressed", "x": from.x, "y": from.y,
                                                        "button": "left", "buttons": 1, "clickCount": 1])
        let steps = 6
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            // Moves wait for frames; with none coming (display asleep), give up on them quickly.
            let moved = (try? await send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": from.x + (to.x - from.x) * t,
                                                                      "y": from.y + (to.y - from.y) * t, "button": "left", "buttons": 1],
                                         timeout: 0.3)) != nil
            if !moved { break }
            try? await Task.sleep(nanoseconds: 8_000_000)
            if box.data != nil { break }
        }
        if let data = box.data {
            for type in ["dragEnter", "dragOver", "drop"] {
                _ = try await send("Input.dispatchDragEvent", ["type": type, "x": to.x, "y": to.y, "data": data])
            }
        }
        _ = try await send("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": to.x, "y": to.y,
                                                        "button": "left", "buttons": 0, "clickCount": 1])
        _ = try? await send("Input.setInterceptDrags", ["enabled": false])
    }

    func hover(x: Double, y: Double) async throws {
        try await moveMouse(x: x, y: y)
    }

    /// Mouse moves are delivered with the next frame; while the display sleeps
    /// there are no frames, so don't wait long for one.
    private func moveMouse(x: Double, y: Double) async throws {
        do {
            _ = try await send("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": x, "y": y], timeout: 0.3)
        } catch let error as CDPError where error.message.contains("timed out") {
            return
        }
    }

    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws {
        _ = try await send("Input.dispatchMouseEvent", [
            "type": "mouseWheel", "x": x, "y": y, "deltaX": deltaX, "deltaY": deltaY,
        ])
    }

    func insertText(_ text: String) async throws {
        _ = try await send("Input.insertText", ["text": text])
    }

    func press(_ combo: String) async throws {
        let key = KeyDescriptor.parse(combo)
        var down: [String: Any] = [
            "type": key.text == nil ? "rawKeyDown" : "keyDown",
            "key": key.key, "code": key.code,
            "windowsVirtualKeyCode": key.keyCode, "nativeVirtualKeyCode": key.keyCode,
            "modifiers": key.modifiers,
        ]
        if let text = key.text { down["text"] = text; down["unmodifiedText"] = text }
        if !key.commands.isEmpty { down["commands"] = key.commands }
        _ = try await send("Input.dispatchKeyEvent", down)
        _ = try await send("Input.dispatchKeyEvent", [
            "type": "keyUp", "key": key.key, "code": key.code,
            "windowsVirtualKeyCode": key.keyCode, "nativeVirtualKeyCode": key.keyCode,
            "modifiers": key.modifiers,
        ])
    }

    struct Screenshot {
        let data: Data
        let width: Int
        let height: Int
        /// Image pixels per CSS pixel. 1 means image coordinates are click coordinates.
        let scale: Double
        let fullPage: Bool
    }

    /// JPEG of the viewport (or whole page). By default one image pixel is one
    /// CSS pixel, so coordinates read off the image can be clicked directly;
    /// wider viewports are scaled down to `maxWidth`. `pixelRatio` asks for a
    /// sharper image (e.g. 2 for Retina-quality captures).
    func screenshot(maxWidth: Double = 1280, quality: Int = 70, fullPage: Bool = false,
                    pixelRatio: Double = 1) async throws -> Screenshot {
        let metrics = try await send("Page.getLayoutMetrics")
        let viewport = metrics["cssVisualViewport"] as? [String: Any] ?? [:]
        let content = metrics["cssContentSize"] as? [String: Any] ?? [:]
        let width = viewport["clientWidth"] as? Double ?? 1280
        var height = viewport["clientHeight"] as? Double ?? 800
        if fullPage { height = min(content["height"] as? Double ?? height, 12_000) }
        // CDP output pixels = CSS pixels × clip.scale × devicePixelRatio.
        let dpr = (try? await evaluateAgent("devicePixelRatio")) as? Double ?? 2
        let scale = min(pixelRatio, maxWidth / max(width, 1))
        let result = try await send("Page.captureScreenshot", [
            "format": "jpeg", "quality": quality, "fromSurface": true,
            "captureBeyondViewport": fullPage,
            "clip": [
                "x": (viewport["pageX"] as? Double) ?? 0.0,
                "y": fullPage ? 0.0 : ((viewport["pageY"] as? Double) ?? 0.0),
                "width": width, "height": height, "scale": scale / max(dpr, 0.5),
            ] as [String: Double],
        ], timeout: 20)
        guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64) else {
            throw CDPError(message: "Screenshot failed.")
        }
        var pixelWidth = Int((width * scale).rounded()), pixelHeight = Int((height * scale).rounded())
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? pixelWidth
            pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? pixelHeight
        }
        return Screenshot(data: data, width: pixelWidth, height: pixelHeight, scale: scale, fullPage: fullPage)
    }
}

/// Maps key names like "Enter", "Shift+Tab", "Meta+A" to CDP key events.
struct KeyDescriptor {
    var key: String
    var code: String
    var keyCode: Int
    var text: String?
    var modifiers: Int
    var commands: [String] = []

    static func parse(_ combo: String) -> KeyDescriptor {
        var parts = combo.split(separator: "+").map { String($0) }
        let main = parts.popLast() ?? combo
        var modifiers = 0
        for part in parts {
            switch part.lowercased() {
            case "alt", "option": modifiers |= 1
            case "control", "ctrl": modifiers |= 2
            case "meta", "cmd", "command": modifiers |= 4
            case "shift": modifiers |= 8
            default: break
            }
        }
        let named: [String: (String, Int, String?)] = [
            "enter": ("Enter", 13, "\r"), "return": ("Enter", 13, "\r"), "tab": ("Tab", 9, nil),
            "escape": ("Escape", 27, nil), "esc": ("Escape", 27, nil), "backspace": ("Backspace", 8, nil),
            "delete": ("Delete", 46, nil), "space": (" ", 32, " "), "arrowup": ("ArrowUp", 38, nil),
            "arrowdown": ("ArrowDown", 40, nil), "arrowleft": ("ArrowLeft", 37, nil),
            "arrowright": ("ArrowRight", 39, nil), "home": ("Home", 36, nil), "end": ("End", 35, nil),
            "pageup": ("PageUp", 33, nil), "pagedown": ("PageDown", 34, nil),
        ]
        if let (key, keyCode, text) = named[main.lowercased()] {
            let code = key == " " ? "Space" : key
            return KeyDescriptor(key: key, code: code, keyCode: keyCode,
                                 text: modifiers & ~8 == 0 ? text : nil, modifiers: modifiers)
        }
        let character = main.count == 1 ? main : String(main.prefix(1))
        let upper = character.uppercased()
        let keyCode = Int(upper.unicodeScalars.first?.value ?? 0)
        let isLetter = character.rangeOfCharacter(from: .letters) != nil
        let code = isLetter ? "Key\(upper)" : (Int(character) != nil ? "Digit\(character)" : "")
        var descriptor = KeyDescriptor(key: character, code: code, keyCode: keyCode,
                                       text: modifiers & ~8 == 0 ? character : nil, modifiers: modifiers)
        // Editing shortcuts must be sent as editor commands on macOS.
        if modifiers & 4 != 0 {
            switch character.lowercased() {
            case "a": descriptor.commands = ["selectAll"]
            case "c": descriptor.commands = ["copy"]
            case "v": descriptor.commands = ["paste"]
            case "x": descriptor.commands = ["cut"]
            case "z": descriptor.commands = [modifiers & 8 != 0 ? "redo" : "undo"]
            default: break
            }
        }
        return descriptor
    }
}
