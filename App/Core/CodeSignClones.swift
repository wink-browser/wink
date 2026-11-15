import AppKit

/// Chromium's code-sign clones, which Wink deletes itself.
///
/// At every launch Chromium copies the whole app (an APFS clone, about 300 MB as `du` counts it) into
/// `/var/folders/…/X/<bundle id>.code_sign_clone/code_sign_clone.XXXXXX`, so the running browser keeps a valid
/// code signature if an update replaces the app on disk (chrome/browser/mac/code_sign_clone_manager.mm).
/// Chromium deletes the copy from a helper process after a clean shutdown, but launches that end any other way
/// (killed, crashed, force-quit test runs) leave theirs behind: by 2026-11-14 one Mac held 346 copies of the dev
/// build and 66 of the release build, 116 GB by `du`.
///
/// So at each launch Wink lists the copies that already exist, before the engine makes this launch's, and
/// deletes them once it knows it is the only Wink with its bundle id. Folder `X` is emptied at boot, so only
/// the copies since the last restart are ever there.
enum CodeSignClones {
    /// The copies left by earlier launches. Call before `WinkRuntime.start`, which makes this launch's copy.
    static func leftovers() -> [URL] {
        guard let folder = folder() else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(isCloneName).map { folder.appendingPathComponent($0, isDirectory: true) }
    }

    /// Deletes `leftovers` in the background, unless another Wink with this bundle id is running (a test run
    /// with its own `WINK_HOME`, say): one of them may be its copy. The next launch on its own deletes them.
    @MainActor
    static func remove(_ leftovers: [URL]) {
        guard !leftovers.isEmpty, let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        guard others.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let removed = leftovers.filter { (try? FileManager.default.removeItem(at: $0)) != nil }.count
            NSLog("[wink] deleted %d code-sign clone(s) left by earlier launches", removed)
        }
    }

    /// `/var/folders/…/X/<bundle id>.code_sign_clone`, found the way Chromium finds it: the sibling of the
    /// user's temporary folder (`T`), not `TMPDIR`, which the environment could point anywhere.
    private static func folder() -> URL? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        let temp = URL(fileURLWithPath: String(cString: buffer), isDirectory: true).resolvingSymlinksInPath()
        guard temp.path.hasPrefix("/private/var/folders/") || temp.path.hasPrefix("/var/folders/") else { return nil }
        return temp.deletingLastPathComponent()
            .appendingPathComponent("X", isDirectory: true)
            .appendingPathComponent("\(bundleID).code_sign_clone", isDirectory: true)
    }

    /// Only Chromium's own folder names: `code_sign_clone.` and the six characters `mkdtemp` chose.
    private static func isCloneName(_ name: String) -> Bool {
        let prefix = "code_sign_clone."
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return suffix.count == 6 && suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }
}
