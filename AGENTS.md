# Contributor guide (people and coding agents)

Portside is a native macOS dock replacement in Swift (SwiftUI and AppKit), built with SwiftPM. Read [CONTRIBUTING.md](CONTRIBUTING.md) first; this file adds the working rules for agents and the end-of-task checklist.

## Layout

- Sources in `Sources/portside/`, one executable target `portside`. Layout tree and private-API notes: `docs/ARCHITECTURE.md`.
- Design and milestones: `docs/PLAN.md`. Status and backlog: `docs/CHECKLIST.md`. Settings file format: `docs/DATA.md`.

## Rules

1. **SwiftPM only.** Never hand-write an `.xcodeproj` or `project.pbxproj`.
2. **Build and run.** `source scripts/swift-env.sh`, then `swift build` after each batch of changes, reading the real output, `CFFIXED_USER_HOME=/tmp/portside-tests swift test` when a covered contract changes, and `swift run portside` to catch launch crashes. A clean build is not proof it works. Never run two SwiftPM commands against `.build` in parallel; they serialize on a lock and look hung.
3. **If you repeat an action twice with the same result, stop and rethink.**
4. **Responsiveness is the point.** No polling timers in the reveal/hide path. Allowed: one cancelable hide-delay timer, widget refresh, running-app cache refresh. Reveal starts within about one frame of the cursor touching the edge; the first click works without stealing focus.
5. **Public APIs by default.** A private API goes in its own file behind `dlopen`/`dlsym` with a graceful fallback, and gets a line in the Notes section of `docs/ARCHITECTURE.md`.
6. **Native Dock settings.** Only the "Hide the macOS Dock" feature changes `com.apple.dock`, and it saves the exact prior values and restores them on quit. Do not change those settings while testing; use the left or right edge instead.
7. **Never touch other apps' preferences or `/Applications`.** Use `CFFIXED_USER_HOME=/tmp/somewhere` to keep test runs away from your real settings and logs.
8. **No secrets in the repo or logs.** Tokens are never logged or written to disk.
9. **No em dashes in docs or comments.** Match the surrounding comment density and naming.

Hover and click behavior needs a person. Build and launch, then say exactly what you could and could not check by hand.

## Git

`main` is protected. Work on a feature branch and open a pull request; do not push to `main`. Do not commit or push unless the maintainer asks.

## Definition of done

1. Update `docs/CHECKLIST.md`: finished items, new findings, deferred items, known gaps.
2. Update the short "Features" and "Planned" sections of `README.md` and the detail in `docs/FEATURES.md`. Move an item from Planned to Features only when it is built and working. Never list a feature that is not in the code.
3. If you added a Swift file, add it to the layout tree in `docs/ARCHITECTURE.md` with a one-line description, and `git add` it.
4. If `dock.json` gained keys or settings changed, update `docs/DATA.md`.
5. Final report, in order: what changed, what to hand test (short numbered list), new untracked files, known gaps.

## Agent skills

### Issue tracker

Use GitHub Issues in `jameszangari/portside`. See [issue-tracker.md](docs/agents/issue-tracker.md).

### Triage labels

Use the default triage labels. See [triage-labels.md](docs/agents/triage-labels.md).

### Domain docs

Single-app repository using the existing domain docs. See [domain.md](docs/agents/domain.md).
