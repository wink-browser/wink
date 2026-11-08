# Releasing Wink

`scripts/release.sh` turns a clean checkout into a downloadable `Wink-<version>.dmg`:

1. Builds a fresh release copy (`build-release/`) with the real Keychain for cookie encryption. Dev builds use Chromium's mock keychain.
2. Signs it inside-out with a Developer ID: hardened runtime, secure timestamp, and per-process entitlements from `Resources/Entitlements/`. Chromium's renderer and GPU helpers JIT-compile code. The browser and its utility helpers need camera, microphone, location and Bluetooth access so macOS can show its permission prompts for websites.
3. Checks that every Mach-O inside is signed with that identity, timestamped, and (for executables) hardened.
4. Notarizes the app with Apple and staples the ticket.
5. Packs the DMG, then signs, notarizes and staples it.
6. Runs a Gatekeeper assessment and writes a SHA-256 next to the DMG.

## One-time setup

- **Certificate.** Install the "Developer ID Application" certificate in the login keychain (`security find-identity -v -p codesigning` lists it).
- **Notary credentials.** Save them once, so no password is ever on a command line. This prompts for an app-specific password from appleid.apple.com:

  ```sh
  xcrun notarytool store-credentials wink-notary --apple-id <Apple ID> --team-id <TEAMID>
  ```

- **Agreements.** The team's agreements at developer.apple.com must be current. Otherwise notarytool fails with *"A required agreement is missing or has expired"*.

## Build a release

```sh
WINK_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" scripts/release.sh
```

The DMG and its `.sha256` land in `build-release/dist/`.

- `WINK_NOTARY_PROFILE` selects another credentials profile (default `wink-notary`).
- `WINK_SKIP_NOTARIZE=1` signs without notarizing, for a quick local check.

The version comes from `project(Wink VERSION …)` in `CMakeLists.txt`.

## Before shipping

- **Launch the signed app.** Hardened-runtime problems show up as helper processes failing to start: blank pages or a crashed renderer.
- **First launch changes cookie encryption.** A release build encrypts cookies with the real Keychain item ("Wink Safe Storage"), not the dev mock keychain, so the first switch from a dev build signs you out of websites once.
- **Update the download button.** Point the website's Download button at the new DMG.
