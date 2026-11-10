# Contributing to Wink

Thanks for helping build Wink. Bug reports, ideas and pull requests are all welcome.

## Before you start

- **Bugs and ideas:** open an issue. Search first; it may already be there.
- **Security problems:** never in public. See [SECURITY.md](SECURITY.md).
- **Bigger changes** (a new agent tool, a change to the consent model, a new dependency): open an issue to talk it through before you write the code.

## Build it

You need macOS 14 or later on Apple silicon, the Command Line Tools (or Xcode), CMake 3.29+ and Ninja:

```sh
brew install cmake ninja
make bootstrap   # downloads the pinned Chromium engine and checks its SHA-256
make             # builds build/Wink.app
make test        # unit tests for the privacy core
```

To try your build next to your everyday Wink without touching its profile, build it under another bundle id: `make BUILD_DIR=build-dev CMAKE_FLAGS=-DWINK_BUNDLE_ID=app.wink.browser.dev`. [Architecture](docs/ARCHITECTURE.md) explains how the code fits together, and [Agents](docs/AGENTS.md) explains the agent tools.

## Pull requests

- Keep each pull request to one change, and explain what it does and why.
- Build and run it. If you touch agent tools, drive them for real through `wink-mcp` (see `Tests/mcp_smoke.py`).
- Changes to what Wink sends over the network, stores, or lets agents do must update [PRIVACY.md](docs/PRIVACY.md) or [AGENTS.md](docs/AGENTS.md) in the same pull request.
- No new telemetry, ever. No new network requests unless the user asked for them.
- CI must pass: it builds Wink, runs the tests and scans for secrets.

### Sign your commits off

Wink uses the [Developer Certificate of Origin](https://developercertificate.org): by adding a `Signed-off-by` line to each commit, you certify that you wrote the change or otherwise have the right to submit it under the project's license. `git commit -s` adds it for you:

```
Signed-off-by: Ada Lovelace <ada@example.com>
```

A check on every pull request makes sure each commit has one. Use your GitHub no-reply address if you'd rather not publish your email.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
