// wink-mcp — stdio bridge between an MCP client (Claude Code, Claude Desktop,
// any agent) and the Wink browser.
//
//   claude mcp add wink -- /Applications/Wink.app/Contents/MacOS/wink-mcp
//
// The MCP server itself lives inside Wink and listens on a Unix domain socket
// that only the current user can reach (0700 directory, peer-uid checked).
// This process just relays newline-delimited JSON-RPC in both directions,
// launching Wink first if it is not running. It never opens a network port.

import Darwin
import Foundation

// The bridge lives in Wink.app/Contents/MacOS, so Foundation resolves the
// enclosing app as the main bundle. Talking to (and launching) that exact copy
// keeps a side-by-side dev build separate from the installed one.
let bundleIdentifier = Bundle.main.bundleIdentifier ?? "app.wink.browser"
let appBundlePath: String? = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.path : nil

func fail(_ message: String) -> Never {
    var text = "wink-mcp: \(message)\n"
    text.withUTF8 { buffer in _ = Darwin.write(STDERR_FILENO, buffer.baseAddress, buffer.count) }
    exit(1)
}

func socketPath() -> String {
    if let override = getenv("WINK_MCP_SOCKET") { return String(cString: override) }
    guard let home = getenv("HOME") else { fail("HOME is not set") }
    let folder = bundleIdentifier == "app.wink.browser" ? "Wink" : bundleIdentifier
    return String(cString: home) + "/Library/Application Support/\(folder)/run/mcp.sock"
}

func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxLength else { close(fd); fail("socket path too long: \(path)") }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { strncpy($0, path, maxLength) }
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result != 0 { close(fd); return nil }
    return fd
}

func launchWink() {
    // `open -g` launches in the background without stealing focus.
    var pid: pid_t = 0
    let args = appBundlePath.map { ["/usr/bin/open", "-g", $0] } ?? ["/usr/bin/open", "-g", "-b", bundleIdentifier]
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

func jsonEscape(_ value: String) -> String {
    var out = ""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
        }
    }
    return out
}

func writeAll(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let n = Darwin.write(fd, pointer + offset, count - offset)
        if n < 0 { if errno == EINTR { continue }; return false }
        offset += n
    }
    return true
}

func pump(from source: Int32, to destination: Int32) -> Bool {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
        if n == 0 { return true }
        if n < 0 { if errno == EINTR { continue }; return false }
        let ok = buffer.withUnsafeBytes { writeAll(destination, $0.baseAddress!, n) }
        if !ok { return false }
    }
}

// --- main -----------------------------------------------------------------

signal(SIGPIPE, SIG_IGN)
let path = socketPath()
var fd = connectSocket(path)
if fd == nil {
    launchWink()
    let deadline = Date.now + 20
    while fd == nil && Date.now < deadline {
        usleep(150_000)
        fd = connectSocket(path)
    }
}
guard let connection = fd else { fail("could not reach Wink at \(path). Is Wink installed?") }

// Identify ourselves before relaying. The token is set when Wink itself
// launched the agent (pre-authorized session); external agents have none and
// the user is asked to approve them in Wink.
let token = getenv("WINK_AGENT_TOKEN").map { String(cString: $0) } ?? ""
let hello = "{\"wink_bridge\":1,\"pid\":\(getpid()),\"parent\":\"\(jsonEscape(parentProcessPath()))\",\"token\":\"\(jsonEscape(token))\"}\n"
_ = hello.utf8CString.withUnsafeBufferPointer { writeAll(connection, $0.baseAddress!, $0.count - 1) }

let socketToStdout = Thread {
    _ = pump(from: connection, to: STDOUT_FILENO)
    exit(0)  // Wink closed the session.
}
socketToStdout.start()
_ = pump(from: STDIN_FILENO, to: connection)
shutdown(connection, SHUT_WR)  // client finished; let Wink flush responses
Thread.sleep(forTimeInterval: 2)
exit(0)
