# Build and release

## Requirements

- macOS 26 or later (`Package.swift` targets `.macOS("26.0")`). Developed on macOS 27 with Xcode 27 on Apple Silicon.
- Swift toolchain with `swift-tools-version` 5.10 support (Xcode command line tools are enough).

## Quick develop

Faster SPM builds on Xcode 26/27: turn off Explicitly Built Modules (large planning/PCM overhead on clean debug for this package). `scripts/build-app.sh` does this already; for plain `swift build` / `swift run`:

```
source scripts/swift-env.sh   # once per shell; sets SWIFT_ENABLE_EXPLICIT_MODULES=NO
swift build
swift run portside
CFFIXED_USER_HOME=/tmp/portside-tests swift test   # keeps tests away from your dock.json
```

Measured on an M4 Max with Xcode 27.2: clean debug ~27s default vs ~9s with that env; incremental stays ~1 to 3s either way. Release compile is ~19s either way. If `.build` grows past several hundred MB (SDK PCM cache), `swift package clean` resets it. Do not run two SwiftPM builds in this repo at once; they wait on one `.build` lock.

Use `swift run` for launch smoke tests only. Quit it afterward and open the signed app with `open build/Portside.app` for Calendar testing and daily use. macOS can attribute a bare executable's Calendar request to its terminal instead of Portside.

Restore the native Dock from the backup without starting the app:

```
swift run portside --restore-dock
```

View logs while it runs:

```
log stream --level info --predicate 'subsystem == "com.james.portside"'
```

## Contributor build

You do not need a signing identity or Apple Developer account to build a `.app`:

```
SIGN_IDENTITY=- scripts/build-app.sh   # ad hoc signed build/Portside.app
open build/Portside.app
```

Ad hoc builds make macOS ask for permissions again whenever the binary changes. `swift build` and `swift run portside` need no signing at all. The release scripts below are for the maintainer.

## Build the app

```
scripts/setup-signing.sh           # once: local cert for day-to-day ~/Applications installs
scripts/setup-notary.sh            # once: Apple notarytool keychain profile (Developer ID releases)
scripts/build-app.sh               # builds build/Portside.app (local cert)
scripts/build-app.sh --install     # also copies it to ~/Applications/Portside.app
scripts/build-app.sh --package     # also writes build/dist/Portside-X.Y.Z.dmg
scripts/build-app.sh --notarize    # Developer ID sign + notary + staple + .dmg (for GitHub)
open build/Portside.app
```

- Runs `swift build -c release`, then assembles `Contents/MacOS/portside`, `Contents/Info.plist` (from the repo's `Info.plist` plus bundle keys and the version from `VERSION`), the app icon, and the SwiftPM resource bundle with the brand PNGs (in `Contents/Resources`, covered by the signature). The icon is `design/icon-composer/AppIcon.icon` compiled by `xcrun actool` into `Assets.car` (Liquid Glass, `CFBundleIconName`) plus a flat `AppIcon.icns` fallback. If actool fails it prints why and copies `design/approved-icon/icns/` instead; if that is missing too, the hidden `portside --export-icon <path.png>` flag renders one.
- Default signing uses the local Portside cert (no network). `--notarize` uses your **Developer ID Application** identity with Hardened Runtime (`Portside.entitlements`), submits via `notarytool` profile `portside-notary`, staples the ticket, then builds the DMG, signs it, notarizes and staples it too. Needs network and `scripts/setup-notary.sh` once.
- `--package` builds `build/dist/Portside-X.Y.Z.dmg` with `scripts/make-dmg.sh`: a drag-to-install window with `Portside.app` on top, an orange arrow, and an `Applications` shortcut in a drop zone, plus the sail volume icon. The script drives Finder to save the layout, so the first run asks to let your terminal control Finder (Automation). It then mounts the DMG and re-verifies the app signature. Release publishes use the notarized DMG from `--notarize`.
- Every run also refreshes `Portside.app` at the repo root (gitignored) with the build it just made, swapped in by rename. After `--notarize` (and so after `publish-release.sh`) it is the stapled release app.
- `--install` copies to `~/Applications/Portside.app`, never `/Applications`. It refuses while that copy is running; quit Portside first. Without the flag nothing is installed.
- Run `scripts/setup-signing.sh` once. It creates a ten-year self-signed `Portside Local Development` certificate in your default user keychain and trusts it for code signing only. Only `/usr/bin/codesign` is granted access to the imported private key. `scripts/build-app.sh` (and setup) call `scripts/ensure-codesign-key-access.sh` before signing: a native alert (Okay / Not Now) may appear once, then the system Touch ID or password sheet. No custom password field and no sudo. Later builds reuse the identity silently. The certificate fingerprint is saved outside the repo; temporary key files are deleted on exit.
- Builds use the saved fingerprint by default and fail if it is missing or unavailable, instead of silently switching identities. Setup also validates an existing fingerprint before looking up certificates by name and never replaces it automatically. `SIGN_IDENTITY="Your Cert Name" scripts/build-app.sh` overrides it. `SIGN_IDENTITY=- scripts/build-app.sh` explicitly uses ad-hoc signing, which may cause macOS to ask for permission again when the binary changes.
- When switching from an ad-hoc build, allow Downloads and other requested permissions once for the newly signed app. Use the installed `~/Applications/Portside.app` for permission checks. `swift run` remains a separate development launch and does not use the local certificate.
- Turn on "Open Portside at login" from the copy you keep (normally `~/Applications/Portside.app`). macOS remembers the path it was registered from.
- `swift build` and `swift run portside` are unchanged and still work for development.

Restore the native Dock from the bundle's binary:

```
build/Portside.app/Contents/MacOS/portside --restore-dock
~/Applications/Portside.app/Contents/MacOS/portside --restore-dock
```

## Versioning and releases

- `VERSION` at the repo root is the single source of truth. Edit the version only there (or let the release script do it).
- `scripts/gen-version.sh` writes `Sources/portside/BuildInfo.swift` (generated, committed) with the version, short git hash, and dirty flag. Run it to refresh the hash before a build.
- Start a release from an up-to-date `main` with `scripts/release.sh patch|minor|major`. It is a dry run by default; add `--apply` to make a `release/vX.Y.Z` branch with one "Release vX.Y.Z" commit (`VERSION` and `BuildInfo.swift`), push it, and open a pull request. `main` is protected, so the bump goes through a PR.
- After merging that PR, run `git pull` and `scripts/publish-release.sh --apply`. It tags the merged commit, builds and notarizes from it, pushes only the tag, and creates (or updates) the GitHub release for `vX.Y.Z` with the stapled `Portside-X.Y.Z.dmg`. Dry run by default. Requires `gh` auth and local `main` level with `origin/main`. Rerun it if a build fails.
- Tags use the `vX.Y.Z` format. Check for Updates compares the latest release tag against this version and, from an installed `.app`, downloads `Portside-X.Y.Z.dmg` and replaces the bundle in place.
- The GitHub repo is public, so update checks and downloads are unauthenticated. The expected visibility is one word at [`docs/github-visibility`](github-visibility). `scripts/check-repo-visibility.sh` compares it to live `gh repo view` (one API call, no polling) and runs in every `publish-release.sh` dry run and `--apply`, so publishing fails if the repo is flipped back to private.

### How an update replaces the app

- The new `Portside.app` is copied from the DMG into a hidden `.portside-update-<id>` folder next to the installed app (same volume), then checked: bundle id `com.james.portside`, the expected version, and a valid signature from Developer ID team `WNZ8H4UHQE`. Anything else is refused before the installed app is touched.
- A helper waits for Portside to quit (up to 60s, else it cancels; the app dismisses the update sheet first, since a sheet blocks quitting), renames the installed app aside, renames the new one into place, and deletes the old one. If the second rename fails, the old app is put back. The path never changes, so Open at Login keeps pointing at the right copy.
- The folder must be writable (`~/Applications` is; `/Applications` may not be for a standard user); otherwise the update stops before downloading.
- Settings > General > Updates lists any other Portside.app copies with their versions (Show in Finder, Move to Trash), since Open at Login or Spotlight can launch a stale one.
- Hidden test commands (no UI): `portside --install-update <dmg> [--expect-version X.Y.Z] [--no-relaunch]` runs the same stage, verify, and swap path from a local DMG against the bundle the binary lives in. `portside --resave-settings` loads and saves dock.json through the normal path. `portside --check-updates` prints the result of a real update check. Run them with `CFFIXED_USER_HOME=/tmp/somewhere` to keep your real preferences and logs out of it. To run `--install-update` against a signed copy, launch it with `open -n --env CFFIXED_USER_HOME=... <app> --args --install-update ...`: started directly from a terminal or another app, macOS App Management refuses the replacement and Portside reports it before downloading. The helper passes `CFFIXED_USER_HOME` on when it reopens the app, so a test run stays isolated. `scripts/build-app.sh` does not regenerate `BuildInfo.swift`: to test an update, set an older `VERSION`, run `scripts/gen-version.sh`, build, and restore both files.
- Window fitting tests: `scripts/window-fit-probe/run.sh` (modes listed in `ProbeObserver.swift`). Launch the dev build with `PORTSIDE_WINDOW_FIT_ONLY=com.james.portside.probe` (plus `CFFIXED_USER_HOME` and `{"autoHide": false}` in that dock.json) so only the probe window is fitted; without it every open app's maximized windows get resized.

## Maintainers

These scripts need the maintainer's Developer ID certificate and notary profile, and are not needed to contribute: `setup-signing.sh`, `setup-notary.sh`, `release.sh`, `publish-release.sh`, `make-dmg.sh` (each has a header comment saying so). `build-app.sh --notarize` also needs them.
