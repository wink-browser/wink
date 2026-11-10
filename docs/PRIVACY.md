# Privacy in Wink

Wink sends nothing about your browsing anywhere: no history, no crash reports, no account. Once a day it checks for updates. Unless you switch it off, that check carries a few anonymous usage counts, described under [Updates and anonymous counts](#updates-and-anonymous-counts). Everything below is on by default.

## Network protections (engine, `Engine/src/content_blocker.cc`)

These run on Chromium's IO thread for every request in the browser process.

- **Tracker and ad blocking.** Third-party requests to about 93,000 known tracker and ad domains are cancelled. The list is derived from EasyPrivacy and EasyList (CC BY-SA 3.0; see `Resources/blocklist/NOTICE`). First-party requests and top-level navigations are never blocked, which keeps breakage low. You can turn protections off per site from the shield in the address pill. Service-worker and prefetch requests, which have no tab, are filtered too.
- **HTTPS upgrades.** Typed or linked `http://` navigations are upgraded to `https://`. If the secure version fails, Wink falls back to `http` for that host and marks the address pill "Not secure". Local and intranet hosts are left alone.
- **Global Privacy Control.** Wink sends `Sec-GPC: 1` and exposes `navigator.globalPrivacyControl === true`. GPC is a legally recognized opt-out of data sale and sharing in several US states.
- **Third-party cookies** are blocked (Chromium `profile.cookie_controls_mode = 1`).
- **WebRTC** never exposes your local IP address (`default_public_interface_only`).
- **Privacy Sandbox ad APIs are off:** Topics, Protected Audience/FLEDGE, Attribution Reporting, Shared Storage, and Private Aggregation.
- **No background calls.** Component updates, domain reliability reports, optimization hints, network-time queries, hyperlink-auditing pings, and Cast discovery are all disabled.
- **Blending in.** Wink sends the standard Chrome user agent and client hints, so it's not a rare, fingerprintable browser.

## Platform

- Chromium's multi-process **sandbox** is on: renderer, GPU and utility processes run under macOS seatbelt profiles.
- **No remote debugging.** The DevTools port is off, and Chromium ignores command-line switches, so a relaunch with `--remote-debugging-port` can't be used to steal sessions. Agents talk to pages in-process.
- **At rest.** Data lives in `~/Library/Application Support/Wink` (owner-only, `0700`). Cookies are encrypted with Wink's own Keychain item, "Wink Safe Storage" (see the dev-build note in ARCHITECTURE). The Anthropic API key is stored in the Keychain.
- **Site permissions.** Camera, microphone, location, notifications, clipboard, MIDI, local-network and storage-access requests prompt every time; answers last for the session. Every other permission type is denied without asking. Popups need a user gesture.

## Your data

- **History** is local (SQLite) and kept for 90 days by default; the retention period is configurable. Private windows and agent tabs never write history.
- **Private windows** use an in-memory profile that disappears when the window closes. Agents can't see private tabs.
- **Forget This Site** (shield popover) deletes a site's cookies, storage, cache, and history.
- **Clear Browsing Data** (⇧⌘⌫) removes cookies, cache, auth, history, favicons, and site storage. Storage for sites that aren't open is removed at next launch.
- **Search suggestions** are off by default, because they would send every keystroke to your search engine. The default search engine is DuckDuckGo.

## Updates and anonymous counts

Release builds ask `wink.minnebo.ai` for the newest version once a day (Sparkle, `App/Services/Updates.swift`), and update themselves. An update downloads in the background and installs when you quit. It's only accepted if it carries Wink's EdDSA signature, which is checked before anything is unpacked, and Apple's Developer ID signature for the same team. The request contains:

- **Always:** Wink's version and the macOS version (major.minor).
- **With "Share anonymous usage counts" on** (the default; Settings › Privacy or the welcome screen), on the first check of each UTC day only: whether this is the first check today, this week, this month and ever, plus the week Wink was installed. Those flags let the team count daily, weekly and monthly users, new installs and retention, without identifying anyone.

What it never contains: an identifier, a cookie, your history, your profile, or anything about the pages you visit.

Sparkle's own system profile is off. On the server, the check only increments counters per day, week and month. The country is derived from the request in aggregate, and IP addresses are not stored. Turn off **Update Wink automatically** to send nothing at all (Wink › Check for Updates… still works when you ask). Dev builds never check.

The website works the same way. It sets no cookies and runs no scripts; it counts page views and download clicks per day (and country), without identifying visitors.

## Importing from another browser

File › Import from Another Browser… (also offered in the welcome) brings logins, history and bookmarks over from Chrome, Arc, Brave, Edge or Vivaldi on the same Mac (`App/Services/BrowserImport.swift`). Nothing is uploaded, and nothing goes through a server:

- Wink reads private copies of the other browser's files, then deletes the copies.
- **Logins** are that browser's cookies, encrypted with its own "… Safe Storage" key in your Keychain. macOS asks before Wink can read the key; if you don't allow it, logins are skipped. Decrypted values only exist in memory, on their way into Wink's cookie store, which encrypts them again with Wink's own key.
- Partitioned (third-party) cookies, expired cookies, and cookies whose own host is on Wink's tracker list stay behind.
- **History** brings the pages from your history retention period (90 days by default). **Bookmarks** become searchable from the command bar. Neither is synced anywhere.

## Your profile

Your name and optional photo stay on this Mac, in Wink's preferences and its private `State` folder. There is no account. Winky uses your first name in chats, so it is included in what you send to the AI model when you talk to her.

## Agents

If Claude Code is installed, Wink adds itself to Claude Code's MCP servers when it launches. It runs `claude mcp add --scope user wink`, which writes one entry to Claude Code's config. It reads Claude Code's config only to check that entry. Turn it off in Settings › Agents, or remove it with `claude mcp remove wink`, and Wink never adds it back. This sends nothing anywhere. An agent still can't browse until you allow it in Wink.

Agents only see what you allow.

While an agent uses a tab, Wink keeps the details of that tab's network requests (headers and bodies, up to 400 requests) in memory so the agent can debug with them. Cookie and authorization headers are never shown, and nothing is written to disk or sent anywhere. Agents can attach files to pages only with your OK (except on localhost), and never from hidden folders, `~/Library` or system folders. Agents see cookie and storage values only on localhost; elsewhere they see names, and changing or clearing them needs your OK. PDFs and recordings an agent makes are saved in your Downloads folder and nowhere else. See [Agents](AGENTS.md#consent-and-visibility) for the full consent model: own tabs only, isolated profile, protected sites, hidden sensitive fields, and an always-visible Stop.
