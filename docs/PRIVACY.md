# Privacy in Wink

Wink sends nothing about you anywhere: no telemetry, crash reporting, or usage metrics, and no account. Everything below is on by default.

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

## Agents

Agents only see what you allow. See [Agents](AGENTS.md#consent-and-visibility) for the full consent model: own tabs only, isolated profile, protected sites, hidden sensitive fields, and an always-visible Stop.
