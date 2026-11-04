# Portside: Checklist

Status of the milestones in `docs/PLAN.md`, what still needs a hand check, and the backlog. The long dated build log that used to live here was removed for the public release; it is in the git history.

## Roadmap

- [x] **A:** Edge tracker, non-activating panel, slide animation
- [x] **B:** Pinned apps, running indicators, drag reorder, persistence
- [x] **B.5 / B.6:** Hover labels; dock position (bottom, left, right) and separator resize
- [x] **C:** Widget protocol and widgets (Clock, Calendar, Weather, System Stats, Battery, then CPU, Memory, Now Playing, Agents, AI Usage)
- [x] **D:** App groups (expand and collapse, custom icons)
- [x] **E:** Settings window (sidebar panes, live apply, global hotkey)
- [x] **F:** Hide the macOS Dock (autohide-delay only, exact save and restore), Open at Login (`SMAppService`), `.app` bundle, notification badges, Developer ID signing and notarization, DMG release, in-place Check for Updates
- [x] **P1-P3 parity:** context menus, Trash, folder stacks (grid, fan, list), spacers, spring-load, magnification, multi-display, fullscreen and Spaces, windows fit clear of the dock, activity icons

## Needs a hand check

These were built and tested with synthetic input; a person should confirm them on a real machine:

- Open at Login from the app tile menu (Automation prompt, no focus steal)
- Two displays: the dock follows the cursor's display; dragging a window across the edge does not reveal
- Fullscreen apps and Space switches keep the reveal working
- Magnification with 27+ apps, group grids, and menus
- Calendar consent and Downloads permission retention in the signed app
- Download the DMG from a release, drag to Applications, launch with no Gatekeeper prompt
- Check for Updates from an installed older copy: Download and Install shows its steps, Portside quits, the new version reopens with settings intact; also the failure state (Try Again, Open Release Page) and the `swift run` state
- Portside tile: Option turns Quit into Force Quit, and with Hide the macOS Dock on, the Dock comes back after it
- Cmd+Tab with Settings open: opening from the menu bar, the hotkey, and a dock click puts Portside first, and it is next in line after switching away
- Tile menu (right-click and hold): window list, recents and app actions for VS Code, Finder, Spotify; choosing each does the right thing; how visible the brief native menu is, with Hide the macOS Dock on and off
- Lid closed and opened, sleep, an external display unplugged, with hiding on and off: the dock still reveals and clicks work. `NSScreen.screens` going empty could not be simulated
- `kill -9` with Hide the macOS Dock on: the native Dock returns within a second
- Fresh install: hiding off, then Settings > Dock explains Keep windows clear (Accessibility is not requested on its own)
- Now Playing's previous / play-pause / next on an Extra Wide widget, since widget clicks moved into the strip's gesture
- Copilot CLI from a Homebrew cask (quarantined) on a tester's Mac: no "Not Opened" alert
- Settings sidebar on macOS 26: header, rows and Check for Updates share one left edge (checked on 27 only)
- Hover labels in light mode over dark windows (dark mode was checked over white and black)
- Glass rim over white pages and text: no colored specks in Match macOS or Custom with Refraction on, and the rim bend still looks right, including while magnifying

## Backlog

- Import plain file tiles from the native Dock (folders already import)
- VoiceOver labels and keyboard navigation
- Side-dock widget layout (side docks show Small widgets)
- Window previews on hover; profiles (saved layouts)
- Trash: Option-click Empty without the warning
- Move the older widgets (Clock, Calendar, Weather, Battery, System Stats) onto the shared `WidgetLayout` spacing
- Optional: hide badges when an app's own notification badge setting is off, if that becomes readable

Out of scope: minimized windows in the Dock, the two-finger App Expose gesture, assigning apps to Spaces, bounce on attention request (needs private APIs).

## Known gaps

- The native menu section draws the Dock's real menu for a few frames each time a tile menu opens, and an app that is neither running nor kept in the native Dock has no window or recents section. It lists windows the Dock lists, which can leave out other Spaces.
- New installs start with hiding off and Keep windows clear on, but nothing asks for Accessibility until the user visits Settings, so windows can extend under the dock until then.
- Accessibility can look granted in Settings while this process is still untrusted after an update (stale TCC row keyed to an old code signature). Toggling the switch does not rewrite it. Grant Access runs `tccutil reset Accessibility com.james.portside`, then asks to quit and relaunch so macOS can prompt for a fresh grant.
- The watchdog restores the native Dock after a crash but does not reopen Portside.
- The cause of the reported "dock stops working" was found by reading the code (force unwrap with no displays, stale windows and slides after sleep), not reproduced; no crash report from a released build was available.
- A signed-out Copilot CLI is not retried for 6 hours after signing in, unless Portside is reopened; the GitHub CLI is still used meanwhile.

- Automatic update notifications and the existing install/relaunch flow need end-to-end testing in the signed release app. Debug launch and settings persistence were checked; no installed app was replaced.
- AppKit ignores `NSApp.terminate` while the SwiftUI update sheet is up, and closing it with `endSheet` was not enough. The sheet dismisses through its SwiftUI state before quitting; if the app is still running 3 seconds later, it exits through the SIGTERM handler, which skips `dockEngine.stop()`.
- Camera usage has no public per-app owner API, so a running camera is credited to apps also using the microphone.
- Codex usage meters only move after a Codex turn that logs `rate_limits` numbers.
- The AI Usage Claude meter uses an undocumented Anthropic endpoint and may stop working without notice.
- The AI Usage Copilot meter uses the CLI's experimental `account.getQuota` or GitHub's undocumented `copilot_internal/user`, and either may change. ACP has no quota method, so `copilot --acp` use is counted through the account-wide quota, not read over ACP. Only tested on a free plan against live data; paid plan parsing is tested with a stub reply.
- The Copilot CLI is found in fixed install locations only (Homebrew, `~/.local/bin`, npm global, nvm, `gh copilot`, VS Code). Elsewhere the meter falls back to the GitHub CLI.
- The Agents widget and notch discover T3 Code runs and OpenCode `session_v2` rows from local SQLite, plus Claude Code and Codex CLI hook files. Copilot still has no session writer. Zed agent threads are not read yet (compressed blobs, no busy flag). Standalone OpenCode needs a live `session_v2` busy timestamp; the authenticated HTTP API is not used.
- Copilot has no app icon unless Copilot for Xcode is installed, so its gauge shows a "C".
- A clicked-open group or folder closes only on a click. Cmd-Tab or a Space switch leaves it (and an auto-hiding dock) up until the next click.
- The Settings sidebar sits flush with the window edge and the toolbar can end in a hard line, unlike the floating sidebar and soft edge in System Settings.
- The lens rim has no chromatic aberration now, and it was not compared against the native Dock's rim, which may have some. The lens rewrites its filter when resized, so one frame of fringe is possible before it is removed again. Not checked after moving the Liquid Glass slider in System Settings.
- Window fitting is not measured with Stage Manager, edge-drag tiling, Raycast window commands, or apps with their own minimum height.
- Group tiles and Portside's own tile use SwiftUI `.contextMenu`, so right-click works only on their unmagnified area.
- The DMG layout script drives Finder; your Finder preferences (path bar, hidden files) show in the DMG window.

## Tester feedback follow-up (2026-11-03)

- [x] Optional notch agent count, working pulse, session focus buttons and usage detail, using existing consent and hooks.
- [x] Automatic launch/daily release checks, system notification, menu bar availability mark and existing verified installer.
- [x] Full Disk Access shortcut in General, with an explanation that the user must grant it and it cannot override corporate security.
- [x] Copilot executable disabled by default behind a separate preference; HTTPS fallback retained with a proxy-certificate error message.
- [x] Removed false playback animation: a silent AVAudioEngine source reproduced `IsRunningOutput == 1`. The UI now reports active output with a static speaker.
- [x] Settings round trips: fresh defaults, legacy auto-hide preservation, and new explicit preferences.
- [x] Debug build and isolated `swift run` launch; test bundle notch opened on first click and changed from 0/0 to 1/1 after a fixture hook event.
- [x] Copilot default left an available fixture executable unexecuted. The HTTPS quota request succeeded; an extra test assumption that GitHub CLI would be signed out was false because it still had a keychain credential.
- [ ] Physical notch positioning, many menu bar items, full screen, display changes and Reduce Motion on a tester's Mac.
- [ ] Corporate Zscaler reproduction, notification permission and signed app install/relaunch, physical sleep/wake, and macOS 26 visual checks.

Known limits: the default static audio icon still appears for silent open output streams. Opt-in measurement reflects app PCM before hardware volume/mute, and very quiet or non-capturable streams may not register. Notch and dock share widget hosts and refresh timers. Update notifications remember the last notified version in Portside preferences. Full Disk Access is never granted programmatically.

Validation note: overwriting the executable inside an already-used temporary test bundle produced one code-signature termination and one SIGILL at a compiler-generated AX array witness accessor in WindowFitter. A fresh signed temporary bundle and the original SwiftPM executable launched successfully with window fitting enabled. No production crash cause is claimed from that test-copy failure; investigate if it recurs in a clean installed build.

### Playback, notch preferences and label follow-up

- [x] Opaque native label background and primary text, with light/dark renders on white/black backgrounds; white-background renders visually inspected.
- [x] Notch position, empty-state visibility, animation, total count and usage preferences, with legacy/partial/invalid-value settings round trips.
- [x] Opt-in actual playback measurement, permission explanation and Settings shortcut.
- [x] Final debug build and isolated left-edge `swift run --skip-build portside`: survived launch check and exited cleanly on SIGTERM without changing native Dock settings.
- [x] Playback gate checks: silence, transient, sustained tone, gaps, stop, NaN and stereo PCM.
- [x] Authorized real process-tap test: silent running stream inactive, synthetic 440 Hz tone detected, silence cleared playback, resources removed. No audio saved.
- [ ] Test Ableton and Windows App playback/pause, permission denial/recovery, hardware mute expectations and display changes in the installed build.
- [ ] Hand-check hover/click behavior and notch preferences on macOS 26. The purple cursor matched the automation overlay; its session was reset, but global overlay removal was not visually verified.

### Settings sidebar regression

- [x] Reproduced inert sidebar clicks and arrow-key navigation in the previous local app. Its rows had no selected state despite the Dock pane being open.
- [x] Root cause: the row geometry modifier wrapped the selection tag. Applying the tag after geometry measurement restores native List selection while preserving the alignment fix.
- [x] Rebuilt app: single-clicked all five panes, verified selected-row state and matching detail content, and used Down to navigate from Dock to Appearance.
- [x] Verified Clock on/off, notch settings expansion and animation on/off, and audio controls hiding/showing with the audio activity toggle, using isolated preferences.
- [x] Debug and release builds passed; isolated SwiftPM launch and packaged-app interaction checks passed. Audio-level regression checks passed without capture permission.
- [ ] macOS 26 sidebar visual alignment, close/reopen and light-mode checks still need hand testing. This SwiftUI modifier-order regression is covered by the real app interaction check; no unit-test seam exists in this repository.

### Agent Notch redesign (agentnotch.app-style)

- [x] Dedicated Settings > Agent Notch pane with enable toggle, live preview, Minimal/Balanced/Detailed presets, placement, compact/dashboard appearance, behavior, filters and reset.
- [x] Compact black island with working/attention counts, pulse while working, attach/below/left/right placement and multi-display options.
- [x] Expandable dashboard: session cards, pin/close, hover expand, click focus or expand, Escape and outside-click collapse, optional plan-usage bars sharing Widgets consent.
- [x] Codable round trips, invalid-value clamps, filter/provider rules, hover/pin lifecycle via `--check-notch`; PNG previews via `--render-notch-previews` (hosting-view bitmap after ScrollView captures were empty).
- [x] Copilot session filter toggle, optional pill border, accent color row that collapses (Form DisclosureGroup did not).
- [x] Playback measurement: debounced tap recreate on process-set churn, preserve playing across recreate, per-app failure instead of global disable, tap UID from `kAudioTapPropertyUID`.
- [x] Accessibility grant helper: when Settings shows Portside on but `AXIsProcessTrusted()` is false (stale TCC after update), Show Windows and Recents / Grant Access offer Reset Permission (`tccutil reset Accessibility`), Quit Portside, and a fresh grant on relaunch instead of the toggle loop.
- [x] Tile context menu with Accessibility granted: NativeDockMenu capture no longer rearms auto-hide / dismisses before Portside's NSMenu pops up (`isCapturing` + `isPresenting`).
- [x] Same with Settings open: Settings resigning key during Dock `AXShowMenu` is deferred until the tile menu presentation ends, so auto-hide does not flap mid-click.
- [x] Agent Notch / Agents widget discover T3 Code runs (`statev2.sqlite`) and OpenCode sessions (`opencode.db` session_v2 busy/idle), with provider filters for OpenCode and Cursor-in-T3; hook PID walk skips short-lived shells.
- [ ] Physical notch attach shape, crowded menu bar overlap, full screen and Reduce Motion on a tester's Mac. Context gauges and inline approval actions stay out of scope until hooks supply that data.
- [ ] Hand-check Ableton and Windows App with Measure actual playback after the tap-churn fix.
- [ ] Hand-check Show Windows and Recents with a stale Accessibility entry (toggle already on): Reset Permission → Quit → relaunch → enable when asked → windows/recents appear.
- [ ] Hand-check Agent Notch with a running T3 thread and a busy OpenCode session: counts, host "T3 Code", click-to-focus, and filters for OpenCode / Cursor.
