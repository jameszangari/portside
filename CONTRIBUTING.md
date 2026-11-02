# Contributing to Portside

Thanks for helping. Portside is a native macOS dock replacement written in Swift (SwiftUI and AppKit).

## Build

SwiftPM only. Do not add an Xcode project.

```
source scripts/swift-env.sh   # faster cold debug builds on Xcode 26/27
swift build
swift run portside
```

You need macOS 26 or later on Apple Silicon and the Xcode command line tools. Do not run two SwiftPM commands in the repo at once; they share one `.build` lock.

To build a `.app` without the maintainer's signing identity, sign ad hoc:

```
SIGN_IDENTITY=- scripts/build-app.sh
open build/Portside.app
```

Ad hoc builds make macOS ask for permissions again whenever the binary changes. The scripts `setup-signing.sh`, `setup-notary.sh`, `release.sh`, `publish-release.sh` and `make-dmg.sh` are for the maintainer's releases; you do not need them. Full details are in [docs/BUILD.md](docs/BUILD.md).

## Ground rules

- **Responsiveness is the point.** No polling timers in the reveal and hide path (allowed: one cancelable hide-delay timer, widget refresh, running-app cache refresh). Reveal should start within about a frame of the cursor touching the edge, and the first click must work without stealing focus.
- **Public APIs by default.** A private API needs its own file, `dlopen`/`dlsym` with a graceful fallback so an OS update degrades instead of crashing, and a note in the Notes section of [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **Do not change `com.apple.dock` settings** except through the existing hide-the-Dock feature, which saves the prior values and restores them.
- **Match the surrounding code:** naming, comment density, idiom. Keep comments short and plain.
- **Verify, do not assume.** Run `swift build` and read the output, and `swift run` to catch launch crashes. Hover and click behavior needs a person; say in the PR what you tried by hand.

## Pull requests

- Fork, branch from `main`, and open a PR. `main` is protected; nothing is pushed to it directly.
- Keep a PR to one change. Describe what changed and how you tested it.
- Update the docs your change touches: `README.md` Features and Planned, `docs/FEATURES.md`, `docs/ARCHITECTURE.md` (layout tree for new files), `docs/DATA.md` (new `dock.json` keys), `docs/CHECKLIST.md`. List a feature only when it is built and working.
- Report security problems privately, see [SECURITY.md](SECURITY.md).

By contributing you agree your work is released under the [MIT License](LICENSE).
