import AppKit
import WinkEngine

// Wink entry point. Order matters:
//   1. load the Chromium framework,
//   2. create the CEF-aware NSApplication subclass,
//   3. initialize Chromium,
//   4. run the native run loop (driven by Chromium's message pump).

let launchStart = Date()

MainActor.assumeIsolated {
    AppDelegate.launchStart = launchStart
    guard WinkRuntime.loadEngineLibrary() else {
        FileHandle.standardError.write("Wink: failed to load the Chromium engine framework.\n".data(using: .utf8)!)
        exit(1)
    }

    let application = WinkApplication.shared as! WinkApplication
    let paths = WinkPaths.shared
    paths.prepare()
    PrivacyActions.performPendingWipe(paths: paths)

    guard WinkRuntime.start(argc: CommandLine.argc,
                            argv: CommandLine.unsafeArgv,
                            configuration: EngineConfiguration.make(paths: paths)) else {
        // Another instance handled the launch (process singleton) or init failed.
        exit(WinkRuntime.exitCode)
    }

    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.terminationHandler = { appDelegate.beginTermination() }
    WinkRuntime.runMessageLoop()
    WinkRuntime.shutdown()
}
exit(0)
