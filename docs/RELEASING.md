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

## Publish

Releases are public downloads on [wink-browser/releases](https://github.com/wink-browser/releases), which holds no source. Attach the DMG as `Wink.dmg`, so the website's link to the latest release keeps working:

```sh
v=0.2.0
cp build-release/dist/Wink-$v.dmg Wink.dmg && shasum -a 256 Wink.dmg > Wink.dmg.sha256
gh release create v$v --repo wink-browser/releases --title "Wink $v" --notes-file notes.md Wink.dmg Wink.dmg.sha256
```

Then tell installed copies about it. The website ([wink.minnebo.ai](https://wink.minnebo.ai), repository `wink-browser/website`, hosted on Vercel) serves `latest.json`, which Wink's daily update check reads. Bump its `version`, commit, and deploy with `vercel deploy --prod`. The Download button needs no change: it always points at `releases/latest/download/Wink.dmg`.

## Updating the engine

`engine.lock` pins CEF. On Apple silicon it is a build with proprietary codecs (see [Architecture](ARCHITECTURE.md#why-cef--a-native-shell)), so a new CEF version takes three steps:

1. Get a codecs build of exactly that version from a source you've vetted: a run of a public build workflow whose script you've read, or your own build.
2. Check it against the official distribution of the same version. `include/` and `libcef_dll/` must match apart from formatting, and so must the `Release/` file list.
3. Mirror it as a release of this repository, then update `CEF_VERSION`, `CHROMIUM_VERSION`, `ENGINE_RELEASE` and `CEF_SHA256_MACOSARM64` together:

   ```sh
   gh release create engine-<version>-codecs --repo wink-browser/wink --latest=false cef_binary_*.tar.bz2 cef_binary_*.tar.bz2.sha256
   ```

`make bootstrap` then fetches it with `gh` and verifies the SHA-256.

## Before shipping

- **Launch the signed app.** Hardened-runtime problems show up as helper processes failing to start: blank pages or a crashed renderer.
- **First launch changes cookie encryption.** A release build encrypts cookies with the real Keychain item ("Wink Safe Storage"), not the dev mock keychain, so the first switch from a dev build signs you out of websites once.
- **Check the download.** Fetch the DMG from the public link and run `shasum -a 256 -c Wink.dmg.sha256` and `spctl -a -t open --context context:primary-signature -vv Wink.dmg`.
