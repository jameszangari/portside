# Portside 2.0 baseline (P2-CORE-01)

Baseline record, test seam, probe inventory and hand-check procedures for Portside 2.0 work. [Roadmap](ROADMAP_2_0.md) · [Tickets](IMPLEMENTATION_PLAN_2_0.md) · [Test matrix](TEST_MATRIX_2_0.md) · [Checklist](CHECKLIST.md)

Later tickets add their own rows to the run record below rather than starting new baseline files.

## Run record

| Field | Value |
| --- | --- |
| Date | 2026-11-06 |
| Commit | `31cd753` on `main`, plus the P2-CORE-01 diff |
| Planning IDs | P2-CORE-01 |
| Environment | macOS 27.0.1 (26A434), Xcode 27.2 (27B52), Apple Swift 6.4.2, Apple M4 Max; one display, no physical interaction |
| Feature flags | None added |

| Row | Steps | Result |
| --- | --- | --- |
| Build | `source scripts/swift-env.sh; swift build`, before and after the change | Pass, no new warnings |
| T-03 settings (automated) | `CFFIXED_USER_HOME=/tmp/<dir> swift test` | Pass, 4 tests. A deliberate break of the unknown-key merge failed 2 of them, then the source was restored |
| T-03 settings (real save path) | Fixture copied to an isolated home as `dock.json`, then `.build/debug/portside --resave-settings` | Pass: exit 0, `futureModules` kept, `pinnedApps` migrated to 3 entries and not written back, `savedByVersion` 1.8.0 |
| Isolated launch | Seeded `dock.json` below, `.build/debug/portside` for 8 seconds, then SIGTERM to that PID only | Pass: alive at 8 s, exit 0. `com.apple.dock` `autohide` (1) and `autohide-delay` (absent) unchanged; no native Dock backup written |
| T-01 reveal / first click | Procedure below | Not run: needs a person |
| T-02 native Dock recovery | Procedure below | Not run: needs a disposable account |
| Reveal latency gate | 100 edge touches, event to animation start | Not run: no signpost or trace exists yet; see gaps |

Seeded launch file (`<home>/Library/Application Support/com.james.portside/dock.json`):

```json
{"edge":"left","entries":[],"hideNativeDock":false,"nativeDockExplained":true,"reserveSpace":false,"autoHide":true,"widgetKinds":[],"showAgentNotch":false,"automaticUpdateChecks":false,"openSettingsOnLaunch":false,"usageProviders":[]}
```

## Test seam

- `Tests/portsideTests` is an XCTest target that depends on the `portside` executable target (`@testable import portside`). No app target or product changed.
- Fixtures live in `Tests/portsideTests/Fixtures` and are read by `Fixture.data(_:)`, located from the source file's path, so no resource bundle is needed.
- Run from the repo root:

  ```
  source scripts/swift-env.sh
  CFFIXED_USER_HOME=/tmp/portside-tests swift test
  ```

  `CFFIXED_USER_HOME` is required: `DockModel` setters persist to `dock.json` under the home folder. Tests decode and encode values and call `DockModel.mergingUnknownKeys` instead of calling setters or `load()`.
- `legacy-flat-pins.json` is a pre-Milestone D file (flat `pinnedApps`, flat background keys, no `autoHide`, an out-of-range `hideDelay`) with one unknown top-level key, `futureModules`. Tests check migration by value, the unknown key surviving a save, migration-only keys not written back, and current values winning over stale ones.

## Probe inventory

Hidden command-line probes in `PortsideApp.swift`. Run each with `CFFIXED_USER_HOME=/tmp/<dir>` unless noted.

| Probe | Build | What it does | Side effects |
| --- | --- | --- | --- |
| `--restore-dock` | all | Restores the native Dock from `native-dock-backup.json`, then exits | Writes `com.apple.dock` only if a backup exists |
| `--resave-settings` | all | Loads and saves `dock.json` through the normal path | Writes `dock.json` |
| `--check-updates` | all | Real update check, prints the result | Network request to GitHub |
| `--install-update <dmg>` | all | Stage, verify and swap from a local DMG (see BUILD.md) | Replaces the bundle the binary lives in |
| `--export-icon <png>` | all | Writes the 1024 px app icon | Writes the given file |
| `--print-usage [provider]` | all | Prints AI usage meters | Reads tokens and contacts providers; avoid unless consented |
| `--install-agent-hooks` / `--remove-agent-hooks` | all | Same as Settings > Widgets > Agent Hooks | Edits `~/.claude` and `~/.codex`; do not run on a daily account |
| `--watch-native-dock <pid>` | all | Internal crash watchdog child | Restores the native Dock when the watched PID exits |
| `--check-notch` | debug | Notch settings, filters and hover/pin lifecycle checks | None outside the process |
| `--render-notch-previews <dir>` | debug | Notch PNG previews | Writes PNGs |
| `--check-audio-levels [--capture]` | debug | Playback gate checks; `--capture` adds a real process tap | `--capture` needs System Audio Recording permission |
| `--render-label-previews <dir>` / `--render-widget-previews <dir>` | debug | Label and widget PNG previews | Writes PNGs |

Scripts: `swift scripts/check-tile-input.swift <pid> <bottom|left|right>` (synthetic clicks, hold menu and label centering against a running dock; needs Accessibility for the terminal and opens Finder) and `scripts/window-fit-probe/run.sh` (window fitting, with `PORTSIDE_WINDOW_FIT_ONLY`; see BUILD.md). Environment overrides: `PORTSIDE_WINDOW_FIT_ONLY`, `PORTSIDE_SETTINGS_TAB`, `PORTSIDE_SETTINGS_HEIGHT`.

## Procedure: reveal, first click, no focus steal (T-01)

Uses the left or right edge so the native Dock is never touched.

1. Seed an isolated home with the file above. To have a tile to click, change `entries` to `[{"type":"app","app":{"bundleIdentifier":"com.apple.TextEdit","path":"/System/Applications/TextEdit.app"}}]`.
2. `source scripts/swift-env.sh; swift build`, then `CFFIXED_USER_HOME=<home> .build/debug/portside`.
3. Open a Notes or Stickies window and place the caret in it.
4. Touch the left edge. Expect: the slide starts with no visible delay; the Notes window stays key (keep typing: text lands in Notes while the dock is out).
5. Move off the dock. Expect: it hides after `hideDelay` (0.3 s default) and moving back before then cancels the hide.
6. Reveal again and click the TextEdit tile once. Expect: TextEdit launches or comes forward on that first click.
7. Repeat 4 to 6 with `"edge":"right"`. Repeat with Settings open (menu bar > Settings) and with a fullscreen app.
8. Optional synthetic pass: `swift scripts/check-tile-input.swift <pid> left` with a Finder tile pinned.
9. Quit from the menu bar. Record pass/fail per step, OS build and display setup in the run record.

## Procedure: native Dock recovery (T-02)

Run only in a disposable macOS user account (AGENTS.md rule 6). Use a signed or ad hoc `.app` or the debug binary; record which.

1. Record `defaults read com.apple.dock autohide` and `defaults read com.apple.dock autohide-delay` (a missing key is a value too).
2. Launch with `"hideNativeDock": true`. Expect: the native Dock stays hidden and `~/Library/Application Support/com.james.portside/native-dock-backup.json` exists.
3. Quit from the menu bar. Expect: both values match step 1 exactly (including a missing key) and the backup file is gone.
4. Relaunch, then `kill -9 <portside pid>`. Expect: the watchdog child restores the native Dock within about a second and deletes the backup.
5. Relaunch, then `kill -9` both the app and its `--watch-native-dock` child. Expect: the native Dock stays hidden and the backup remains. Launch again: startup recovery restores before the UI appears. Alternatively `portside --restore-dock` restores without UI.
6. Sleep/wake, lid and display unplug with hiding on and off: the dock reveals and clicks work afterward (existing CHECKLIST hand check).
7. Compare against step 1 after every step that restores, and record results.

## Hand gaps at baseline

- Every item in [CHECKLIST.md](CHECKLIST.md) "Needs a hand check" and the unchecked tester follow-ups remain open; this ticket closes none of them.
- No UI or interaction tests exist. Hover, reveal, first click and focus behavior are covered only by the procedure above and `check-tile-input.swift`.
- Reveal latency is not measured. The test matrix gate (event to animation start over 100 interactions) needs a signpost or bounded trace in the reveal path; adding one is a separate change.
- Native Dock hide/restore, the watchdog, display recovery and the updater have no automated tests; they write system or app state and stay physical checks.
- macOS 26 has not been checked for this baseline.
