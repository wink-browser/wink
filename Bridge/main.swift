// wink-mcp — stdio bridge between an MCP client (Claude Code, Claude Desktop,
// any agent) and the Wink browser.
//
//   claude mcp add --scope user wink -- /Applications/Wink.app/Contents/MacOS/wink-mcp
//
// The MCP server itself lives inside Wink and listens on a Unix domain socket
// that only the current user can reach (0700 directory, peer-uid checked).
// This process relays newline-delimited JSON-RPC in both directions. It never
// opens a network port.
//
// It is also what makes Wink pleasant to leave installed in every agent:
// - Lazy: an agent session starting up doesn't open Wink. The handshake and
//   the tool list come from a small file Wink writes next to its socket
//   (run/mcp-server.json); Wink opens on the first tool call.
// - Resilient: if Wink quits or restarts (an update, a crash), the next call
//   reopens it and replays the handshake, so the agent keeps its browser
//   tools instead of losing them for the rest of its session.

import Darwin
import Foundation

// The bridge lives in Wink.app/Contents/MacOS, so Foundation resolves the
// enclosing app as the main bundle. Talking to (and launching) that exact copy
// keeps a side-by-side dev build separate from the installed one.
let bundleIdentifier = Bundle.main.bundleIdentifier ?? "app.wink.browser"
let appBundlePath: String? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.path : nil

func log(_ message: String) {
    let text = "wink-mcp: \(message)\n"
    text.utf8CString.withUnsafeBufferPointer { _ = Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count - 1) }
}

func socketPath() -> String {
    if let override = getenv("WINK_MCP_SOCKET"), override.pointee != 0 { return String(cString: override) }
    let home = getenv("HOME").map { String(cString: $0) } ?? NSHomeDirectory()
    let folder = bundleIdentifier == "app.wink.browser" ? "Wink" : bundleIdentifier
    return home + "/Library/Application Support/\(folder)/run/mcp.sock"
}

let path = socketPath()
/// What Wink last said about itself (see MCPServer.writeHandshake).
let handshakeFile = (path as NSString).deletingLastPathComponent + "/mcp-server.json"

func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxLength else { close(fd); log("socket path too long: \(path)"); return nil }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { strncpy($0, path, maxLength) }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result != 0 { close(fd); return nil }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

func launchWink() {
    var args = ["/usr/bin/open", "-g"]
    // A side-by-side dev build passes its test settings on (never the release).
    if bundleIdentifier != "app.wink.browser" {
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("WINK_DEBUG") || key == "WINK_HOME" {
            args += ["--env", "\(key)=\(value)"]
        }
    }
    args += appBundlePath.map { [$0] } ?? ["-b", bundleIdentifier]
    var pid: pid_t = 0
    var cArgs = args.map { strdup($0) } + [nil]
    defer { cArgs.forEach { free($0) } }
    if posix_spawn(&pid, args[0], nil, nil, &cArgs, environ) == 0 {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

func parentProcessPath() -> String {
    var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    let length = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
    return length > 0 ? String(cString: buffer) : ""
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return true }
        var offset = 0
        while offset < raw.count {
            let n = Darwin.write(fd, base + offset, raw.count - offset)
            if n < 0 { if errno == EINTR || errno == EAGAIN { usleep(1000); continue }; return false }
            offset += n
        }
        return true
    }
}

func encode(_ object: Any) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
    data.append(0x0A)
    return data
}

/// A JSON-RPC id as a dictionary key (ids are numbers or strings).
func idKey(_ id: Any) -> String {
    if let string = id as? String { return "s:" + string }
    return "n:\(id)"
}

/// Lines split from a byte stream.
struct LineReader {
    private var buffer = Data()
    let fd: Int32

    init(fd: Int32) { self.fd = fd }

    /// The next complete line, or nil at end of stream.
    mutating func next() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                if buffer.isEmpty { return nil }
                let rest = buffer
                buffer.removeAll()
                return rest
            }
            buffer.append(chunk, count: n)
        }
    }
}

final class Bridge: @unchecked Sendable {
    private let lock = NSLock()
    private let outputLock = NSLock()
    /// The socket to Wink; -1 while not connected.
    private var upstream: Int32 = -1
    private var generation = 0
    /// The client's initialize request, replayed whenever we (re)connect.
    private var initializeRequest: [String: Any]?
    private var replayCount = 0
    /// Requests forwarded to Wink and not answered yet: id key → (id, method).
    private var pending: [String: (id: Any, method: String)] = [:]
    /// Ids of handshakes the bridge replays itself; Wink's answers stay here.
    private var swallowed: Set<String> = []

    // MARK: Client → Wink

    func run() {
        var stdin = LineReader(fd: STDIN_FILENO)
        while let line = stdin.next() {
            guard !line.isEmpty else { continue }
            handle(line)
        }
        // The client is done: let Wink finish answering, then leave.
        lock.lock()
        let fd = upstream
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_WR)
            let deadline = Date.now + 2
            while Date.now < deadline {
                lock.lock(); let open = upstream >= 0 && !pending.isEmpty; lock.unlock()
                if !open { break }
                usleep(20_000)
            }
        }
        exit(0)
    }

    private func handle(_ line: Data) {
        let object = try? JSONSerialization.jsonObject(with: line)
        let message = object as? [String: Any]
        let method = message?["method"] as? String
        let id = message?["id"]

        if method == "initialize", let message {
            lock.lock(); initializeRequest = message; lock.unlock()
            // Wink already open: talk to it directly. Otherwise answer from
            // what it wrote last time, and open it only when a tool is used.
            if connect(launch: false, replay: false) {
                forward(line, id: id, method: method)
            } else if let handshake = Self.handshake() {
                reply(id, Self.initializeResult(handshake, requested: (message["params"] as? [String: Any])?["protocolVersion"] as? String))
            } else if connect(launch: true, replay: false) {
                forward(line, id: id, method: method)
            } else {
                replyError(id, "Couldn't open Wink. Is it installed?")
            }
            return
        }

        lock.lock(); let connected = upstream >= 0; lock.unlock()
        if connected {
            forward(line, id: id, method: method)
            return
        }

        switch method {
        case "notifications/initialized"?, "notifications/cancelled"?:
            return  // replayed with the handshake when Wink opens
        case "ping"?:
            reply(id, [:])
        case "tools/list"?:
            if let handshake = Self.handshake(), let tools = handshake["tools"] {
                reply(id, ["tools": tools])
            } else {
                connectThenForward(line, id: id, method: method)
            }
        case "resources/list"?: reply(id, ["resources": []])
        case "resources/templates/list"?: reply(id, ["resourceTemplates": []])
        case "prompts/list"?: reply(id, ["prompts": []])
        case "logging/setLevel"?: reply(id, [:])
        case "tools/call"?, nil:
            // Real work (or a batch): this is when Wink opens.
            if message?["result"] != nil || message?["error"] != nil { return }  // a reply meant for Wink's last session
            connectThenForward(line, id: id, method: method)
        case let method?:
            // Anything else Wink doesn't implement either (e.g. Claude Code's
            // `server/discover` probe, which falls back to initialize).
            if !method.hasPrefix("notifications/") {
                replyError(id, "Method not found: \(method)", code: -32601)
            }
        }
    }

    private func connectThenForward(_ line: Data, id: Any?, method: String?, retry: Bool = true) {
        if connect(launch: true, replay: true) {
            forward(line, id: id, method: method, retry: retry)
        } else if let id {
            fail(id, method: method ?? "", "Couldn't open Wink. If it is open, check Settings › Agents › Let agents connect.")
        }
    }

    private func forward(_ line: Data, id: Any?, method: String?, retry: Bool = true) {
        lock.lock()
        let fd = upstream
        let key = id.map(idKey)
        if fd >= 0, let id, let key, let method { pending[key] = (id, method) }
        lock.unlock()
        var payload = line
        payload.append(0x0A)
        if fd >= 0 && writeAll(fd, payload) { return }
        // Wink went away between the check and the write: reconnect, once.
        if let key { lock.lock(); pending.removeValue(forKey: key); lock.unlock() }
        disconnected(fd)
        if retry, id != nil || method != nil {
            connectThenForward(line, id: id, method: method, retry: false)
        } else if let id {
            fail(id, method: method ?? "", "Lost the connection to Wink. Call the tool again.")
        }
    }

    // MARK: Connection

    /// Connects to Wink (opening it if `launch`), introduces the bridge and,
    /// when `replay`, repeats the client's handshake on the new connection.
    private func connect(launch: Bool, replay: Bool) -> Bool {
        lock.lock()
        if upstream >= 0 { lock.unlock(); return true }
        lock.unlock()

        var fd = connectSocket(path)
        if fd == nil && launch {
            launchWink()
            let deadline = Date.now + 25
            while fd == nil && Date.now < deadline {
                usleep(150_000)
                fd = connectSocket(path)
            }
        }
        guard let fd else { return false }

        // Identify ourselves first. The token is set when Wink itself launched
        // the agent (pre-approved); other agents are approved by the user in Wink.
        let token = getenv("WINK_AGENT_TOKEN").map { String(cString: $0) } ?? ""
        var outgoing = encode(["wink_bridge": 1, "pid": Int(getpid()), "parent": parentProcessPath(), "token": token])

        lock.lock()
        if replay, var initialize = initializeRequest {
            replayCount += 1
            let id = "wink-bridge-\(replayCount)"
            initialize["id"] = id
            swallowed.insert(idKey(id))
            outgoing += encode(initialize)
            outgoing += encode(["jsonrpc": "2.0", "method": "notifications/initialized"])
        }
        upstream = fd
        generation += 1
        let current = generation
        lock.unlock()

        // The reader owns the descriptor and closes it when Wink hangs up.
        let reader = Thread { [self] in pumpFromWink(fd, generation: current) }
        reader.start()
        guard writeAll(fd, outgoing) else { disconnected(fd); return false }
        return true
    }

    // MARK: Wink → client

    private func pumpFromWink(_ fd: Int32, generation: Int) {
        var lines = LineReader(fd: fd)
        while let line = lines.next() {
            guard !line.isEmpty else { continue }
            let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            if let id = message?["id"], message?["method"] == nil {
                let key = idKey(id)
                lock.lock()
                let isOwn = swallowed.remove(key) != nil
                pending.removeValue(forKey: key)
                lock.unlock()
                if isOwn { continue }
            }
            var payload = line
            payload.append(0x0A)
            output(payload)
        }
        lock.lock()
        let stillCurrent = self.generation == generation
        lock.unlock()
        if stillCurrent { disconnected(fd) }
        close(fd)
    }

    /// Wink closed the connection (quit, restarted, updated): answer what was
    /// in flight so the agent isn't left waiting, and reconnect on demand.
    private func disconnected(_ fd: Int32) {
        lock.lock()
        guard fd >= 0, upstream == fd else { lock.unlock(); return }
        upstream = -1
        let orphans = Array(pending.values)
        pending.removeAll()
        swallowed.removeAll()
        lock.unlock()
        shutdown(fd, SHUT_RDWR)  // wakes the reader, which closes it
        for request in orphans {
            fail(request.id, method: request.method, "Wink closed before this finished (it may have restarted). Call the tool again; Wink reopens by itself.")
        }
    }

    // MARK: Replies

    private func output(_ data: Data) {
        outputLock.lock()
        defer { outputLock.unlock() }
        if !writeAll(STDOUT_FILENO, data) { exit(0) }
    }

    private func reply(_ id: Any?, _ result: [String: Any]) {
        guard let id else { return }
        output(encode(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    private func replyError(_ id: Any?, _ message: String, code: Int = -32000) {
        guard let id else { return }
        output(encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]))
    }

    /// A tool call fails as a tool result the model can read; anything else as a JSON-RPC error.
    private func fail(_ id: Any, method: String, _ message: String) {
        if method == "tools/call" {
            reply(id, ["content": [["type": "text", "text": message]], "isError": true])
        } else {
            replyError(id, message)
        }
    }

    // MARK: Handshake file

    static func handshake() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: handshakeFile),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["serverInfo"] != nil, object["tools"] != nil else { return nil }
        return object
    }

    static func initializeResult(_ handshake: [String: Any], requested: String?) -> [String: Any] {
        let supported = handshake["protocolVersions"] as? [String] ?? ["2025-06-18"]
        let version = requested.flatMap { supported.contains($0) ? $0 : nil } ?? supported[0]
        var result: [String: Any] = [
            "protocolVersion": version,
            "capabilities": handshake["capabilities"] ?? ["tools": ["listChanged": false]],
            "serverInfo": handshake["serverInfo"]!,
        ]
        if let instructions = handshake["instructions"] { result["instructions"] = instructions }
        return result
    }
}

signal(SIGPIPE, SIG_IGN)
Bridge().run()
