# Wink architecture

```
┌──────────────────────────── Wink.app (browser process) ────────────────────────────┐
│  Swift: AppKit + SwiftUI                                                           │
│  ┌────────────┐ ┌──────────────┐ ┌───────────────┐ ┌────────────────────────────┐  │
│  │ Windows,   │ │ Command bar, │ │ Agent panel   │ │ AgentHub: consent, tab     │  │
│  │ tabs,      │ │ sidebar,     │ │ Claude API /  │ │ access, activity, Stop     │  │
│  │ session    │ │ overlays     │ │ Claude Code   │ ├────────────────────────────┤  │
│  └─────┬──────┘ └──────────────┘ └──────┬────────┘ │ BrowserTools (37 tools)    │  │
│        │                                │          │ CDPSession → isolated world│  │
│        │                                │          ├────────────────────────────┤  │
│        │                                │          │ MCP server (unix socket)   │◄─┼── wink-mcp ◄── Claude Code,
│        ▼                                ▼          └─────────────┬──────────────┘  │    Claude Desktop, any MCP client
│  WinkEngine (Objective-C++): WinkRuntime · WinkWebView · WinkProfile · ContentBlocker
│        │  pure-ObjC headers; no C++ or CEF types reach Swift                       │
│        ▼                                                                           │
│  Chromium Embedded Framework 156 (Chromium 156.0.8078.88)                          │
└────────────────────────────────────────────────────────────────────────────────────┘
        │ spawns, sandboxed (seatbelt)
        ▼
  Wink Helper (Renderer) · (GPU) · network / storage utilities — Helper/helper_main.mm
```

## Why CEF + a native shell

Wink embeds Chromium through CEF (the Chromium Embedded Framework) instead of forking Chromium's UI:

- **Real Chromium.** Blink, V8, Chromium's network stack, site isolation and the multi-process sandbox are unchanged. Sites behave as they do in Chrome, and Wink presents a standard Chrome user agent.
- **Native UI.** The browser chrome is AppKit and SwiftUI, not a web UI or Chromium's Views toolkit. It's cheap to render and feels like a Mac app.
- **Buildable anywhere.** The engine is a pinned, checksum-verified binary (`engine.lock`, `make bootstrap`). A Chromium fork needs about 100 GB of checkout and hours per build.
- **With the codecs sites expect.** Official CEF builds leave out H.264, AAC and HEVC, so Instagram, X and most video wouldn't play. On Apple silicon Wink uses CEF built from source with `proprietary_codecs=true ffmpeg_branding=Chrome`, at exactly the version in `engine.lock`. It comes from the public GitHub Actions workflow `cef-codecs.yml` of [dpfaffenbauer/OpenArch](https://github.com/dpfaffenbauer/OpenArch) (MIT), which builds CEF's and Chromium's own sources with only CEF's patches on GitHub-hosted runners. The archive is mirrored as a release of this repository (`engine-<version>-codecs`) and pinned by SHA-256. Before it was adopted, its headers, wrapper sources and file list were compared with the official distribution of the same version. They matched except for formatting. H.264, HEVC and AAC are patent-licensed. Chromium-based browsers ship them, but review the AVC, HEVC and AAC pool terms before Wink ships at scale.
- **Swappable.** Swift only sees the Objective-C facade in `Engine/include/WinkEngine`. Moving to a source-built CEF, or to a full Chromium fork, changes `Engine/` but not the app.

CEF browsers embedded in a native view use CEF's lightweight *Alloy* runtime style. Wink provides its own UI for tabs, dialogs, permissions, and popups.

## Layout

| Path | What |
|---|---|
| `Engine/` | Objective-C++ bridge over CEF: runtime/init (`WinkRuntime.mm`), the per-tab browser view and its CEF client (`WinkWebView.mm`), profiles (`WinkProfile.mm`), network privacy core (`content_blocker.cc`, pure C++) |
| `Helper/` | Entry point for every Chromium child process (sandboxed). Injects `navigator.globalPrivacyControl`. |
| `App/Browser/` | Tab model (each tab is its Chromium view's delegate), window state and controller |
| `App/UI/` | Root layout, sidebar, content card + overlays, agent visuals (aurora glow, cursor, page effects), Winky's prompt bar over the page (`WinkyBar.swift`) and welcome (`Welcome.swift`), command bar, menus, settings |
| `App/Agent/` | `AgentHub` (consent, activity, pause/take-over, Stop), `Guardrails`, `BrowserTools`, `CDPSession`, `PageScripts` (JS), `MCPServer`, `ClaudeAPIEngine`, `ClaudeCodeEngine`, agent panel |
| `App/Services/` | History (SQLite), favicons, downloads, sessions, tab sleeping, content-blocker settings sync, updates through Sparkle with the anonymous counts (`Updates.swift`), importing logins, history and bookmarks from other browsers (`BrowserImport.swift`) |
| `Bridge/` | `wink-mcp`: stdio ⇄ unix-socket relay for MCP clients; answers the handshake while Wink is closed, opens Wink on the first tool call, reconnects after a restart |
| `Resources/` | Info.plists, app icon and the cut-out eye (both built from `Brand/wink-eye.jpg` by `make icon`), blocklist (+ NOTICE) |
| `scripts/` | `bootstrap.sh`, `bundle.sh` (assemble + sign), `release.sh` (Developer ID + notarization + DMG), `update_blocklist.py`, `make_icon.swift` |
| `Tests/` | C++ unit tests for the content blocker; `agent_e2e.py`, the end-to-end agent suite CI runs against a headless Wink |

## Key flows

**Tabs.** A `Tab` owns at most one `WinkWebView`. Live tabs stay in the content card as hidden views, so switching is instant; Chromium treats hidden views as backgrounded and throttles them. `TabSleeper` discards views that have been idle for a configurable time (default 30 minutes). It skips tabs that are playing audio, capturing camera or mic, or in use by an agent. A sleeping tab reloads when you select it.

**Closing.** Tab close goes through Chromium (`CloseBrowser(false)`) so `beforeunload` works. `DoClose` returns true and Wink completes the close by tearing down the view. Quit force-closes every browser, waits for `OnBeforeClose`, then shuts Chromium down, with a 3-second ceiling.

**Popups.** `OnBeforePopup` asks the window for a new tab and parents the popup's browser in it, so `window.opener` survives and OAuth sign-in windows work. Popups without a user gesture are blocked.

**Agents → page.** Tools speak the Chrome DevTools Protocol through `CefBrowserHost::SendDevToolsMessage`, which is in-process with no port. Page scripts run in a private isolated world, so the page can't observe or tamper with them, and are installed once per document. Input uses CDP `Input.*` events, which pages see as trusted.

Each action runs one path, `BrowserTools.act`:

1. Wait while paused.
2. Run the guardrail check.
3. Glide the cursor to the target.
4. Start a MutationObserver.
5. Dispatch the input.
6. Settle: poll mutation counts from Swift until quiet, or wait for the load if the action navigated.
7. Summarize what changed for the agent.

**Agent visuals.** `AuroraGlowView` is two conic gradients rotating under a static mask, which is a signed-distance falloff from the card's edge computed off the main thread. The inner half sits in the card; the outer half sits behind it and spills onto the window. `AgentOverlayView` draws the eye cursor, outlines, ripples and captions as plain CALayers. The eye is `Resources/WinkEye.png`, which `make icon` cuts from the logo artwork with an alpha matte keyed off the mustard paper. All motion runs in the render server.

## Build system

CMake + Ninja. Objective-C++ (`.mm`) compiles as CXX with CEF's flags (`-fno-rtti -fno-exceptions -std=c++20`); ARC is enabled for Wink's `.mm` files. Swift builds in whole-module mode. `scripts/bundle.sh` assembles `Wink.app`:

- the versioned CEF framework (re-copied only when the engine version changes)
- five helper app bundles
- `wink-mcp`
- resources

It then signs everything inside-out: ad-hoc for development. With `WINK_SIGN_IDENTITY` set to a Developer ID, it uses the hardened runtime, a secure timestamp and per-process entitlements from `Resources/Entitlements/`. Chromium's renderer and GPU helpers JIT-compile code, so they need `allow-jit`. See [Releasing](RELEASING.md).

If a Command Line Tools upgrade left a stale `usr/include/swift/module.modulemap` behind, Swift fails with *redefinition of module 'SwiftBridging'*. CMake detects this and hides the stale file with a VFS overlay rather than modifying the system. You can also delete the file yourself:

```sh
sudo rm /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
```

Dev builds pass Chromium `--use-mock-keychain` (`WINK_DEV_MOCK_KEYCHAIN=ON`), because ad-hoc signatures change on every build and would trigger a Keychain prompt each launch. Release builds should turn this off so cookies are encrypted with Wink's own Keychain item.

## Measured (Apple M3, 16 GB)

| | |
|---|---|
| Launch to ready (Chromium init + window + session restore) | ~265 ms |
| Footprint, 1 GitHub tab (6 processes) | ~390 MB |
| 5 tabs → background tabs asleep | 858 MB → 421 MB |
| Blocklist: 93k domains | ~3 MB, ~1 µs/lookup, allocation-free on the IO thread |
| Agent `find` / `screenshot` / `click` + settle + change report | ~10 ms / ~50 ms / ~0.5–0.7 s |
| Claude Code: 4 LinkedIn-style connection requests | 6 browser calls, 28 s, $0.17 |

## Development hooks

`WINK_DEBUG_DIR=<dir>` enables a dev-only driver (`App/Core/DebugDriver.swift`):

- `kill -USR1` writes window snapshots, rendering offscreen when the display sleeps.
- `kill -USR2` runs commands from `<dir>/commands.txt`: `open`, `query`, `ask`, `accept`, `deny`, `stop-agents`, `pause-agent`, `takeover`, `limit`, `confirm-mode`, `expand-log`, `minimize-pill`, `sleep-now`, `state`, …

To test next to your everyday Wink, build a separate copy and run it invisibly:

```sh
make BUILD_DIR=build-dev CMAKE_FLAGS=-DWINK_BUNDLE_ID=app.wink.browser.dev
WINK_HOME=/tmp/wink-test WINK_MCP_SOCKET=/tmp/wink-test.sock WINK_DEBUG_DIR=/tmp/wink-dbg WINK_DEBUG_HEADLESS=1 \
  build-dev/Wink.app/Contents/MacOS/Wink
```

- **Separate identity.** Another bundle id gets its own preferences and data folder.
- **Separate data and socket.** `WINK_HOME` and `WINK_MCP_SOCKET` move the profile and the agent socket. Socket paths must stay under 104 bytes.
- **Invisible.** `WINK_DEBUG_HEADLESS=1` keeps the instance out of the Dock, never activates it, and makes its windows transparent and click-through.

`ANTHROPIC_BASE_URL` points the built-in agent at a proxy or a local mock.

## Roadmap

1. **Engine.** Widevine for DRM streaming (needs VMP signing through castLabs EVS and Google's approval), and building the codecs engine in Wink's own CI instead of mirroring another project's build. Wink branding in Chromium's strings.
2. **Fingerprinting defenses** that need Blink patches (canvas/audio/font farbling), and cosmetic filtering.
3. **Distribution.** Delta updates (Sparkle's `BinaryDelta`), so an update doesn't download the whole engine again.
4. **Agents.** Per-site agent permissions UI, an activity timeline view, agent tabs that render in a live picture-in-picture, MCP resources (tab contents) and notifications, compaction for long built-in conversations.
5. **Browser.** Extensions, password manager (Keychain-backed), bookmarks/spaces, tab groups, Windows/Linux shells.
