# Security

Wink is a web browser that agents can drive, so its security is the product. Thank you for helping keep it safe.

## Reporting a vulnerability

Report it privately: **[open a security advisory](https://github.com/wink-browser/wink/security/advisories/new)**. Only the maintainers can see it. Please don't open a public issue or pull request for a vulnerability.

Include what you found, how to reproduce it, and what an attacker could do with it. We'll confirm we got it within three working days, keep you posted while we fix it, and credit you in the release notes if you'd like.

## Supported versions

Only the latest release gets security fixes. Wink updates itself, so most people are on it within a day of a release.

## What we most want to hear about

- An agent, or a web page, getting around Wink's consent model: reaching tabs it wasn't given, skipping the "wants to send, buy, delete, connect or upload" prompts, or acting while paused or stopped.
- Anything that lets a web page, another user on the Mac, or the network reach the agent socket (`~/Library/Application Support/Wink/run/mcp.sock`) or the `wink-mcp` bridge.
- Ways to get Wink to accept an update that wasn't signed with its key, or to run code from outside the app bundle.
- Leaks of browsing data, cookies, history or local files: through agents, the importer, file uploads, or the network.
- Escapes from Chromium's sandbox that Wink's configuration makes possible.

Bugs in Chromium itself go to the [Chromium security team](https://www.chromium.org/Home/chromium-security/reporting-security-bugs/); we pick up their fixes when we update the engine.
