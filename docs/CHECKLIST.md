# Portside: Checklist

Roadmap mirrors `docs/PLAN.md`. Milestones A to E, B.5 and B.6 are done and hand-tested. Milestone F is done and hand-tested (folder stacks from `persistent-others` import with the P2 grid-first slice; plain file tiles still skipped). P1 and P2 are partly built, see below.

## Roadmap

- [x] **A:** Edge tracker + non-activating panel + slide
- [x] **B:** Pinned apps + running indicators + drag reorder + persistence
- [x] **C:** Widget protocol and widgets (clock, calendar, weather, system stats, battery)
- [x] **B.5:** Hover labels with a reusable overlay panel (including the label placement fix)
- [x] **B.6:** Dock position (bottom/left/right) and separator resize
- [x] **D:** App groups (expand/collapse)
- [x] **E:** Settings window (reveal/hide delay, animation, icon size, magnification, dock position, widgets, groups) applying live; now a sidebar layout with a System pane; includes auto-hide toggle with Cmd+Option+D, Portside as a regular app while Settings is open, inline group naming and rename, open groups on hover
- [ ] **F:** [x] Hide the macOS Dock (autohide-delay trick only, exact save and restore); [x] launch at login (`SMAppService`); [x] a real .app bundle (`scripts/build-app.sh`); [x] import native orientation and tilesize as Portside's initial position and icon size; [x] a manual "Import from macOS Dock" action with undo; [x] import `persistent-others` folders as stacks (file tiles still skipped). First-launch seeding of pinned apps and folder stacks is built.
- [ ] **Live on it:** Daily-drive checkpoint with notes before starting P1
- [ ] **P1:** Right-click context menu (Keep in Dock, Open at Login, Show in Finder, Hide, Quit, Remove); click-and-hold opens the same menu (built on app tiles, group tiles, Portside's own tile and grid cells, hand test pending); divider right-click (built: Turn Hiding On/Off, Turn Magnification On/Off, Position on Screen, Dock Settings); Option turns Quit into Force Quit (built); drag apps in from Finder (built); drag icons out to remove (built, hand test pending); drop files onto app icons to open them (built: strip tiles and group grid cells); launch bounce (built: all three edges plus group grid cells); reveal when a file is dragged to the edge (built); Cmd-click (Reveal in Finder, built); Option-click (hide frontmost) and Cmd+Option-click (hide others) (built); Hide/Show and Force Quit in the app menu (built); Cmd-Option-D show/hide (built); Open at Login checkbox on app tiles (built, hand test pending)
- [x] **P2:** Trash; folder stacks (grid-first; fan/list deferred); spacers; system glass + Reduce Transparency; spring-load apps; magnification. Hand-tested.
- [ ] **P3:** [x] Follow the display the cursor hits; [x] fullscreen apps and Spaces (`canJoinAllSpaces` / `fullScreenAuxiliary` + re-front on Space change); [x] do not reveal while holding the mouse button / dragging a window (file drags still reveal); [x] badge counts from LaunchServices (private API, guarded; no Accessibility); [ ] window list in the right-click menu; [ ] VoiceOver labels and keyboard navigation
- [ ] **Out of scope (do not build):** minimized windows in the Dock; two-finger swipe App Expose gesture; assigning apps to Spaces from the menu; the recents section; bounce on attention request (needs private APIs, not wanted for now)
- [ ] **Enhancements:** more widgets; app groups (D); window previews on hover (on B.5 overlay); profiles
- [ ] **UX cleanup:** Side-dock widget layout (deferred from B.6; see phase below)

## README cleanup + macOS 26 floor (2026-10-31)

- [x] Declared minimum bumped from macOS 14 to **macOS 26** (`Package.swift` `.macOS("26.0")`, `LSMinimumSystemVersion` / actool `26.0`). Matches Liquid Glass and the only tested host (macOS 27 / Xcode 27).
- [x] README shortened to overview + quick start + doc index. Detail moved to `docs/FEATURES.md`, `docs/ARCHITECTURE.md`, `docs/BUILD.md`, `docs/DATA.md`.
- [x] `AGENTS.md` definition of done points at those files for layout / dock.json / private-API notes.
- Known gap: still untested on a clean macOS 26 machine (developed on 27).

## Open Settings hotkey (2026-10-31)

- [x] Customizable global hotkey opens Settings from any app (Carbon `RegisterEventHotKey`, same path as Cmd+Option+D).
- [x] Default: Command-Shift-D (`⌘⇧D`). Distinct from Cmd+Option+D (Dock hiding / system shortcut) and from the local menu's Cmd+,
- [x] Settings > General > Keyboard: record, Reset to default, Clear. Persisted as `settingsHotkey` in dock.json (`null` = cleared; older files without the key keep the default).
- [x] AppDelegate re-registers live when the chord changes. Menu bar Settings… still shows Cmd+, (local menu shortcut).
- [x] `swift build` passes on Swift 6.4.2 / Xcode 27.2.
- [ ] Hand test: with another app frontmost, press ⌘⇧D and confirm Settings opens; change the shortcut in General > Keyboard and confirm the new combo works and the old one does not; Clear, confirm none fires; Reset restores ⌘⇧D; relaunch and confirm it persists.
- Known gap: if a system or app shortcut claims the same combo, macOS may take it first (same as Cmd+Option+D).

## Release as a .dmg (2026-10-31)

- [x] Releases ship `build/dist/Portside-X.Y.Z.dmg` instead of a zip. `release.sh`, `publish-release.sh`, and `build-app.sh --package` / `--notarize` all use it.
- [x] New `scripts/make-dmg.sh`: drag-to-install window (540x560 pt, icon view, toolbar hidden), `Portside.app` on top, orange down arrow, `Applications` symlink in a rounded drop zone. Background rendered by `scripts/DMGBackground.swift` at 1x and 2x, merged into a Retina TIFF. Sail volume icon. Compressed UDZO.
- [x] `--notarize` order: sign app, notarize + staple app, build DMG, sign DMG, notarize + staple DMG, `spctl --type open`. Users who copy the app out still get a stapled app.
- [x] `verify_dmg` mounts the result and checks the app signature, the Applications link, and the saved layout.
- [x] Verified (ad-hoc `--package`): window bounds 200,120,740,708; icons at 270,150 and 270,415; screenshot matches the Chrome-style layout; volume icon shows.
- Findings: Finder only saves window bounds after a close/reopen, and icon positions must be set after that reopen or they shift down by the toolbar height. `hdiutil -srcfolder` drops `.VolumeIcon.icns` and the main Finder pass deletes it, so it is copied last and parked off-window in a short second pass.
- [x] Full `--notarize` DMG run: app and DMG both Accepted and stapled. Published as [v0.3.0](https://github.com/jameszangari/portside-dock/releases/tag/v0.3.0) with `Portside-0.3.0.dmg` (3.5 MB). The downloaded asset, quarantined, passes `spctl` as Notarized Developer ID; the app inside is 0.3.0, stapled, and accepted.
- [ ] Hand test: download from the release page, open the DMG, drag to Applications, launch with no Gatekeeper prompt.
- Known gaps: needs Finder Automation permission for the terminal on first run. If your Finder shows the path bar or hidden files, you see them in the DMG window too (your Finder prefs, not baked into the DMG).

## Developer ID + notarization (2026-10-31)

- [x] Developer ID Application cert installed (James Zangari / WNZ8H4UHQE). G2 intermediate (`devidg2.der`) required for the identity to show as valid.
- [x] `scripts/setup-notary.sh` + keychain profile `portside-notary` stored (app-specific password).
- [x] `Portside.entitlements` for Hardened Runtime: `com.apple.security.automation.apple-events` (Trash, Open at Login) and `com.apple.security.personal-information.calendars` (Calendar widget; without it EventKit is denied with no prompt).
- [x] Verified: all five scripts pass `bash -n`; bad args exit 2; release/publish dry runs change nothing. Local-cert `build-app.sh` and `--notarize` both exit 0. The release zip, unpacked and quarantined like a browser download, is Developer ID signed with runtime flag, stapled, has both entitlements, and `spctl` accepts it as Notarized Developer ID.
- [x] `scripts/build-app.sh --notarize`: Developer ID sign (runtime + timestamp), notarytool submit, staple, re-zip. Local `--install` still uses the Portside Local Development cert.
- [x] `release.sh` / `publish-release.sh` use `--notarize` for the GitHub asset.
- [x] `scripts/build-app.sh --notarize` Accepted, stapled (with CDN retry), `spctl`: `accepted` / `Notarized Developer ID` / James Zangari (WNZ8H4UHQE). Zip at `build/dist/Portside-0.2.0.zip`.
- [ ] Hand test: open the stapled `build/Portside.app`; confirm Calendar / Empty Trash / Open at Login still work under Hardened Runtime. Then cut/publish a real GitHub release when ready.
- README Build / Versioning / layout updated. No dock.json keys.

## Versioned .app on each GitHub release (2026-10-31)

- [x] Goal: every release tag ships a downloadable `Portside.app` (zipped).
- [x] `scripts/build-app.sh --package` writes `build/dist/Portside-X.Y.Z.zip` via `ditto -c -k --keepParent`, then unpacks and `codesign --verify --deep --strict`.
- [x] `scripts/release.sh --apply` still commits and tags, then runs `--package`. Signing identity is checked before the commit. Still never pushes.
- [x] New `scripts/publish-release.sh`: dry run by default; `--apply` pushes HEAD and `vX.Y.Z`, then `gh release create` (or `gh release upload --clobber` if the release already exists) with the zip. Refuses unless HEAD matches the tag.
- [x] Dry runs of `release.sh patch` and `publish-release.sh` print the zip path and change nothing.
- [x] `scripts/build-app.sh --package` produced `build/dist/Portside-0.2.0.zip` (3.3M); unpack + `codesign --verify --deep --strict` passed; Info.plist version 0.2.0.
- [ ] Human publish when ready: next cut is `scripts/release.sh patch --apply` then `scripts/publish-release.sh --apply` (preferred), or check out `v0.2.0`, package from that commit, and publish that tag. Do not attach a zip built from a newer commit to an older tag.
- README Versioning / Build / layout updated. No dock.json keys. Not a user-facing dock feature.

## Faster SPM builds (2026-10-31)

- [x] Cause: Xcode 26/27 Explicitly Built Modules. Clean/cold debug spent most wall time in "Planning deferred tasks" and SDK PCM generation; `.build/out/SDKExplicitPrecompiledModules` had grown to ~800MB / ~800 variants.
- [x] Fix: `scripts/swift-env.sh` defaults `SWIFT_ENABLE_EXPLICIT_MODULES=NO`. `scripts/build-app.sh` sources it. README and AGENTS.md document `source scripts/swift-env.sh` before `swift build` / `swift run`.
- [x] Measured (M4 Max, Xcode 27.2): clean debug ~27s -> ~9s; touch-one-file ~2.5s either way; clean release ~19s either way. Parallel SwiftPM on the same `.build` serializes on a lock (one contested `build-app.sh` hit 64s).
- [ ] No hand test beyond build timing. Product behavior unchanged.
- README build section and project layout updated; not a dock feature.

## Folders First first-click (2026-10-31)

- [x] Cause: the open stack's `...` header used a SwiftUI `Menu` with `Toggle`s. On the non-key overlay, those toggles needed a wake-up click before Folders First / Show Hidden Files fired.
- [x] Fix: `...` pops the same AppKit `StackOptionsMenu` as the tile right-click (via `StackOptionsMenuButton` + `MenuKeyFocus`), so checkbox items fire on the first click. Header now also includes Display as Folder.
- [x] Follow-up: AppKit menus sit at `.popUpMenu`, but the stack/group overlay is higher, so the menu drew as a ghost behind the glass. `MenuKeyFocus.popUp` demotes the source window to `.popUpMenu` for the tracking run (also covers group-grid right-clicks).
- [x] Follow-up: the grid order and the Folders First checkmark drifted apart (checked showed files first, unchecked showed folders first). Cause: the cache held the already-arranged list and the toggle re-sorted that list. With Custom Order and no saved order the sort is a no-op, so turning Folders First off kept folders in front, and each toggle compounded it. Fix: `StackContents` now stores only the raw name-sorted listing (`listings`); `items(for:)` applies sort and folders-first from the live stack on every read. Disk reads happen only when the path or Show Hidden Files changes. `StackController` forwards `contents.objectWillChange` so the open grid redraws when a read lands.
- [x] `swift build` passes. Release build installed to `~/Applications/Portside.app` and relaunched.
- [ ] Hand test: open a folder stack, click `...`: menu on top of the grid; click Folders First several times: order and checkmark stay in sync every time. Same for Show Hidden Files and each Sort by option. Escape closes; dock stays up.
- README Features already covered; no new dock.json keys.

## Battery compact icon (2026-10-31)

- [x] Below 28pt tile (same cutoff as CPU / Memory), Battery shows a state-aware SF Symbol (`battery.*.percent` or `.bolt` when charging/plugged) instead of the percentage digits. Hover still shows the named percent.
- [x] Compact Battery icon uses default (neutral) foreground, matching CPU / Memory glyphs; ring color still reflects charge/AC.
- [x] Wide System Stats legend is a two-column Grid so CPU / RAM values share one trailing number column.
- [x] `swift build` passes.
- [ ] Hand test: shrink below 28pt and confirm Battery shows a neutral icon; grow back for the number. At Wide System Stats, confirm the two numbers stack on one vertical line.
- README Features updated; no new dock.json keys.

## Widget text scales from 32pt (2026-10-31)

- [x] Cause: widget fonts used `max(fixedPt, tile * ratio)`, so below ~32pt text overflowed the tile, and above it secondary labels stayed tiny while gauges grew.
- [x] Fix: `WidgetTypography.fontSize(_:tile:)` scales every widget face from the 32pt visual (System Stats Wide legend 8/10pt, gauge readings 11pt, Calendar day 15pt, and matching Clock / Weather / Battery sizes). No fixed floors; `minimumScaleFactor` only as a safety net.
- [x] `swift build` passes on Swift 6.4.2 / Xcode 27.2.
- [ ] Hand test: set icon size to 32pt and confirm the look, then drag to ~24pt and ~64pt and confirm CPU/RAM, Calendar, Weather, Battery, and Clock keep the same relative sizing with no clipping.
- README Features updated; no new dock.json keys.

## Settings focus pins dock (2026-10-31)

- [x] While Settings is the key window and auto-hide is on, DockEngine suppresses auto-hide (edge tracker off, panel stays revealed) without flipping `dockModel.autoHide` or the Settings toggle.
- [x] Resigning key (another app, miniaturize) or closing Settings restores effective auto-hide from the saved preference and rearms hide if the cursor is outside.
- [x] Preference changes while Settings is focused still apply live; turning auto-hide on stays suppressed until Settings loses focus.
- [x] `swift build` passes on Swift 6.4.2 / Xcode 27.2.
- [ ] Hand test: auto-hide on, open Settings, confirm dock stays up and the General toggle still reads On; Cmd+Tab away and confirm hide resumes; return to Settings and confirm it pins again; close Settings and confirm normal auto-hide.
- README Features / Notes updated; no new dock.json keys.

## System Stats Wide labels (2026-10-31)

- [x] Wide System Stats legend: smaller color-matched numbers (~0.18× tile) with neutral CPU / RAM labels (~0.12× tile) beside them. Single CPU / Memory tiles and Small System Stats unchanged.
- [x] Swift 6.4.2 / Xcode 27.2: `swift build` and `scripts/build-app.sh --install` pass; strict signature verification passes. Opened `~/Applications/Portside.app`; only that process is running.
- [ ] Hand-check Wide System Stats at the current icon size.
- README Features updated; no new setting or backlog feature.

## Calendar date bar width (2026-10-31)

- [x] Compact Calendar red bar takes its width from the date text layout instead of a fixed fraction of the tile. Single- and double-digit dates use the same layout rule in Small and Wide.
- [x] Swift 6.4.2 / Xcode 27.2: `swift build` and `scripts/build-app.sh --install` pass; strict signature verification passes. Opened `~/Applications/Portside.app`; only that process is running.
- [ ] Hand-check the bar against the date at the current icon size. Larger tiles keep their weekday header.
- README Features and Planned reviewed; no new setting or backlog feature.

## Calendar connection regression (2026-10-31)

- [x] Reproduced from actual click logs: two requests returned `granted=false error=none`, leaving “Click to connect Calendar” unchanged. The running executable was `.build/out/Products/Debug/portside`, left behind by the typography verification.
- [x] TCC logs attribute the Calendar request to `com.t3tools.t3code`, not the signed Portside app. This is a launch-context regression, not a swallowed widget click. Do not leave `swift run` running after smoke tests.
- [x] Calendar now explains the signed-app requirement before an unbundled permission request, retains its requesting EventKit store, prevents concurrent requests, and shows failed-request recovery. Denied/restricted clicks open Calendar privacy settings; write-only access can request full access.
- [x] Recheck authorization on refresh and click so external permission changes do not leave stale event/access state. No new timers, private APIs, settings, or persistence keys.
- [x] Swift 6.4.2 / Xcode 27.2: `swift build` and `scripts/build-app.sh` pass; strict signature verification passes. `swift run portside` launched without reported errors and exited cleanly on SIGTERM. Opened `build/Portside.app` through Launch Services and verified it is the only Portside process; widget/engine startup logs are healthy. Signed app left running for the human consent test.
- [ ] Human: click Calendar in the signed app, approve access if prompted, confirm event/no-event label, then click again to open Calendar. If denied, click to open Calendars privacy settings, enable access, and click again.
- Test limitation: macOS TCC attribution and consent require the actual launched app and human permission UI; a mocked EventKit unit test would not reproduce this regression. Captured request/TCC logs are the regression evidence.

## Widget typography follow-up (2026-10-31)

Supersedes the inline labels from the activity widget pass below.

- [x] James approved the widget appearance and requested a commit.
- [x] Remove CPU / RAM micro-labels and percent suffixes from gauges. Single gauges use one larger system-font number; combined Small keeps only concentric rings, while Wide has color-matched numbers.
- [x] Larger system typography for Battery and Weather. Clock drops its secondary date below 48pt. Calendar below 44pt uses a date and status symbol, with no tiny weekday or event text.
- [x] Hover titles carry live readings and Calendar access/event details. Hover target registration now lives in the observed widget container, so published refreshes update the visible label without a new timer.
- [x] `swift build` passes. Rendered all widgets at 31pt, 48pt and 64pt, including 100% readings and a negative temperature; CPU / Memory hover reading assertions pass.
- [x] `swift run portside` launched without reported errors; the updated development build is left running for review, with the installed copy stopped first.
- [ ] Hand test at 31pt: inspect every tile, hover for details, hold over CPU for a refresh, and click to confirm the existing destination opens. Check Small / Wide and side positions.
- Known gap: sub-28pt layouts and long Calendar event titles still need broader overflow work. No settings or persistence keys changed.

## Activity widget readability (2026-10-31)

- [x] Keep System Stats concentric rings: CPU outside in blue, RAM inside in purple. Thicker strokes and explicit metric labels replace unlabeled percentages.
- [x] Wide layout uses larger percentages beside a labeled legend. Optional CPU and Memory square widgets show a single labeled gauge and open Activity Monitor; both start disabled and appear in Settings and the menu bar widget list.
- [x] Existing widget kinds and size preferences stay intact. New tiles use `cpu` and `memory` in the existing `widgetKinds` array.
- [x] `swift build` passes on Swift 6.4.2 / Xcode 27.2. A temporary SwiftUI rendering harness checked 48pt and 64pt layouts including 100% values and verified distinct CPU / Memory widget IDs.
- [x] `swift run portside` launched and remained running without reported errors, then exited cleanly with Ctrl+C. Reopened the installed copy after the check.
- [ ] Hand test: enable CPU and Memory in Settings > Widgets; compare with System Stats in Small and Wide; click each to open Activity Monitor; relaunch and confirm selection persists.
- Known gap: combined Small labels remain small at low icon sizes. Prefer Wide or the separate gauges for readability. GPU, disk and network metrics are not added in this slice.

## Remaining backlog (actionable)

### codesign keychain prompt (2026-10-31)

- [x] Dialog `codesign wants to access key "identity"` is Portside's local signing private key (ACL description `identity`, cert `Portside Local Development`), triggered by `scripts/build-app.sh`.
- [x] Root cause: import used `-T /usr/bin/codesign`, but `partition_id` was only `apple-tool:`. Without `codesign:` in the partition list, macOS keeps asking for the login password.
- [x] Added `scripts/ensure-codesign-key-access.sh`: checks the partition list, tries a silent fix, then native consent. Called from `scripts/build-app.sh` before codesign and from `scripts/setup-signing.sh` on create/reuse. Unattended runs can set `PORTSIDE_SKIP_KEYCHAIN_PROMPT=1`.
- [x] `scripts/SigningConsent.swift`: stock `NSAlert` (Okay primary, Not Now destructive). No custom panel (that caused the extra border/shadow frame). After Okay, `LocalAuthentication` shows the system Touch ID / password sheet. Compiled cache under `scripts/.cache/` (gitignored).
- [ ] Human: run `scripts/build-app.sh` (or `--install`). Click Okay on the system alert, approve Touch ID / password, confirm later rebuilds stay quiet. If codesign still asks, Always Allow.
- Known gap: silent partition fix can still fail after owner auth if the key ACL requires the login password string; codesign's Always Allow remains the fallback.
- README signing notes updated. No dock.json or Settings changes.

### Remember macOS folder permissions (2026-10-31)

- [x] Signing review: reproduced and fixed setup silently replacing a saved fingerprint when a different valid certificate has the same name. Saved identities now take priority across the keychain search list; invalid or unavailable saved identities fail without rewriting the record.
- [x] Eleven isolated setup/build-preflight checks pass, including same-name replacement rejection, saved-identity reuse with duplicate names, invalid/missing/unavailable identity handling, existing-certificate reuse, and refusing an untrusted existing certificate. These fixtures do not mutate the real keychain.
- [x] Confirmed the real local certificate's user trust is limited to Code Signing, and both installed and freshly rebuilt apps use its saved fingerprint. Debug and release builds succeed.
- [x] Strict signature verification passes for both app copies. Modifying a temporary app copy's Info.plist fails verification; re-signing that copy changes its code hash while satisfying the original app's certificate-based requirement. The signed app and `swift run portside` both launch successfully in icon-export mode; this does not verify the Downloads consent UI.
- [x] Inspect both built and installed app signatures: both used a `cdhash` designated requirement with ad-hoc signing. No valid code signing identity existed.
- [x] Add `scripts/setup-signing.sh`: create a local code signing identity once, grant codesign key access, trust it for code signing in the user account, and persist its fingerprint outside the repo. Reuse it on subsequent runs; stop if an existing identity is unavailable rather than replacing it.
- [x] Default app builds to the saved signing identity, with explicit `SIGN_IDENTITY` override and explicit ad-hoc opt-out. Never silently fall back to ad-hoc signing.
- [x] Create the local identity on this machine and confirm a second setup run reuses it.
- [x] `swift build` and `scripts/build-app.sh` succeeded. The release bundle passes strict signature verification; its designated requirement now uses the bundle identifier and certificate fingerprint instead of a binary hash. Two different temporary executables signed with this identity had different code hashes but identical designated requirements. `swift run portside --export-icon` and the signed bundle's export command both launched and wrote PNGs successfully. Full permission UI behavior remains a hand test.
- [ ] Human: install, Allow Downloads once for the new signing identity, quit/reopen twice, rebuild/reinstall, and confirm Downloads does not ask again. This requires the macOS consent UI; permissions remain managed by macOS.

### Release compiler warnings (2026-10-31)

- [x] Explicitly discard layout-move results inside three animation closures so `withAnimation` returns `Void` without unused-result warnings.
- [x] `swift build` and `scripts/build-app.sh` succeeded without these warnings; bundle assembly and signing completed. `swift run portside` stayed running until stopped with Ctrl+C, with no launch error reported.
- README Features and Planned reviewed: no user-facing feature or setting changed in this compiler-warning cleanup.

Ordered for daily-driver impact. One slice at a time; hand-test gate after each. Milestones A to E and most of F/P1/P2/P3 are already shipped; this is what is left.

### 0. Pending hand tests (clear before more features)

Status (2026-10-31): James confirmed A, C, E, F. **B (Open at Login) and D (multi-display / Spaces / button-hold) deferred** until he can test them. Fresh `~/Applications/Portside.app` was used.

#### A. Settings sidebar
- [x] 1–4. Confirmed

#### B. Open at Login (app tile checkbox) — deferred
- [ ] 5–10. Deferred (Automation / Login Items)

#### C. Notification badges
- [x] 11–17. Confirmed

#### D. Spaces / fullscreen / button-hold — deferred
- [ ] 18–22. Deferred (second display / deeper Spaces testing)

#### E. Magnification smoke
- [x] 23–26. Confirmed

#### F. Quick regressions
- [x] 27–28. Confirmed

### 1. Quick bugs and polish

Status (2026-10-31): built. Settings always centers on the primary display; Icon gap slider in General > Dock (`iconGap`, 0 to 8pt, default 6). `swift build` clean. Hand test pending.

- [x] **Settings window position:** every open (from closed or miniaturized) places the fixed 760x560 window at the dead center of the primary screen's visible frame. No longer follows the cursor's screen. Menu bar and separator menu share the same path.
- [x] **Icon gap slider:** Settings > General > Dock, under Icon size. Range 0 to 8pt, default 6. Live apply, persisted as `iconGap` in `dock.json`. Strip, multi-unit widgets, hover slop, and magnifier slot math all use it on Bottom/Left/Right.
- [x] **Icon gap vs separators:** icon gap now spaces only tiles (apps, groups, folders, widgets, Trash). Section separator air per side is `5 + iconGap` (separator pads itself by a constant 5), so it tracks the gap. Hit target stays at least 9pt so resize/menu work at gap 0.
- [x] **Same minimum spacing for every item:** app icons carry a built-in transparent margin (100/1024 of the tile per side, measured on system icons), so at gap 0 they never touch. Widgets now pad by that margin along the dock, and group/folder tiles draw their rounded square at the icon's visible size (`IconMetrics.margin` in DockItem.swift). Gap 0 = app-icon spacing everywhere; fit-to-screen math includes the widget margins.
- [x] **Separator between widgets and folders/Trash:** the right section now reads widgets | folders and Trash. The extra separator shows only when widgets exist and a folder, Trash, or a folder-drop gap follows; fit-to-screen math counts it. Same resize and menu behavior as the other separators.
- [x] **Even right edge:** the system folder and Trash images have only a 4% / 2% transparent margin (app icons 10%, measured), so Trash hugged the dock edge and the folder sat tight against its neighbors. Both are now drawn at `IconMetrics.fullBleedScale` (0.86) inside the tile, matching an app icon's visible size and edge spacing.

#### Hand test
- [ ] 1. Close Settings if open. Menu bar > Settings: window opens centered on the main display. Close. Separator > Dock Settings: same spot and size. Move the window, close, reopen: back to that center (not where you left it).
- [ ] 2. Open Settings while the cursor is near a screen edge or (if available) on another display: still primary-center, not under the cursor.
- [ ] 3. General > Icon gap: drag 0 to 8 while the dock is visible; tiles tighten/loosen live. At 0, widgets, groups, folders and Trash sit as far apart as app icons do (none touch). At 0 and 8, space around each separator stays the same. Default 6 matches the previous look. Relaunch: value kept.
- [ ] 4. With widgets, a folder and Trash showing: a separator sits between the widgets and the folder, none between folder and Trash. Hide the widgets or Trash: no stray separator. Switch to Left and Right: same gap along the column. Reveal timing unchanged. Separator still draggable / right-clickable at gap 0.

### 2. App groups (gaps vs native feel)

Status (2026-10-31): built. Finder drop-in and menu rename were already shipped; strip drag-in, title-click rename, and in-grid reorder added. `swift build` clean. Hand test pending.

Already shipped: create/rename from menus and Settings, Finder drop into group, drag member out, open on hover.
- [x] **Drag strip icon into a group:** drag a pinned or unpinned running app onto a group tile (opens the grid) or into the open grid; dashed insertion gap chooses the slot; drop adds and removes from the strip. Escape cancels. `DockModel.addToGroup` / `GroupController.finishStripAppDrop`.
- [x] **Click group card title to rename:** tap the title in the open group popover for the same inline rename as creation (Return commits, Escape cancels, key focus only while editing).
- [x] **Reorder inside a group:** drag a member within the open grid; dashed gap follows; release inside moves with `moveInGroup` (no remove prompt). Release clearly outside still asks Remove from Group / Remove from Dock.
- [x] **Reorder cleanup (glitchy drags):** causes and fixes. Needs hand test.
  - Strip: the slot came from `x / (tile + spacing)`, which ignores the 8pt padding, spacers, separators and widths, so tiles flipped under the cursor. Now `steppedSlot` uses the tiles' real frames: a tile passes a neighbor only when the cursor crosses that neighbor's midpoint, so a neighbor still sliding aside can't pull it back.
  - Drag locations were in the `strip` space while Trash / group hit tests used `dockRoot` frames (offset by the strip padding). Reorder, folder and unpinned-app drags now use `dockRoot`.
  - Folders: a cursor in the gap between two folders sent the dragged one to the last slot, and the move wasn't animated. Fixed with the same stepped slot and the same 0.12s ease.
  - Group grid: the dragged member was removed from the grid layout, which destroyed the view owning the gesture, so `onEnded` never ran (DragOut's "mouse up without a gesture end" fallback closed it without saving the move). Now the grid is one flat `LazyVGrid`, the dragged cell stays as a dashed placeholder, order changes live (`GroupController.reorderSlot`), and release saves. Out and back, or Escape, restores the start order.

#### Hand test
- [ ] 1. Open a group. Click its title: rename field appears; type a name, Return. Escape cancels. Frontmost app keeps focus after.
- [ ] 2. Drag a pinned app onto a group tile: grid opens; drop on the tile or into a chosen gap; app leaves the strip and lands in the group. Escape mid-drag puts it back.
- [ ] 3. Drag an unpinned running app onto a group the same way.
- [ ] 4. Open a group; drag a member to a new slot inside the grid: order updates, no alert. Drag a member clearly out: Remove from Group / Remove from Dock alert as before.
- [ ] 5. Reveal timing unchanged.

### 2b. Free layout (move anything anywhere)

Status (2026-10-31): built, `swift build` clean, app launches (also with a hand-edited test layout containing a stale id, which loaded fine). Synthetic mouse input can't reveal the dock, so the drags are untested. Hand test pending.

- [x] **One order for everything:** `layout` in `dock.json` is a list of ids: apps, groups and spacers (their entry ids), `widget:<kind>`, `stack:<id>`, `trash`, `running` (the unpinned running apps plus Portside's own tile, with their separator, moving as one block), and `separator:<id>`. Empty (the default) means the old look, so nothing moves until you move something. `DockModel.resolvedLayout()` drops stale ids and slots new items beside their own kind (a new app after the previous app, a widget after the previous widget, a folder before Trash), so a saved layout never goes stale. The per-kind arrays (`entries`, `stacks`, `widgetKinds`) are kept in the same relative order, so Settings, import and groups still see a sane list.
- [x] **Drag any tile to any slot:** apps, groups, spacers, widgets, folders and Trash. A dragged item steps past a neighbor when the cursor crosses its midpoint, using the real slot frames (`LayoutFramesKey`), same rule as the reorder fix. Drag out still removes apps, groups, spacers, widgets and folders; Trash only moves (it never offers removal, `removable: false` in DragOut). Escape puts the item back; saved on release.
- [x] **Separators are items:** divider right-click now has Add Separator (at the end), Move Separator Left/Right (Up/Down on side docks), Remove Separator, and Reset Layout. Dragging a separator still resizes the icons.
- [x] **Finder-drop gap:** a new app lands right after the entry before the gap (or before the first entry); a new folder likewise among folders. Settings widget reordering keeps a saved layout in step.
- [x] Fit-to-screen counts every separator in the layout.

#### Hand test
- [ ] 1. Drag an app to the far right, past the widgets and Trash. Then drag a widget in between two apps, a folder to the very start, and Trash to the middle. Each follows the cursor without flicker; relaunch keeps the order.
- [ ] 2. Drag Trash out of the dock and release: it goes back, no poof and no label. Escape mid-drag puts any item back.
- [ ] 3. Drag an app onto Trash / a group tile: still asks / joins as before. Drag a widget out: still removed.
- [ ] 4. Right-click a separator: Add Separator adds one at the end; Move Separator Left/Right shifts it; Remove Separator deletes it. Reset Layout restores apps, widgets, folders, Trash.
- [ ] 5. Pin a new app from Finder with a custom layout: the dashed gap shows where it will land and it lands there.
- [ ] 6. Left and Right docks: same drags along the column; reveal timing unchanged.

Known gaps (layout):
- Separators move through the menu, not by dragging (their drag resizes the icons).
- With a custom layout the "Move" order in Settings > Widgets and the dock can differ only if you reorder in one place; the last change wins in both.

### 2c. Square widgets and widget sizes

Status (2026-10-31): built, `swift build` clean, app launches. The three new square designs were rendered offscreen at 48pt and checked (clock face reads the right time, text fits). Menu and Settings picker untested by hand.

- [x] **Square (1:1) design for every widget:** Clock is an analog face (12 ticks, hour and minute hands, orange center); Calendar is weekday over date like the Calendar icon, with a dot in the next event's color; System Stats is concentric rings (CPU outer blue, memory inner purple, round caps from 12 o'clock) with both percents inside in the ring colors; its Wide design is the same rings beside a CPU/MEM legend. Both rendered offscreen at 48pt and fit. Weather and Battery were already square. Tooltips carry the detail the square drops (full date, next event, both percents).
- [x] **Side docks always Small:** the left/right column is one tile wide (it was as wide as the Wide widgets). Fit-to-screen math uses each widget's shown size.
- [x] **Size per widget on the bottom dock (iOS-style):** right-click a widget for Remove Widget, Edit Widgets..., and a size row of outlines (square, wide) with the current one highlighted (`WidgetSizePicker`, a SwiftUI view inside an NSMenu item). The same picker sits on each enabled row in Settings > Widgets. Saved as `widgetSizes` (only non-default sizes); default stays each widget's own design.

- [x] **Widget hover labels:** widgets are hover targets now, so the native-style label names what a click opens (`DockWidget.hoverTitle`: Activity Monitor for System Stats, Battery Settings for Battery, else the widget name). They stay out of the magnifier's tiles (never grow), and a widget slid aside by magnification keeps its label on it. The old AppKit tooltips are gone.

#### Hand test
- [ ] 1. Switch to a Left or Right dock: every widget is square and the column is one tile wide. Clock shows a face with the right time; Calendar shows weekday + date; Stats shows both bars.
- [ ] 2. Bottom dock: right-click Clock. The menu shows Remove Widget, Edit Widgets..., and two size outlines. Click the square: menu closes, Clock turns into the face. Click Wide again from the menu: back to the digital clock. Relaunch keeps it.
- [ ] 3. Weather and Battery menus show no size row (they only have Small).
- [ ] 4. Settings > Widgets: size outlines appear on Clock, Calendar and System Stats rows and change the dock live.
- [ ] 5. Dragging a Small widget around (free layout) still works; the floating preview is square.
- [ ] 6. Hover each widget: label shows Clock / Calendar / Weather / Activity Monitor / Battery Settings, like an app's label. With magnification on, widgets don't grow and the label stays on the widget.
- [ ] 7. System Stats rings: outer blue (CPU) and inner purple (memory) track the numbers over a few seconds.

Known gaps:
- No Extra Wide (3-tile) or taller sizes yet; every design is one tile tall.

### 3. Folder stacks (P2 leftovers)

Status (2026-10-31): built, `swift build` clean, app launches and the existing Downloads stack loads. Hand test pending.

Already shipped: pin folder from Finder, grid popover, drop-in, FSEvents, import from native Dock.
- [x] **Fan view:** icons rise from the tile in a curve (`StackFanView`), name pill beside each, first 10 then "N more in Finder". Bends right on Bottom and Left docks and left on a Right dock; names sit on the side away from a Left dock, otherwise to the left of the icons.
- [x] **List view:** rows with icon, name, and a detail that follows the sort (date for the date sorts, kind otherwise). Scrolls past 320pt. Drop slot uses height only.
- [x] **View picker:** tile right-click > View as (Grid, Fan, List), and the `...` button in the open stack's header (AppKit menu, same items as the tile). Persisted per stack as `view`.
- [x] **Sort / filter:** Custom Order (default), Name, Date Added, Date Modified (newest first), Kind; Folders First; Show Hidden Files. Persisted per stack (`sort`, `foldersFirst`, `showHidden`). Changing one re-reads the folder, so the open stack updates live. Header `...` uses AppKit checkboxes so the first click fires (SwiftUI Menu Toggle did not).
- [x] **Show as folder vs stack of icons:** Display as Folder (`showAsFolder`), and any empty folder, draws just the folder's own icon (the system's, so Downloads, Documents and so on keep their native artwork) at full tile size like an app icon, with no card or border. The mini-grid "stack of icons" look keeps its card.
- [x] **Import:** native `showas`, `arrangement` and `displayas` map onto view, sort and Display as Folder when stacks import.
- [x] Fixes found on the way: a file change refreshed a stack with the settings it had when first watched (stale `itemOrder`); a refresh queued during a read reused stale settings. Both now use the newest stack.
- [ ] Milestone F leftover: import plain file tiles from `persistent-others` (folders already import)

#### Hand test
- [ ] 1. Right-click the Downloads stack: View as, Sort by, Folders First, Show Hidden Files, Display as Folder are listed with checkmarks on the current choices.
- [ ] 2. View as Fan, then click the tile: icons curve up from the tile with names beside them; click one to open it. A folder with more than 10 items ends with "N more in Finder".
- [ ] 3. View as List: rows with a kind (or date) on the right; scrolls when long. Click opens.
- [ ] 4. Open the stack and use the `...` button in its header: pick Sort by Date Modified, then Name: the order changes live while open. Does the menu open and close without the dock hiding?
- [ ] 5. Folders First and Show Hidden Files: items regroup / dotfiles appear and disappear.
- [ ] 6. Display as Folder: tile shows the plain folder icon at the same size as the app icons, with no background or border (Downloads shows its native Downloads icon); turn off: mini grid returns.
- [ ] 7. Drop a file into the open stack: Custom Order + Grid or List shows the dashed slot; Fan or any other sort just drops in.
- [ ] 8. Quit and relaunch: view, sort and filters are kept per stack.
- [ ] 9. Try the Fan on a Left and a Right dock; reveal timing unchanged.

Known gaps (stacks):
- The fan opens centered on the tile like the grid, so it is not anchored at its base the way the native fan is. Side docks are the least tested.
- No in-stack drag reordering; Custom Order is set by where files are dropped.
- Nothing in Settings yet; options live on the tile menu and the open stack.

### 4. P3 leftovers
- [ ] Window list in the app right-click menu (Screen Recording for titles; click focuses)
- [ ] VoiceOver labels and keyboard navigation
- [ ] (Optional) hide badges when the app's Notification badge setting is off, if/when that becomes readable

### 5. UX cleanup
- [ ] Side-dock widget layout (see phase below). Evaluate candidates; do not shrink bottom-dock behavior. Acceptance: Left/Right with 27+ apps and 5 widgets keep configured icon size; widget text >= 11pt; reveal timing unchanged.

### 6. Enhancements (after parity gaps above)
- [ ] Window previews on hover (reuse B.5 overlay)
- [ ] Profiles (saved layouts / pin sets)
- [ ] Update checker (GitHub release tag vs AppInfo.version; replace Check for Updates placeholder)
- [ ] Trash polish: Option-click Empty without warning; empty/full icon animation
- [ ] More widget kinds (only if daily drive asks for them)

### Explicitly still out of scope
Minimized windows in the Dock; attention bounce; two-finger App Expose; assign-to-Spaces from the menu; recents section.

---

# Settings: sidebar layout (2026-10-31)

Status: built and agent-checked with screenshots of every pane. Hand test pending. No new files, no dock.json changes.

## Deliverables

- [x] `NavigationSplitView` with a fixed sidebar (no collapse toggle) and the pane title in the toolbar. Panes: General, Appearance, Widgets, Groups, System.
- [x] Fixed 760 x 560 window with full-size content and a transparent title bar. Panes scroll; the old fit-to-content resize, header and tab bar are gone.
- [x] General split: General keeps Dock and Timing; the new System pane has macOS Dock, Startup, and Import (with the import sheet and Undo).
- [x] Sidebar header shows the icon, "Portside" and `v0.2.0` (full version line as a tooltip); Check for Updates sits at the bottom of the sidebar.

## Verification

- `swift build` clean. Installed build opened via reopen; screenshots of all five panes: everything fits the width, General scrolls, others fit without scrolling.
- Finding: the sidebar renders about 144pt wide, not the 200pt asked for with a single `navigationSplitViewColumnWidth` value. The version line truncated at that width, so it now shows only `v0.2.0`.

## Hand test

- [ ] Open Settings from the menu bar and from the dock separator menu: window opens centered, 760 x 560, General selected.
- [ ] Click each pane; controls apply live as before. Import sheet still opens from System.
- [ ] Cmd+W closes; focus returns to the previous app.

## Known gaps

- Sidebar width not pinned to 200pt (fix: min/ideal/max column width), not applied yet.
- The `v0.2.0` label is not in the installed app until the next install.

---

# P1 leftover: Open at Login on app tiles (2026-10-31)

Status: built, `swift build` clean (no warnings), `swift run` launches. Hand test pending. New files: `Sources/portside/AppLoginItem.swift`, `Sources/AppLoginItemList/` (C helper). Log category `AppLoginItem`. No dock.json changes. `Info.plist` `NSAppleEventsUsageDescription` now mentions System Events.

## Deliverables

- [x] App tile menu (strip, unpinned running, group grid cells): checkbox "Open at Login" after Keep/Remove (and Add to Group when shown), before Show in Finder.
- [x] State reads from the session login-items list (`LSSharedFileList` via `AppLoginItemListContainsPath`), same list as System Settings > Open at Login. No Automation needed to show the checkmark.
- [x] Toggle for other apps writes through System Events (`make login item` / `delete`). First toggle may ask for Automation permission for System Events. Denial shows an alert with an Open Settings link.
- [x] Portside's own tile (when running as `Portside.app`) uses `SMAppService.mainApp`, same as Settings > Open Portside at login.
- [x] Path match is standardized; bundle-id fallback covers the same app at another install path.
- [x] Verified: C helper matches System Events for Raycast/Bitwarden on and Calculator off; System Events add/remove of Calculator round-trips and restores the prior 10-item list.

## Known gaps

- `LSSharedFileListInsertItemURL` still compiles but does not persist on this macOS (returns a pointer, item never appears). Writes stay on System Events.
- Under `swift run`, Portside's own tile uses System Events (no `.app` bundle for `SMAppService`), same as any other app. Prefer the built app for Portside's own checkbox.
- Ad-hoc rebuilds may re-prompt for System Events Automation (same as Finder Automation for Empty Trash).

## Hand test

- [ ] Right-click an app that is already under Open at Login (Raycast, Bitwarden, …): checkbox is on. Toggle off; confirm it disappears from System Settings > General > Login Items. Toggle back on.
- [ ] Right-click Calculator (or another app not in Login Items): checkbox off. Toggle on; it appears in Login Items. Toggle off again.
- [ ] First toggle on a fresh build: Automation prompt for System Events. Deny once and confirm the alert; Allow and confirm the toggle works.
- [ ] Group grid cell and an unpinned running app: same checkbox behavior.
- [ ] Portside's own tile in `~/Applications/Portside.app`: checkbox tracks Settings > Open Portside at login.
- [ ] Frontmost app is unchanged after a successful toggle (no focus steal). Reveal/hide timing unchanged.

---

# P3: Notification badges (2026-10-31)

Status: rebuilt on LaunchServices, installed build verified with synthetic reveals and a screenshot. Hand test pending. Files: `DockBadges.swift`, `LaunchServicesBadges.swift` (new, private API). dock.json: `showBadges` (default true). `badgeAccessHintDismissed` removed (old files ignore it).

## Deliverables

- [x] Read each running app's badge from LaunchServices ("StatusLabel", the same store the Dock draws from) via `_LSASNCreateWithPid` + `_LSCopyApplicationInformationItem`, loaded with dlopen/dlsym. Missing symbols: badges off, Settings says "Not available", no crash.
- [x] No Accessibility permission. The Accessibility hint and prompt are gone.
- [x] Reads run off the main thread. One read when the dock starts revealing (deferred a runloop turn, outside the reveal path), then every 1s only while the dock is on screen; app launch and quit also read. Nothing runs while hidden.
- [x] Chip: system-red circle (capsule for longer text), white bold text, soft shadow, top-trailing corner, sized from the tile (grows with magnification). Overlay only: icons no longer shift when a badge appears; no white ring.
- [x] Group tiles show the sum of member badges; grid cells show their own.
- [x] Native style, measured against the real Dock (quit Portside, revealed the native Dock with two test apps, screenshot): height 0.38 of the tile, regular-weight white digits at 0.54 of the height with slightly tight tracking, no ring or shadow, top-trailing corner flush with the icon frame's corner.
- [x] Native red calibrated on screen: P3 (0.850, 0.281, 0.223), about sRGB #EB372D. Portside's badge pixels now equal the native Dock's (P3 0.826, 0.404, 0.316 in the screenshot). `systemRed` was visibly pinker.
- [x] Settings > Appearance > Badges: color menu (macOS Red default, Accent Color, Orange, Yellow, Green, Blue, Purple, Pink, Graphite, Custom with a color picker) and a live preview chip. Text turns black on light fills. dock.json: `badgeColor`, `badgeCustomColor`.

## Verification

- `swift build` clean. Installed with `scripts/build-app.sh --install` after a graceful quit (Dock prefs restored to autohide on, no delay, then the hide trick re-applied on launch).
- Finding: the old Accessibility approach could not work with "Hide the macOS Dock". After `killall Dock` the Dock's tiles report `AXStatusLabel` nil for badges set before the restart, while LaunchServices still has them (test app: AX `[]`, LS `5`). Portside restarts the Dock at every launch. Ad-hoc rebuilds also reset the Accessibility grant.
- Finding: the Dock posts no AX notifications for badge changes, and LaunchServices delivers none to clients (`lsappinfo listen`), so a visible-only 1s read is the event-free minimum.
- Logs: launch read `Discord.app=1, Mail.app=460`; a test app badge set while hidden appeared on the next reveal; live changes (1, 2, cleared, 4) landed within 1s while revealed; no reads after hide.
- Reveal timing after the change: mouseEntered -> panel interactive 1.7 to 3ms warm (14ms first reveal), interactive within 0.06ms of animation start. A first version that listed apps on the main thread added 20ms; fixed.
- Screenshot of the revealed dock: Discord "1" circle and Mail "460" capsule at the top-right, unclipped.
- Finding: the badge color mismatch was color management, not Liquid Glass. A plain test window without glass produced the same shifted pixels; icons were unaffected. Fixed by calibrating the input color against the screen.
- Color setting: `badgeColor` set to `green` in dock.json rendered a systemGreen badge after relaunch; file restored afterwards.
- Capsule width for "460": 1.32 of its height vs native 1.25 (sub-pixel at normal sizes).

## Hand test

- [ ] Apps with badges (Mail, Discord, Messages) show the same count as their app icon would on the native Dock, on Bottom, Left and Right.
- [ ] Read a message or change a count with the dock up: the badge updates within about 1s. Hidden then revealed: correct by the end of the slide.
- [ ] Magnification on: the badge grows with its icon and stays unclipped at both ends of the dock.
- [ ] Group tile with badged members shows the sum; open grid shows per-app badges.
- [ ] Toggle Show notification badges off/on live. No Accessibility prompt appears.
- [ ] Appearance > Badges: each color applies live to the dock and the preview; Custom opens a picker and survives relaunch; Yellow shows black text.
- [ ] Compare with the native Dock in light mode too (calibration was done in dark mode).

## Known gaps

- An app whose badges are turned off in System Settings > Notifications may still show a badge here. The Dock filters those itself and the setting is not readable (no `com.apple.ncprefs` on macOS 27).
- Up to 1s lag while the dock is visible (no change events exist).

## Deferred

- Window list in the app menu; VoiceOver / keyboard navigation.

---

# P3: Multi-display, Spaces, button-hold suppress (2026-10-31)

Status: implemented, committed (`ea653d8`). Hand test pending (James: no second display available right now; multi-display checks deferred). Single-screen items (button-hold suppress, Spaces/fullscreen, file-drag reveal) also still pending confirmation.

## Deliverables

- [x] `DockScreen.active` follows the display whose edge the cursor hits; panel, layout fit limit, and icon scale relocate on `dockScreenDidChange`.
- [x] One edge window per screen (same thickness and level as before). Screen-parameter changes rebuild zones; Space / fullscreen switches re-front edge windows and a revealed panel.
- [x] Panel and edge windows keep `.canJoinAllSpaces` and `.fullScreenAuxiliary` so reveal works over fullscreen apps and across Spaces.
- [x] Edge `mouseEntered` while any mouse button is held does not reveal (window drag). File `draggingEntered` still reveals. On mouse-up, if the cursor is still in an edge zone, reveal then.
- [x] README Features / Planned / layout notes updated.

## Verification

- Swift 6.4.2, Xcode 27.2, macOS 27.0.1, arm64. `swift build` clean. `.build/debug/portside` stayed alive; logs showed edge armed and panel relocated to the active screen (1 screen in the agent environment).

## Hand test

- [ ] Two displays: move to the bottom (or side) edge of the external display: dock appears there. Move to the built-in edge: dock moves there. Check logs for `dock active screen` and `panel relocated`.
- [ ] Auto-hide on: drag a window by its title bar across the dock edge: dock does not reveal. Release with the cursor still on the edge: dock reveals. Log should show `enter suppressed` then `mouseUp after button-hold suppress`.
- [ ] Drag a file from Finder to the edge: dock still reveals (unchanged).
- [ ] Fullscreen an app (Safari or Photos): bump the dock edge: Portside reveals over it. Switch Spaces with the dock up or hidden: edge still works; revealed panel stays front.
- [ ] Single-display reveal/hide timing and hide-delay cancel still feel the same.

## Deferred (later P3)

- Badge counts (done, see the badges section above).
- Window list in the app menu (Screen Recording for titles).
- VoiceOver labels and keyboard navigation.

---

# P2: Folder stacks, grid-first (2026-10-31)

Status: done and hand-tested by James. Fan/list/sort deferred.

## Deliverables

- [x] `FolderStack` model + `stacks` in dock.json; right section after widgets, before Trash.
- [x] Tile mini-grid of contents (folder icon when empty); magnify + hover label; not mixed with pinned apps.
- [x] Click opens grid popover (reuse group motion/placement). Click item opens it. Menu: Open, Show in Finder, Remove.
- [x] Drag folder from Finder to pin; reorder stacks; drag out to remove. Insertion gap opens at the drop slot while dragging (native Dock style). Same dashed tile gap for pinning apps from Finder among entries.
- [x] Drag-out "Remove" label no longer clipped (label is laid out above the floating preview inside the overlay size, not offset outside a fixed frame).
- [x] Drop files/apps onto stack tile or open grid deposits into the folder (move, else copy). Open grid shows an insertion gap at the drop slot; `itemOrder` in dock.json keeps placement. Dragging over a stack tile opens the grid immediately (no 600ms delay).
- [x] App groups: Finder drag (including `.app`) over a group tile opens the grid immediately; open grid shows the same dashed tile-sized insertion gap; drop adds at that slot (no pin-gap beside the group on the strip).
- [x] Drag a member out of an open group grid: alert with Remove from Group, Remove from Dock, or Cancel (focus returned to the previous app).
- [x] Pinning an app from Finder: gap clears and tile appears in one unanimated layout pass (no drop jitter).
- [x] FSEvents content updates, no polling.
- [x] Import / first-launch seed from native `persistent-others` directories; file tiles skipped.
- [x] README Features, Planned, layout, dock.json keys updated.

## Hand test: Bottom, Left, Right

- [x] Drag a folder from Finder onto the dock: stack appears before Trash; mini icons match contents.
- [x] Click opens grid; click a file/app opens it; Portside stays inactive. Right-click Open / Show in Finder / Remove.
- [x] Drop a file onto the closed stack and into the open grid: it lands in the folder; tile/grid update.
- [x] Open a stack grid, drag an app from Applications into a chosen slot (gap follows); it stays in that place after drop.
- [x] Drop an app from Finder onto the strip (not a stack): pins with no visible jitter when the gap becomes the icon.
- [x] Drag a file or app onto a stack tile: grid opens immediately; leave closes after grace via hide rules.
- [x] Reorder stacks; drag one out to remove. Import from macOS Dock adds native folders. Mag + labels OK.
- [x] Reveal/hide still within a frame; app groups still work alongside stacks.

---

# P2: Spacers, Reduce Transparency, app spring-load (2026-10-31)

Status: done and hand-tested by James. New file: `Sources/portside/AppSpringLoad.swift`. dock.json: `DockEntry` type `spacer` (`{ type, spacer: { id, size } }`).

## Deliverables

- [x] Section spacers (regular / small) in the pinned section: Add Spacer on the separator menu; reorder by drag; drag out or Remove Spacer to delete. Import / first-launch seed from native `spacer-tile` / `small-spacer-tile`.
- [x] Reduce Transparency (Accessibility): Liquid Glass falls back to frosted at high opacity; strip redraws live via `accessibilityDisplayOptionsDidChangeNotification`. Reduce Motion already respected elsewhere.
- [x] File drag resting ~600ms on a running app tile brings that app forward (`AppSpringLoad`). Does not launch not-running apps.
- [x] System glass (Liquid Glass / Frosted / Solid) was already shipped; this slice only adds the Accessibility Reduce Transparency path.
- [x] Magnification polish already on all three edges (prior slice).

## Hand test

- [x] Separator menu > Add Spacer (Regular and Small); drag to reorder; drag out to remove; right-click Remove Spacer.
- [x] Import from macOS Dock (or first-launch seed) keeps native spacers in place.
- [x] System Settings > Accessibility > Display > Reduce Transparency on/off: glass becomes opaque frosted live; off restores glass.
- [x] Drag a file from Finder onto a running app tile, hold ~0.6s: that app comes forward; drop still opens the file. Pass quickly: no activate.
- [x] Reveal/hide, groups, stacks unchanged.

## Deferred

- Fan and list views; sort-by; show as folder vs stack of icons.
- Importing plain file tiles from `persistent-others`.

---

# P2: Trash (2026-10-31)

Status: implemented, debug build and launch verified. Click/label regressions from this slice fixed and agent-tested with synthetic input. Hand test pending. No commits or pushes.

## Deliverables

- [x] Native empty/full Trash tile at the far end on every edge; same icon size, magnification, hover label and AppKit right-click/hold menu; no tile drag or drag-out removal.
- [x] General > Dock: Show Trash in dock, live and default on; `showTrash` persisted in dock.json, older files default on.
- [x] FSEvents watcher for `~/.Trash` (works without Full Disk Access; DispatchSource+O_EVTONLY does not). Background reads, no polling. Unknown state looks empty and disables Empty Trash.
- [x] Fullness: list `~/.Trash` when allowed; else Finder `count of items of the trash` when Automation is already allowed (no watcher prompt). Hint only if both fail. Drops/Empty Trash update the icon optimistically.
- [x] One dismissible Full Disk Access hint next to the setting (also notes Finder Automation), with a System Settings link. `trashAccessHintDismissed` persists dismissal/link use so it does not nag again.
- [x] Open through NSWorkspace. Empty Trash uses NSAppleScript with a Finder-hosted confirmation before Finder's empty command. Cancel is harmless; Automation denial and failures show inline in Settings and in the hover label.
- [x] `NSAppleEventsUsageDescription` embedded in the SPM binary and copied into the app bundle by build-app.sh.
- [x] File/folder drops reuse FileDrop session highlighting and hide suppression, preflight deletability and use FileManager.trashItem off the main thread. Failures report briefly.
- [x] Dock tile dropped on Trash asks first (Remove from Dock / Move to Trash / Cancel). No silent delete. Move to Trash is for apps and folder stacks only (groups/widgets unpin only).
- [x] README Features, Planned, project layout and data keys updated.
- [x] Regression fix (James): short clicks open apps again. `menuHold` uses `onTapGesture` plus a simultaneous long-press, not an exclusive LongPress/Tap sequence that could swallow taps in the non-activating hosting view.
- [x] Regression fix (James): magnified hover labels stay centered. The hovered icon reports spring-interpolated scale/shift via a `GeometryEffect`; the label overlay reanchors immediately to that frame (no second window animation).

## Verification

- Swift 6.4.2, Xcode 27.2, macOS 27.0.1, arm64. The inherited implementation initially failed to compile because its `open()` method shadowed Darwin.open; fixed and every subsequent code batch built successfully.
- `swift run portside` launched and stayed alive. Real permission denial produced one Trash log and the empty fallback, with no crash.
- Synthetic bottom-edge reveal: animation start 1.71ms, panel interactive 2.66ms, animation finished 155.48ms. Panel entry canceled the 300ms pending hide; exit hid normally.
- Public NSTrashEmpty/NSTrashFull images resolve with representations through 1024pt. NSWorkspace opening `~/.Trash` succeeded with Finder even without Full Disk Access.
- Finder confirmation script syntax compiled with osacompile without executing it. No existing Trash contents were deleted.
- Final `swift build`, `swift run portside`, and `scripts/build-app.sh` passed. The release bundle passed strict code-signature verification and contains NSAppleEventsUsageDescription. SIGTERM stopped the smoke-test app and the existing native Dock restore path ran.
- `scripts/check-tile-input.swift` (Accessibility): mag off bottom, and mag on bottom/left/right. Each PASS: 2 short clicks, 1 hold menu, no launch on hold release, settled label center error under 0.5pt, Portside stays inactive.
- Click/label regression rebuild: `swift build` and `scripts/build-app.sh` passed after the fixes.

## Hand test: repeat on Bottom, Left and Right

- [x] Trash is last, native icon and label align with apps; magnification works. Dragging Trash itself cannot reorder or remove it.
- [x] Drag a disposable file/folder to the edge and onto Trash: dock stays up, target highlights, file moves; full icon updates with Full Disk Access. Drag away and re-enter during hide delay. Invalid drops reject; internal app tiles remain in their original order.
- [x] Click once while another app is active: Finder opens Trash, Portside stays inactive. Check ordinary app tile clicks too.
- [x] Right-click and hold both show Open/Empty Trash. Empty and unreadable state disable Empty Trash. With access and disposable contents, Cancel preserves them; confirm deletes via Finder and icon empties. Test Automation denial without a crash.
- [x] Without Full Disk Access: empty icon, one Settings hint and working Open/drop actions. Dismiss or follow its link, reopen Settings/relaunch: no repeated hint.
- [x] Show Trash off/on updates live and survives relaunch. Repeat with auto-hide off and magnification both off/on. Check reveal logs stay within a frame.

James confirmed Trash hand tests good (2026-10-31).

## Known gaps and deferred work

- Full Disk Access is unavailable in this launch context, so actual full-state watcher updates, file drops, confirmation, and Automation allow/deny paths still need the hand test. No claim of destructive-flow verification.
- The watcher covers the requested `~/.Trash`, not per-volume Trash directories on external disks.
- Filesystem permissions can change after preflight; a multi-file drop can partially succeed. Failures are reported, successful moves stay in the Trash.
- Deferred: Option-click "Empty Trash without warning" and Trash icon animation.
- Synthetic Accessibility clicks pass; trackpad/mouse hand confirmation of short-click launch and magnified label centering still needed.
- 2026-10-31: James reported hide-after-hover broken. Cause was agent test prefs left `autoHide: false` in dock.json (hide path correctly no-ops when off). Restored to true; synth edge enter/exit logged hide armed 300ms then "hide timer fired, hiding".
- 2026-10-31: James reported Trash stayed empty with items present. Listing `~/.Trash` is TCC-blocked without FDA; O_EVTONLY watch also fails. Switched to FSEvents + Finder count fallback. Launch log: watching (FSEvents), "using Finder for empty/full", Trash full (11 items).

---

# Magnification, part 2: side edges and polish (2026-10-31)

Status: built and agent-tested with synthetic input on all three edges, waiting for James's hand test. No new files, no new dock.json keys.

## Deliverables

- [x] Left and Right: same falloff, settings and off-during-drag rules. Icons grow sideways away from the screen edge (scale anchored at the screen side), the shelf keeps its width and lengthens, widgets and separators shift without growing. Room, hit areas, the active band and hover frames are all edge-aware now.
- [x] Fix found while testing: at launch the strip reported its tiles before the magnifier knew the edge (it defaulted to bottom), so side docks measured tiles along x and nothing grew. The magnifier keeps the raw targets and re-reads them when the edge changes.
- [x] Long docks: the shelf stays inside the visible frame. If widening around the cursor would push an end off screen (or under the menu bar on the sides), the growth goes to the other end; only past both limits does it spill evenly. Tested with 30 entries on Left, Right and Bottom.
- [x] Side docks: the column is as wide as the widest widget, so while magnified a tile's hover frame reaches the shelf's screen-side edge (the cursor there already magnifies that tile). Off: unchanged.
- [x] Labels: anchored on the magnified frame on every edge, centered on the icon, usual bubble gap. They slide with the tiles (ease-out about the spring's response) instead of jumping to where the tile is headed; a label that opens as the tiles start to grow starts at the normal frame and rises with the icon.
- [x] Launch bounce while magnified: **bounce at the live magnified size and keep magnifying** (picked over freezing the tile: freezing left the dock unresponsive for the whole launch). Magnification no longer pauses for a bounce. The bounce layer follows its tile's size and slot with the same spring as the tiles (Core Animation spring with the same response and damping), inside a bounce window with room around it so the window never moves mid-follow. The icon is drawn once at the magnified size and scaled down (trilinear). Magnification off: exact old behavior (tile-size bitmap, same window).
- [x] Group tiles and Portside's own tile use the shared AppKit menu path (`appKitContextMenu` with `MenuHold`): right-click and press-and-hold work on the full magnified icon and the menu opens above it. Group tile menu: Rename, Ungroup, Remove from Dock. Portside tile: Settings..., Quit.
- [x] Quick re-entry: while tiles settle after an exit the panel ignores the mouse (clicks above pass through); a global mouse-moved monitor that exists only during that settle takes the mouse back as soon as the cursor is over the shelf and resumes magnification at once.
- [x] Control-Shift flips magnification while held (on to off, off to on). Flags-changed monitors (global plus local) exist only while the dock is revealed; each mouse move over the dock also reports the modifier state. Settings shows a hint under the Magnification toggle.
- [x] Menus and the keyboard: while any dock menu tracks, a 1x1 invisible non-activating panel takes key focus, so key events reach the menu while the frontmost app stays active. Ordering it out after gives focus back. Log category `TileActions`: "menu opened (key focus borrowed ...)" and "menu closed, frontmost app ...".
- [x] Group grid while magnified: opens the usual gap from the tile's normal position and stays there while the tiles settle (screenshots on all three edges: no movement between the first frame and the settled frame).

## Verification (agent, synthetic input, screenshots)

- `swift build` and `swift build -c release` clean. `swift run` launches; SIGTERM quits and the native Dock comes back (`autohide-delay` removed). Your dock.json was backed up, swapped for test configs (30 entries, each edge) and restored byte for byte.
- Reveal timing unchanged: mouseEntered -> animation start 0.9 to 2.1ms, finished about 145 to 150ms.
- Left and Right with 30 entries plus widgets: growth sideways, label beside the magnified icon, shelf clamped below the menu bar at the top end. Bottom with 30 entries: shelf stays on screen at both ends.
- Bounce (triggered with a temporary debug hook, removed): Calculator bounced at 64pt (tile 32pt) with magnification on, kept bouncing at the shrinking size and new slot as the cursor moved along, and the tiles settled normally on exit.
- Right-click and press-and-hold on the raised part of a magnified group tile opened the group's menu above it. Press-and-hold on an app tile still works.
- Escape: a menu left open 2.5s stayed open, then closed about 0.3s after a synthetic Escape posted at the HID level (the same route real keys take). Frontmost app unchanged, Portside never active.
- Re-entry: out of the dock and back over the shelf within about 100ms: "cursor back over the shelf while settling", tiles magnified again in the next screenshot.
- Control-Shift: held -> tiles settle and the label drops to the normal tile; released -> magnified again, without moving the mouse.
- Mouse-move cost unchanged: handler about 100 to 150us, whole turn about 2.4 to 3.3ms average.

## Known gaps

- The global flags monitor worked here because this shell has Accessibility access. A built Portside.app without it may get no global flags events; then Control-Shift applies on the next mouse move over the dock instead of instantly. No prompt is shown either way.
- Borrowing key focus for a menu takes key status from the frontmost app's window while the menu is open (it stays the active app, like Spotlight). Real typing into the frontmost app right after a menu closes is untested here.
- A plain synthetic click still does not launch an app (see the app click regression section), so click-to-launch while magnified is only verified through the debug hook.
- One synthetic press-and-hold on a group tile, sent 250ms after a menu closed with no mouse move between, did not open the menu; with a move first it worked every time. Watch for this in the hand test.
- Widget right-click still uses SwiftUI `.contextMenu` (widgets do not magnify), so the keyboard fix does not cover the Remove Widget menu.
- The bounce icon is drawn from the magnified-size bitmap even after the tiles settle back mid-bounce; it is scaled down with trilinear filtering, so the hand-off back to the tile may look a hair different.
- Menus still turn magnification off while open (part 1 behavior).

## Hand test (do each on Bottom, Left and Right; Settings > General > Position)

- [ ] Sweep slowly and fast: smooth growth away from the edge, about 2 tiles of falloff, widgets and separators move but do not grow, still cursor never jitters. On a side dock, also sweep along the screen-edge side of the column
- [ ] With many apps (27+ plus widgets), sweep to both ends: the shelf stays on screen (and below the menu bar on the sides)
- [ ] Labels: sit the usual gap from the magnified icon's top (or outer side), centered, slide along with it without flicker, including the first label right after entering
- [ ] Click an app (launch and activate), right-click and press-and-hold an app tile and a group tile, including the raised part: the right menu, above (beside) the magnified icon
- [ ] Click a not-running app while magnified: it bounces at the magnified size, magnification keeps following the cursor, no jump; move off the dock mid-bounce: tiles and bounce shrink back together
- [ ] Leave the dock and come straight back within about 200ms: magnification picks up at once
- [ ] Hold Control-Shift over the dock: magnification turns off; release: back on. With Magnification off in Settings, Control-Shift turns it on while held. Note whether it is instant or needs a mouse move (Accessibility, see gaps)
- [ ] Open a menu (right-click and press-and-hold): Escape closes it, arrow keys and Return work, and afterwards typing goes to the frontmost app as before
- [ ] Click a group tile while magnified: the grid opens the usual gap from the tile's normal spot and does not move as the tiles settle
- [ ] Open Settings so Portside's own tile shows: right-click and hold on it give Settings... and Quit
- [ ] Turn Magnification off: dock looks and behaves exactly as before
- [ ] Reveal timing in the log unchanged (`log stream --level info --predicate 'subsystem == "com.james.portside"'`)

---

# Magnification, part 1: bottom edge, engine and setting (2026-10-31)

Status: built and agent-tested with synthetic input on the bottom edge, waiting for James's hand test. Part 2 (above) addresses the known gaps below except the icon margins and menus turning magnification off.

## Deliverables

- [x] `Magnifier.swift` (new): one place computes every tile's scale and shift from the cursor. Raised cosine over 3 slots each side (a tile 1 slot away gets 75% of the growth, 2 slots 25%). The point under the cursor stays fixed: tiles left of it shift left, right of it shift right, so the tile under a stationary cursor never moves away (no hover flicker). The shelf widens by the same amounts at each end.
- [x] Render transforms only (`scaleEffect` from the bottom, `offset`), applied by small modifiers that are the only observers of the magnifier. The strip's layout, its measured size, hover target frames and drop hit-testing stay unmagnified. The strip body is not re-evaluated per mouse move.
- [x] Shelf keeps its height; icons rise above it. Running dots shift with their icon and never grow. Widgets and separators shift, never grow. Pinned, running unpinned, group and Portside's own tiles magnify.
- [x] Panel room: the window grows (32pt up at the default size, a few tiles' worth on each side) only while tiles are magnified or settling, then shrinks back. The shelf never moves on screen when the room comes or goes (base frame placed first, root view aligned to the screen edge).
- [x] Enter/exit with room follows the active region (shelf plus the band the magnified icons cover), not the window, so the transparent room never keeps the dock up. While tiles settle after the cursor left, the panel ignores mouse events, so a click above the dock goes through at once.
- [x] Clicks follow the magnified icon (SwiftUI gesture hit-testing honors the transforms). The right-click overlay grows with the magnified tile, so right-click on the raised part works and the menu opens above the magnified icon (not under the cursor).
- [x] Hover labels hit-test and anchor on the magnified frame and follow the tile while it grows.
- [x] Suspended (tiles settle back, re-engage on the next mouse move after) during item drags, file drags, separator resize, an open group grid, any menu, the remove-group alert, and a launch bounce.
- [x] Motion: SwiftUI springs (engage 160ms, follow interactive 120ms, settle 200ms). No timers, no display link of ours; SwiftUI stops rendering when the spring settles. Reduce Motion: no spring, sizes follow the cursor directly.
- [x] Settings > General > Dock: Magnification toggle (replaces nothing: the old disabled row had already been removed) and Magnified size slider (16 to 128pt, default 64, disabled while off, live). Helper text on side docks says it works on the bottom only for now.
- [x] dock.json: new `magnifiedSize` key; `magnificationEnabled` unchanged. Restored by Undo last import.
- [x] Divider menu: Turn Magnification On/Off.
- [x] Fix (James's report): magnified icons looked translucent where they rose past the shelf edge. The shelf's 1pt border (Frosted, Solid) was an overlay drawn on top of the strip content, and Glass wrapped the content in the glass. The shelf is now its own layer behind the tiles in every style, so icons always render on top at full opacity. Checked with screenshots in Frosted and Glass while magnified.
- [x] Fix (James's report): hovering a group with magnification on broke the dock. Open on hover opened the grid, magnification suspended, and when the tiles had settled the panel shrank to 24x16pt and hid under the cursor. Cause: the strip's first size report fires while the panel is being built, before the engine listens, so the panel ran on the hosting view's intrinsic size, which is zero since the strip root fills the hosting view (needed for the room). Fixes: `DockInteractions` keeps the last size and replays it when the listener is set; the panel's tracking area is created once (`.inVisibleRect` follows resizes); an exit within 50ms of a room resize while the cursor is still over the dock is ignored (AppKit sends an exit and enter about 8ms apart when a window shrinks under a still cursor). Verified: group opens, grid stays open, dock stays up; moving along closes it and magnification resumes; leaving hides as usual; clicks above the dock still go through.
- Unmagnified look, pixel-diffed old vs new with magnification off: Frosted and Solid identical (only the live clock and CPU numbers differ). Glass: app icons identical, but content no longer gets the glass's vibrancy, so running dots, the System Stats bars and the battery ring show their true colors (slightly less bright than before).

## Verification (agent, synthetic input via CGEvent, screenshots)

- `swift build` and `swift build -c release` clean. `swift run` launches, SIGTERM quits and restores the native Dock (verified `autohide-delay` removed).
- Reveal timing unchanged: mouseEntered -> animation start 1.2 to 2.3ms, animation finished about 150ms.
- Screenshots: bell-shaped growth centered on the cursor, bottoms on the shelf, shelf height unchanged and widened, label above the magnified tile; widgets unchanged; 128pt works live from the slider; Left position shows no magnification and a normal layout.
- Click pass-through: clicks 6pt above the panel over the widgets, 25 to 35pt above the shelf right after leaving the tiles, and mid-settle all reached a test window under the dock.
- Hit-testing: press-and-hold and right-click on the raised part of a magnified Mail icon (above the shelf) opened Mail's menu.
- Reorder drag: magnification suspended at drag start, tiles back to base size during the drag, dropped back in its slot, resumed after.
- Cost per mouse move (release build, 30 pinned entries plus running apps, about 480 moves per sweep at 120Hz): handler about 80us; whole main-thread turn including SwiftUI update and CA commit about 3.3ms average, about 10ms max (the max is the engage move that resizes and redraws the window). Logged once per hover: category `Magnifier`, "mouse-moved cost". Measurements are noisy at this scale.
- Not verifiable with synthetic input: a plain click launching the right app. Synthetic taps do not fire on HEAD either (see the app click regression section), so this needs the hand test.

## Known gaps (part 2 or later)

- Side edges: no magnification yet (the math is axis-aware, room and anchors are bottom only).
- Launch bounce: magnification is suspended while a bounce plays (the bounce draws the unmagnified tile).
- Group tiles and Portside's own tile still use SwiftUI `.contextMenu`, so right-click only works on their unmagnified area.
- Menus: magnification turns off while a menu is open, so the menu stays where the magnified icon was while the icon settles back. Settling while a menu tracks can be delayed until it closes (run loop mode), harmless since the dock stays up.
- Synthetic Escape did not close a press-and-hold menu in testing (it went to the frontmost app); a click elsewhere did. Real keyboard input untested here.
- Icons' transparent margins scale with them, so gaps between big magnified icons look wider than 6pt (same as the native Dock).
- Coming back to the shelf during the roughly 200ms settle after leaving is not seen until the settle ends (the panel ignores the mouse then); the hide timer's own check keeps the dock up meanwhile.

## Hand test (bottom edge)

- [ ] Settings > General: turn Magnification on; Magnified size enables. Sweep the dock slowly and fast: smooth growth, falloff to about 2 tiles each side, no jitter on a still cursor
- [ ] Move off the dock (up and sideways): tiles settle back smoothly, dock hides with the usual delay
- [ ] Drag the Magnified size slider while hovering the dock with the other hand on the trackpad, or hover after each change: applies live
- [ ] Click tiles while magnified, including the raised part above the shelf: the tile under the cursor launches or activates
- [ ] Click the app right above the dock (over widgets, and just after leaving the tiles): the click reaches the app
- [ ] Right-click and press-and-hold a magnified tile: its menu, above the icon; magnification eases off while the menu is open
- [ ] Reorder drag, drag out, file drag over the dock, open a group grid: tiles at normal size meanwhile, magnify again after
- [ ] With "Open groups on hover" on: hover a group tile, the grid opens and stays, the dock stays up; move along the dock, it closes and magnification comes back
- [ ] Turn Magnification off: dock looks and behaves exactly as before
- [ ] Reduce Motion on: sizes follow the cursor without springing
- [ ] Reveal timing in the log unchanged (`log stream --level info --predicate 'subsystem == "com.james.portside"'`)

---

# App click regression (2026-10-31)

- [x] Replaced separately attached long-press and tap recognizers with one `LongPressGesture.exclusively(before: TapGesture())` in `menuHold`. Both strip app icons and group app cells use it. Removed the persistent fired flag and its next-click suppression path.
- [x] `swift build` passed with Swift 6.4.2 / Xcode 27.2. `swift run portside` built and launched without an immediate crash.
- [x] Temporary AppKit/SwiftUI harness using the actual gesture helper: short click, hold, next short click, and drag produced exactly 2 taps, 1 hold, 1 drag. No tap on hold release or drag.
- [ ] Human verification: real mouse/trackpad clicks open apps in strip and groups; holds and right-click still open menus; reorder still works.
- Finding: the simplified old-gesture harness also accepted synthetic clicks, so the original real-input failure is not reproduced automatically. This is a candidate fix to gesture arbitration, not a confirmed root cause. The temporary harness does not exercise native menu tracking or app launching.
- No new source files, preferences, or dock.json keys.

---

# P1 slice: click-and-hold menu and divider menu

Status: built; agent re-verified 2026-10-31 with `scripts/check-tile-input.swift` (mag off, bottom: PASS). Waiting for James's hand test. No new files, no dock.json changes. Log category `TileActions` ("press and hold: opening menu").

## Deliverables

- [x] Click-and-hold on an app tile (strip tiles, unpinned running apps, group tiles, Portside's own tile, group grid cells, Trash, folder stacks) opens the right-click menu at the tile. `menuHold(_:onTap:)` uses `onTapGesture` plus a simultaneous SwiftUI long press (0.5s, 4pt), not an exclusive sequence (exclusive swallowed short clicks in the non-activating hosting view). Moving more than 4pt first cancels it and the reorder or drag-out gesture takes over. A short click is unchanged (no added delay).
- [x] The release after a hold is not a click: `MenuHold.fired` suppresses the tap that would otherwise fire on release.
- [x] Same `RightClickView` popup as right-click, so placement per edge, hover label hiding and the grid-close-on-menu rules are shared. Panel untouched (still non-activating).
- [x] Divider right-click is now an AppKit menu: Turn Hiding On/Off, Position on Screen (Left, Bottom, Right, checkmark on the current, `setEdge`, live), Dock Settings... (opens Settings), Quit Portside. The old "Settings..." SwiftUI item is gone.
- [x] Magnification: the divider menu has Turn Magnification On/Off (built with magnification, 2026-10-31).

## Verification (agent)

- `swift build` clean; `scripts/build-app.sh` installed to `~/Applications/Portside.app`.
- `scripts/check-tile-input.swift` mag off bottom: PASS (2 short clicks launch Finder, 1 hold opens menu, no launch on hold release, Portside stays inactive). Mag-on AX hover was flaky in this session (Finder tile not in the tree); prior mag-on runs had PASS.

## Known gaps

- Real trackpad/mouse hand confirmation still needed (synthetic CGEvents only here).
- Releasing the button with the cursor over a menu item may pick it (native behavior); the menu opens 4pt off the tile so the cursor starts outside it.
- If drag-reorder, drag-out, file drops or spring-loading regress, suspect the long-press gesture on the tile first.

## Hand test (each edge: Bottom, Left, Right)

- [ ] Short click on an app launches or activates instantly; bounce unchanged; no focus stolen
- [ ] Press and hold still 0.5s: menu opens at the tile; release does not launch; menu items work; Escape closes
- [ ] Press and move before 0.5s: normal reorder; drag out still removes
- [ ] Same in an open group grid cell
- [ ] File drop on a tile and spring-loading a group still work
- [ ] Divider right-click: Turn Hiding, Position on Screen (checkmark, applies live), Dock Settings opens Settings
- [ ] Reveal timing in the log unchanged (mouseEntered to animation start about 1 to 2ms)

---

# Safety slice: confirm before removing a group

Status: built, `swift build` clean, `swift run` stays up, waiting for James's hand test. New file: `Sources/portside/GroupRemoval.swift`. Log category `GroupRemoval`. No dock.json changes.

## Deliverables

- [x] "Remove from Dock" on a group tile and dragging a group tile out both ask: "Remove group <name>?" / "This removes the group and its N apps from the dock." Buttons: Ungroup Instead (default, same as Ungroup), Remove Group (destructive), Cancel. Portside's icon.
- [x] Focus: `NSApp.activate()` for the alert, then the previously frontmost app is activated again (not when Settings was the frontmost app).
- [x] The hide timer refuses while the alert is up (`isConfirmingRemoval`); it is re-armed when the alert closes.
- [x] Drag-out: the overlay stays up without the poof (`end(_, deferResolution:)`) until the choice is made (`resolve(remove:)`). Cancel: tile is already in its slot, nothing saved. Remove: poof (none under Reduce Motion). Ungroup: overlay vanishes, group replaced by its apps.
- [x] Empty groups: no alert, removed as before (poof on drag). App tile removal untouched. Settings > Groups Delete already confirmed.

## Verification (agent)

- `swift build` clean; `swift run` stays up; SIGTERM leaves `autohide-delay` unset.
- Not run by the agent: the alert, all three buttons, drag paths, focus hand-back (need real clicks and drags).

## Follow-up fixes (James's test round 1)

- [x] Dragging a tile (including a group tile) off the strip closes any open grid at drag start, hover-opened or clicked; hover cannot open a grid mid-drag. Drags from inside a grid keep it open (`itemDragChanged(_, fromStrip:)`).
- [x] A context menu opened over the strip closes the open grid, so a group's right-click menu no longer sits on top of its own grid (`stripMenuOpened`). Menus inside the grid leave it open.
- [x] Icon rim: the running copy had been launched before the icon rebuild. After a relaunch Portside's tile is dark with the same rim as its neighbors (screenshot of the strip with Settings open).

## Known gaps

- Alert is modal and shown on the next run loop turn after the click or drop, so the dock may hold the overlay for a frame first.
- Under Reduce Motion the poof is skipped but the alert still shows.
- After a strip menu closes with the cursor still on a group tile, hover can open the grid again after the normal delay.

## Hand test

- [ ] Right-click a group > Remove from Dock: alert shows name and app count. Ungroup Instead: apps back as tiles in the slot. Repeat for Remove Group (gone) and Cancel (nothing changes)
- [ ] Frontmost app is the same before and after the alert; dock stayed up while it was open and hides after
- [ ] Drag a group tile out and release: alert. Cancel snaps the tile back, dock.json unchanged. Remove Group poofs. Ungroup Instead ungroups
- [ ] Empty group (if you can make one): no alert
- [ ] App tiles still remove instantly (menu and drag)
- [ ] Open groups on hover on: hover a group open, then drag that group tile: the grid closes as the drag starts
- [ ] Hover a group open, right-click its tile: grid closes, menu shows alone. Right-click a cell inside the grid: grid stays

---

# P1 slice: modifier clicks and app menu (Hide, Force Quit)

Status: built, `swift build` clean, waiting for James's hand test. New file: `Sources/portside/TileActions.swift`. Log category `TileActions`. No dock.json changes.

## Deliverables

- [x] Cmd-click on an app tile (strip, unpinned running, group grid cell): `activateFileViewerSelecting`, no launch, no bounce.
- [x] Option-click: opens or activates the app (bounce if not running) and hides the app that was frontmost. Cmd+Option-click: hides every other regular app. Computed at click time, hidden once the app is up (`afterOpen`). Never hides Portside or the clicked app.
- [x] Right-click menu is now an AppKit `NSMenu` (SwiftUI `.contextMenu` has no alternate items), shown by a right-click-only overlay (`appKitContextMenu`). Order: Keep/Remove from Dock, Add to Group, Show in Finder, separator, Hide or Show (`isHidden`), Quit. Group cells: Remove from Group first, no Add to Group.
- [x] Option swaps Quit for Force Quit (`isAlternate`, Option mask, `forceTerminate()`).
- [x] The menu opens above the tile, centered on it, like the native Dock (beside it on the side docks); the hover label hides while any menu is open. Verified on the bottom dock by screenshot; left and right not seen. Group grid cells use the bottom placement whatever the dock edge. `menu.size` counts the hidden Force Quit alternate, so it is measured without it.
- [x] Panel untouched: still non-activating; plain clicks take the old path.

## Verification (agent)

- `swift build` clean; `swift run` stays up; SIGTERM restores the Dock (`autohide-delay` unset).
- Synthetic right-click on the Messages tile showed the new menu (screenshot): Remove from Dock, Add to Group, Show in Finder, Hide, Quit.
- Not seen: modifier clicks, Force Quit swap with Option held, Show label, grid cells, left/right edges. Native Dock was not compared; behavior follows Apple's documented Dock shortcuts.

## Findings and gaps

- Hover label "Messages" stayed visible on top of the open menu (screenshot). Check if it was like this before.
- Option-click when the clicked app is already frontmost hides nothing.
- [x] "Open at Login" for other apps: built (see P1 leftover section above). Reads via LSSharedFileList; writes via System Events Automation.
- Cmd-click in a grid leaves the grid open.
- Hover label restyled to match the native Dock, measured from James's native screenshot (2x, scale checked against the text width): 14pt text, 25pt body, 14pt side padding, 11pt corner radius, 7pt tail with a flared base, thin light rim, tail tip 2.5pt past the dock edge. Our capture at the same scale matches within about 1pt. Synthetic CGEvents do not reveal the native Dock, so the agent could not capture it directly. Side-dock tails not seen.
- Hover label and drag-out "Remove" label now use the dock's own background (`dockBackground(_:in:)` with the bubble shape): same style (Liquid Glass, Frosted, Solid), frost, tint and rim as the strip. Seen with Frosted at 0.65 (screenshot); Liquid Glass and Solid only by code.

## Hand test

- [ ] Cmd-click an app: Finder reveals it, nothing launches or bounces (also in a grid cell)
- [ ] Option-click with a few apps open: clicked app comes forward, previous frontmost hides
- [ ] Cmd+Option-click: all others hide; not-running app launches with bounce, then others hide
- [ ] Right-click a running app: Hide, then again: Show
- [ ] Hold Option with the menu open: Quit becomes Force Quit; force quit a throwaway app
- [ ] Bottom, Left, Right; plain clicks and bounce unchanged, no focus stolen

---

# P1 slice: drag an icon out of the dock to remove it

Status: built and agent-verified, waiting for James's hand test. New file: `Sources/portside/DragOut.swift`. Log category `DragOut`. No new dock.json keys.

## Deliverables

- [x] Pinned app tile dragged clearly out and released: removed, same as "Remove from Dock" (`unpin`). A running app stays as an unpinned running app.
- [x] "Clearly out": the cursor is 24pt or more outside the dock panel's frame in any direction (`DragOutController.threshold`), so past the far side or past either end, on all three edges. The floating icon follows the cursor for the whole drag; the "Remove" label shows once outside. Overlay is an `OverlayPanel` (same non-activating, click-through class as the hover labels; its own instance so a hover label never replaces it). The cursor turns into the system "disappearing item" cursor while outside.
- [x] While outside, the tile goes back to its starting slot (strip gap stays empty), so a removal never reorders the rest. Back over the dock: label hides and the normal live reorder resumes.
- [x] Poof on removal: the icon scales up 1.5x and fades while eight soft puffs drift out (SwiftUI, 300ms, no private APIs). Reduce Motion: no poof, removal is instant.
- [x] Escape during the drag cancels: the item snaps back to where it started and nothing is saved. Portside is never active, so for the length of a drag the drag overlay takes key focus without activating Portside (same trick as inline group rename) and gives it back at the end or on Escape.
- [x] Group tiles: same as their "Remove from Dock", now behind a confirmation (see the safety slice above); running members stay as unpinned running apps.
- [x] Widgets: they already have "Remove Widget", so a widget dragged out and released is turned off the same way (`setWidget(_, enabled: false)`). Widgets still do not reorder in the strip; released over the dock nothing changes.
- [x] Open group grid: an app dragged clearly out and released asks Remove from Group (lands after the group tile; a one-app group becomes that app) or Remove from Dock (`unpin`), or Cancel. Label reads "Remove". Released inside the grid, nothing changes (members are not reordered).
- [x] Hide path: the drag start cancels a pending hide; exits during a drag do not arm it ("item drag in progress, hide not armed"); the hide timer also refuses while an item drag is on (button still held). After the drop the hide is re-armed with the normal delay if the cursor is outside. A hover-opened grid does not grace-close mid-drag.
- [x] No polling: everything runs from the gesture's changes plus a local key and mouse-up monitor installed only for the drag. The only timer is the one-shot that removes the poof overlay.
- [x] Clicks, file drops (`FileDrop.swift`), and in-dock reorder unchanged.
- [x] `swift build` clean, no warnings; `swift run` stays up

## Verification (agent, synthetic CGEvents)

Scratch dock.json (Finder, TextEdit, Calculator, Chess, two groups, Dictionary; clock and battery; `hideNativeDock` off so the native Dock was never touched). Real dock.json backed up and restored byte for byte (`cmp`).

- [x] Bottom: Chess dragged up and released: label and icon near the cursor (screenshot), removed, dock hid 300ms after the drop. Calculator out and back in: `outside` then `back over the dock`, reorder saved at the new slot. Calculator out then Escape: `canceled`, order unchanged on disk. Escape after an in-dock move: back to its original slot. Group "Doomed" out: removed with its apps; poof caught in two screenshots (scaling, puffs). Clock widget out: removed, widget stopped. Grid: Notes dragged out of the open TestGroup grid: removed from the group, placed right after it in dock.json. Preview moved inside the grid and released: nothing changed.
- [x] Left (auto-hide on): remove, out and back (reorder), Escape, and a grid member out of the group.
- [x] Right with hiding off: remove, out and back, Escape, group tile out (screenshot).
- [x] Dock stayed up during every drag, including a 1.2s hold outside with a 300ms hide delay. Panel exits during drags logged "hide not armed".
- [x] Focus: TextEdit frontmost, a reorder drag and then an Escape-canceled drag on the dock, typed keys landed in TextEdit both times; TextEdit stayed frontmost.
- [x] Plain click after the drags opened the app (`panel mouseDown (key window: false, portside active: false)`).
- [x] Reveal timing unchanged: mouseEntered to animation start 0.46 to 2.02ms.

## Findings

- A drag-out removal of a group tile is destructive with no undo; now asks first (safety slice above).
- The drag needs key focus for Escape, so for the length of a drag the frontmost app's window is briefly not key (keys typed mid-drag go nowhere). Focus comes back at the end (verified with TextEdit).
- Floating preview used to stay hidden while the cursor was over the dock (`DragOutView` opacity 0 on `.inside`), so reorder felt locked to the strip. Fixed: preview always follows the cursor; strip/grid tile opacity is 0 for the dragged id (gap + neighbor shift). "Remove" label still only when clearly outside.

## Known gaps

- Not seen by the agent: Reduce Motion (needs the system setting changed), the cursor change (screenshots do not show the cursor), and the feel of the poof at full speed.
- Grid members cannot be reordered by dragging; a member dragged onto the strip is removed from the group (lands next to the group), not placed where it was dropped.
- Unpinned running apps and Portside's own tile do not drag (nothing to remove), same as before.

## Hand test must also check

- [ ] Bottom, Left, Right: drag an app out (label shows, release removes with a poof)
- [ ] Drag out and back in: no removal, normal reorder
- [ ] Drag out, then Escape: snaps back, typing still goes to the frontmost app
- [ ] Drag a group tile out (removes the group and its apps)
- [ ] Drag an app out of an open group grid (leaves the group, appears next to it)
- [ ] Drag a widget out (turned off); a plain widget click still works
- [ ] Plain reorder and plain clicks unchanged; the dock stays up for the whole drag and hides after the normal delay
- [ ] With hiding off

---

# Appearance slice: icon style and dock background

Status: done and hand-tested by James. New file: `Sources/portside/DockAppearance.swift`. Log category `Appearance`. New dock.json keys: `iconStyle`, `backgroundStyle`, `backgroundFrost`, `backgroundTint`, `cornerRadius` (all optional on load; unknown values fall back to defaults).

## Deliverables

- [x] Icon style "Match macOS" (default): icons come from `NSWorkspace.icon(forFile:)`, which already used the system icon style (Dark here), but the cache never refreshed. Now `IconThemeObserver` watches the global `AppleIconAppearanceTheme` default (KVO) and light/dark mode (`NSApp.effectiveAppearance`, for the automatic styles) and drops every cached icon, Portside's own included.
- [x] Icon style "Original": each app's own `CFBundleIconFile` (.icns), so the system style is ignored. Apps with only a compiled asset catalog fall back to the system rendering. Portside's tile uses its flat PNGs.
- [x] Dock background: Liquid Glass (SwiftUI `glassEffect`, macOS 26+, default there), Frosted (the old `ultraThinMaterial` look, default before 26), Solid. Glass is clear glass with a `regularMaterial` layer blended in by the Frost slider (0% clear, 100% frosted). Frost doubles as material strength (Frosted) and fill opacity (Solid).
- [x] Tint toggle plus color picker with opacity (starts at brand navy, 35%); glass tints the glass itself, the others overlay the color.
- [x] Corner radius 4 to 28 pt (default 16).
- [x] Settings > Appearance tab with Reset to Defaults; changes apply live. Group grids use the same background.
- [x] Settings footers now left-align when they wrap.

## Verification (agent)

- `swift build` and `scripts/build-app.sh`: no warnings; bundle verifies.
- Prototype window compared clear glass at frost 0, 0.5, 1, regular glass, frosted, and solid over real windows: frost gives a smooth clear-to-frosted range.
- Cross-process KVO on the global domain: a test process saw `defaults write -g` changes of a scratch key (deleted afterwards). The real `AppleIconAppearanceTheme` was not changed by the agent.
- Drawing an icon under `.aqua` vs `.darkAqua` does not change it: the icon style is a system setting, so there is no public way to show a style other than the system's. Hence only Match macOS and Original.
- Ran the debug build: Appearance tab renders (screenshot), the strip draws with glass.

## Known gaps

- Not seen by the agent: a real system icon style change refreshing the dock (needs James to switch it), and glass over a bright or busy desktop.
- Glass needs macOS 26; older systems show Frosted and hide the Liquid Glass option.
- The macOS "Liquid Glass: Clear / Tinted" preference (`NSGlassTintAmount`) is applied by the system glass itself; Portside does not read it.
- Hover labels keep their own style.
- Widget cards were an 8% white fill over the dock background, so low Frost made them see-through. They now have their own `regularMaterial` backing (plus the same white fill) in `WidgetTile`, independent of style, frost and tint. Seen over T3 Code with the current settings (screenshot); not checked at Frost 0 or with Solid.

## Hand test must also check

- [x] System Settings > Appearance > Icon and widget style: switch Default, Dark, Clear, Tinted; the dock's icons follow within a moment, without a relaunch
- [x] Icon style Original: colorful app artwork regardless of the system style
- [x] Background Liquid Glass, Frost 0% / 50% / 100% over a colorful window; compare with the native Dock
- [x] Frosted and Solid, tint on/off, corner radius; group grid matches
- [x] Reset to Defaults; relaunch keeps the settings

---

# Branding slice: approved sail identity

Status: done and hand-tested by James. New files: `Sources/portside/BrandAssets.swift`, `Sources/portside/Support/AppIcon-{16,32,128,256}.png` (actool's flat render of `AppIcon.icon`), `Sources/portside/Support/MenuBarIcon-{22,44}.png` (copies of `design/brand/menu-bar/portside-menu-bar-black-*`). Log category `Brand`.

## Deliverables

- [x] Bundle icon: `scripts/build-app.sh` compiles `design/brand/icon-composer/AppIcon.icon` with `xcrun actool` into `Assets.car` plus a flat `AppIcon.icns`, and sets `CFBundleIconName`. If actool fails it prints the log and copies the approved .icns; if that is missing, `--export-icon` renders one.
- [x] Runtime icon (`AppIcon.swift`): the hand-drawn bird is gone. In Portside.app (with `CFBundleIconName`) the icon is `NSWorkspace.icon(forFile:)` of the bundle, so it is the system's Liquid Glass rendering in the current icon style, at the same size as other apps; the native Dock tile is left to macOS. Under `swift run`, the bundled PNGs, one representation per size. Used by the Settings header, Portside's own dock tile, the unbundled native Dock tile, both alerts, and About.
- [x] Menu bar: brand mark as a template image (22pt, 1x and 2x). The supplied black PNGs are already pure black with alpha, so no new template was generated. Title and accessibility label stay "Portside".
- [x] Resources: `BrandAssets` finds `portside_portside.bundle` in `Contents/Resources` (app) or next to the executable (`swift run`) without `Bundle.module`. Missing bundle or file: logged, generic app icon and `sailboat.fill` fallback, no crash.
- [x] "About Portside" in the menu bar item: standard About panel, brand icon, version, short hash on unreleased builds, "by James Cliff" and the repo link.
- [x] README branded header (wordmark `<picture>`, tagline, macOS and Swift badges, brand guide link); features and layout updated.
- [x] Colors: unchanged. The tokens define navy, sailcloth, and safety orange but no accent, and the Settings window keeps the system accent.
- [x] `swift run` icon: borrows the system rendering from a Portside.app that LaunchServices knows (bundle id `com.james.portside`, must have `CFBundleIconName`), so the dev build looks like the real one. The flat PNGs are only the last fallback; they have a lighter rim and no dark style, which made the icon stand out (James's screenshot was the `swift run` build).
- [x] Settings window opens dead center of the visible area of the screen with the cursor, every time it opens (not `NSWindow.center()`, which sits high). Layout fits in the first 0.5s keep it centered; later tab switches keep the top edge. Saved position removed (`NSWindow Frame PortsideSettings` deleted from defaults).
- [x] Icon Composer `.icon` via `actool`: James re-saved it in Icon Composer (navy fill, one SVG layer); compiles with no errors or warnings. Layer file renamed to `portside-sail-master.svg` (icon.json updated).

## Verification (agent)

- `swift build` and `scripts/build-app.sh`: no warnings. `codesign --verify --deep --strict`: valid with `Assets.car`; the resource bundle's PNGs are sealed (appending a byte to one fails verification).
- actool failure path: build pointed at a broken `.icon` printed the actool errors, fell back to the approved .icns (no `Assets.car`, no `CFBundleIconName`), and still verified.
- Portside's own dock: the Portside tile is the same size as its neighbors and uses the system dark icon style, like the other apps (screenshot).
- `swift run` log: "unbundled: using the system icon of .../build/Portside.app"; Settings header shows the system rendering.
- Settings frame (window server coordinates) 604,111 520x927 on a 1728x1117 screen with a 33pt menu bar: centered on the visible area to the half point.
- `open build/Portside.app` (cwd `/`): log shows the resource bundle in `Contents/Resources`. `swift run portside`: bundle found in `.build/out/Products/Debug`.
- App copy with the resource bundle deleted and re-signed: launches, logs three fallback errors, no crash. `--export-icon` still writes a PNG in both cases (1024px brand PNG when present).
- Screenshots: Settings header, Portside's own dock tile, About panel. Finder icon checked through `NSWorkspace.icon(forFile:)` (LaunchServices).
- Menu bar template checked offscreen only (light and dark appearances); the real item is in Bartender's hidden section.

## Findings

- The approved PNG/.icns artwork is full bleed (fills the 1024 canvas, no macOS icon grid margin), so it looked about 24% larger than other apps and had no Liquid Glass. Fixed by building from the Icon Composer document instead; the flat .icns is now only the fallback.
- The first `.icon` (one PNG layer, `"fill": "none"`) was rejected by actool ("The data couldn't be read because it isn't in the correct format"). The version re-saved from Icon Composer compiles.
- actool's flat `AppIcon.icns` only holds 16, 32, 128, and 256 px; the larger sizes live in `Assets.car`.
- SwiftPM's `Bundle.module` looks for the resource bundle beside `Portside.app`, not in `Contents/Resources`, and would `fatalError` in the packaged app.
- The v2 package has no app mockups or screenshots, so the README shows no app imagery.
- The `.icon` had only a solid navy fill with no dark variant, so with the Dark icon style the system still drew the light rendering (navy, light glass rim) while every other app got the dark one (seen in the remove-group alert and Portside's own tile). Fixed by a `fill-specializations` entry in `icon.json`: navy by default, `automatic` for the dark appearance. Rendered through `NSWorkspace.icon(forFile:)` next to Messages and Notion: background and rim now match. Dark style no longer shows navy.

## Known gaps

- Real menu bar appearance (light, dark, tinted) and the native Dock tile not seen by the agent.
- `Sources/portside/Support/` holds copies of the brand PNGs; re-copy them if the brand files change (AppIcon PNGs: `iconutil -c iconset` on actool's `AppIcon.icns`).
- Under `swift run` without any built Portside.app, the icon is the flat light render (no glass, does not follow the icon style).
- The system icon is read once per launch; changing the icon style while Portside runs updates Finder and the native Dock but not Portside's own tile until relaunch.

## Hand test must also check

- [x] Menu bar item in light mode, dark mode, and over a tinted wallpaper
- [x] Icon in Finder (`build/Portside.app`) and in the native Dock while Settings is open, both bundled and `swift run`
- [x] About Portside: comes forward, link opens the repo
- [x] Alert icon (Settings > Hide the macOS Dock first-time dialog)

---

# Milestone F part 3: import from the native Dock

Status: done and hand-tested by James (first launch and the Settings sheet). New file: `NativeDockImport.swift`. Reads `com.apple.dock` through CFPreferences only, never writes it. Log category `Import`.

## Deliverables

- [x] First launch (no dock.json): pinned apps, `orientation` (missing = bottom) and `tilesize` (clamped to 16...128 and to what fits) become the initial apps, position and icon size. If `native-dock-backup.json` exists, orientation and tilesize come from its saved values.
- [x] Settings > General > Import: "Import from macOS Dock..." opens a sheet with the summary (apps, native position and size, folder/file tiles and missing apps to be skipped), the apps choice (Add missing, default; Replace apps, keep widgets and groups), a checkbox for position and size (off by default), and the undo note.
- [x] Before applying, dock.json is saved and copied to `dock.json.before-import` (overwritten each time). "Undo last import" shows only while that file exists, restores it live and deletes it.
- [x] Native order, Finder first. Missing paths skipped and counted. Spacer tiles skipped, `persistent-others` counted and skipped. Counts logged.
- [x] Add missing: appends new apps after the existing entries, never removes or reorders. Replace: top level apps replaced by the native list; groups keep their slots; apps already inside a group are not duplicated. Widgets, separators, other settings untouched. Applies live.
- [x] `persistent-others` folders import as stacks (grid-first P2 slice). Plain file tiles still skipped.

## Verification (agent)

- First launch on the real prefs (dock.json moved aside): log `read native Dock: 27 apps, 0 missing, 0 spacers skipped, 1 folder/file tiles skipped, edge bottom, tilesize 37.0 (live)`; dock.json got edge bottom, iconSize 37, 27 entries. dock.json restored byte for byte afterwards.
- `swift build` and `swift build -c release`: no warnings. No native Dock key written (autohide-delay still unset).
- Not run by the agent: the sheet, Add missing, Replace, Undo, and the backup-sourced path (a fake backup would trigger launch recovery and touch the Dock). Covered by James's hand test.

## Findings

- Native `orientation` is absent on this Mac (bottom is the default), `tilesize` is 37.
- Undo restores everything in dock.json except `hideNativeDock` and `nativeDockExplained`, which describe the real Dock and must not go stale.
- The first-launch icon size clamp is an estimate (no strip yet); the strip clamps again at render time. The manual import uses the live strip limit.
- Settings window height now includes the Import section; the Form fits it.

## Known gaps

- Undo is one level deep and also reverts any other change made after the import.
- Folder and file tiles are not imported.

## Hand test must also check

- [x] Settings sheet: Add missing, Replace apps, position and size checkbox, Undo last import

---

# Milestone F part 2: .app bundle + launch at login

Status: done and hand-tested by James. New files: `scripts/build-app.sh`, `Sources/portside/LaunchAtLogin.swift`.

## Deliverables

- [x] `scripts/build-app.sh` (bash, no network): `swift build -c release`, assembles `build/Portside.app` (`Contents/MacOS/portside`, `Contents/Info.plist`, `Contents/Resources/AppIcon.icns`, plus any SPM resource bundles)
- [x] Info.plist built from the repo's `Info.plist` (one source for the Calendar strings) with `plutil -replace`: executable, bundle id, name, display name, APPL, version and build from `VERSION`, `LSMinimumSystemVersion` 14.0, `LSUIElement`, `NSHighResolutionCapable`, `CFBundleIconFile`. Linker-embedded plist kept for `swift run`.
- [x] Hidden `portside --export-icon <path.png>`: renders `AppIcon` at exactly 1024px and exits before any UI. Missing path prints usage, exit 2.
- [x] `.iconset` (16 to 512 @1x/@2x via `sips`) and `AppIcon.icns` via `iconutil`
- [x] Ad-hoc signing by default, `SIGN_IDENTITY` for a real identity, `codesign --verify --deep --strict` after signing
- [x] `--install`: copies to `~/Applications/Portside.app` with `ditto`, refuses while that copy is running. Never `/Applications`.
- [x] `build/` in `.gitignore`
- [x] `LaunchAtLogin.swift`: `SMAppService.mainApp` register/unregister, status read on every Settings open and after each toggle, nothing in dock.json, os.Logger category `LaunchAtLogin`
- [x] Settings > General > Startup: "Open Portside at login". enabled = on; notRegistered = off; requiresApproval = on plus helper line and "Open Login Items Settings..." button; notFound = off plus explanation; failures show a red inline error and the toggle snaps to the real status
- [x] Unbundled (`swift run`): toggle disabled with "Available when running Portside.app."
- [x] `swift build` (debug) and `swift build -c release`: no warnings

## Verification (agent)

- `codesign --verify --deep --strict --verbose=2`: valid on disk, satisfies its Designated Requirement. `codesign -dv`: Identifier com.james.portside, adhoc, Info.plist entries=14.
- `plutil -lint` OK; `plutil -p` shows every required key.
- `build/Portside.app/Contents/MacOS/portside --export-icon /tmp/p2.png`: wrote a 1024x1024 PNG, exit 0. Image checked visually.
- `open build/Portside.app`: process runs from the bundle path, cwd `/`. Log shows dock.json loaded and "launch: Hide the macOS Dock is on, hiding" with the exact values saved; `autohide-delay` became 1000000. So the login launch path (same `applyAtLaunch`) does not depend on a terminal or working directory: data paths come from `FileManager` Application Support, `killall` is called by absolute path.
- Menu bar item exists (System Events: "Portside", status menu, 92x24) but Bartender put it in its hidden section (x = -1).
- Opened Settings from the menu via System Events: log `LaunchAtLogin status: notFound`.
- Quit via AppleEvent: `autohide-delay` back to unset (as before). `swift run portside` still launches; SIGTERM restores the Dock.
- Did not toggle the login item or run `--install` (left to the hand test).

## Findings

- On macOS 27, `SMAppService.mainApp.status` is `notFound` before the app was ever registered, not `notRegistered`. The notFound helper text is therefore phrased as "Not registered with macOS yet" instead of an error.
- New SPM puts the debug binary at `.build/out/Products/Debug/portside`; the script asks `swift build --show-bin-path` instead of assuming a path.
- The Settings window's saved frame was mostly off screen (top at y 972 of 1117); moved it back on screen through System Events while testing, which updated the saved frame.
- Generic icon: the bundle has a real `AppIcon.icns`, so Finder and the native Dock should show it without the runtime dock-tile workaround (still in place, harmless). Needs the hand test to confirm.
- Bartender: the bundled app has a stable bundle id, so Bartender should remember its menu bar item across launches. Unconfirmed: on the first bundle launch it treated the item as new and hid it.

## Known gaps

- Ad-hoc signatures change every build: Calendar permission may be asked again, and Login Items may list a stale or duplicate entry after a rebuild. A self-signed `SIGN_IDENTITY` avoids both.
- The login item points at whichever copy registered it. Register from `~/Applications/Portside.app`, not `build/`.
- Not notarized and no hardened runtime (personal use only).
- Registration itself (enabled, requiresApproval, failures) is untested by the agent.

## Hand test must also check

- [x] Icon in Finder and in the native Dock while Settings is open
- [x] Toggle on: Portside listed in System Settings > General > Login Items
- [x] Log out and in: Portside starts, and hides the native Dock if that option is on
- [x] Toggle off: removed from Login Items
- [x] `swift run portside`: toggle disabled with "Available when running Portside.app."
- [x] Bartender keeps the menu bar item placement across two bundle launches

---

# Tooling slice: automated versioning

Status: done, hand-tested by James and committed. New files: `VERSION`, `scripts/gen-version.sh`, `scripts/release.sh`, `Sources/portside/BuildInfo.swift`.

## Deliverables

- [x] `VERSION` at the repo root (`0.1.0`) is the only place the version number is edited.
- [x] `scripts/gen-version.sh` (bash 3.2, no network) writes `Sources/portside/BuildInfo.swift`: version, short commit hash, dirty flag, release flag. Marked as generated. Commit and dirty fall back to `"unknown"` / `nil` without git. Rewrites only on change.
- [x] `BuildInfo.swift` is meant to be committed so `swift build` works without running the script.
- [x] `AppInfo` reads version, commit, dirty and release from `BuildInfo`. Header: "Version 0.1.0 by James Cliff", plus ` (abc1234)` for unreleased builds or ` (abc1234-dirty)` for dirty ones. Header layout untouched (`SettingsWindow.swift` not edited).
- [x] `scripts/release.sh patch|minor|major`: dry run by default; `--apply` refuses on a dirty tree or an existing tag, bumps `VERSION`, runs `gen-version.sh --release`, one commit "Release vX.Y.Z", annotated tag vX.Y.Z, never pushes, prints the push and `gh release create` commands.
- [x] README "Versioning and releases" section.
- [x] `swift build` clean, no warnings; launches and stays up

## Verification (agent)

- `gen-version.sh` run twice: second run reports "unchanged". In a non-git copy it writes commit `"unknown"`, `isDirty: nil`.
- `release.sh minor` dry run printed 0.1.0 -> 0.2.0, the dirty-tree warning, the steps, and the push commands. `VERSION` unchanged afterwards.
- No args and a bogus arg print usage (exit 2). `release.sh patch --apply` on the dirty tree refused before changing anything (exit 1).
- The full `--apply` path (commit and tag) was not run, per instructions.

## Findings

- The release commit can't contain its own hash, so `--release` writes the pre-release HEAD as `commit` and sets `isRelease = true`, which hides the hash in the header.
- `BuildInfo.swift` is excluded from the dirty check, otherwise regenerating it would mark the next run dirty.
- The author was "James" in `AppInfo`; changed to "James Cliff" to match the requested header text.

## Known gaps

- `BuildInfo.swift` is only as fresh as the last `gen-version.sh` run. Nothing runs it automatically before `swift build` (that needs an SPM build plugin). After a release, it still says release until regenerated, so dev builds show no hash until you run the script.
- Running the script on a dirty tree changes the committed `BuildInfo.swift`; commit or discard it as you like.
- No tags exist yet, so until the first release the header shows the hash.

## Hand test must also check

- [x] Settings header reads "Version 0.1.0 by James Cliff (<hash>-dirty)" now, and the same look as before otherwise
- [x] After committing, `scripts/gen-version.sh` then `swift run`: header shows the clean hash
- [x] `scripts/release.sh patch` prints a dry run and changes nothing (`git status`)

---

# UX slice: Settings window redesign

Status: done, hand-tested by James and committed. Visual and layout only: no behavior, settings key, or dock.json changes. New files: `AppInfo.swift`, `UpdateChecker.swift`.

## Deliverables

- [x] One container level: a grouped `Form` per tab, no bordered tab pane.
- [x] Branding header above the tabs: app icon, "Portside", "Version 0.1.0 by James", Check for Updates. Name, author, version, and repo URL live in `AppInfo.swift`.
- [x] Toolbar-style tabs (SF Symbol above label): General, Widgets, Groups. Title stays "Portside Settings".
- [x] Window 520pt wide; height fits the selected tab (animated, top edge fixed, off under Reduce Motion). Opens dead center (see Branding slice); the old saved position key is deleted. Cmd+W closes.
- [x] Continuous sliders (no ticks), values snapped in the binding (delays and animation to 10ms, icon size to 1pt), fixed label column, right-aligned monospaced value.
- [x] Helper text 12pt secondary, directly under its control; unneeded helper text removed.
- [x] General: Dock (Position, Icon size, Hide dock automatically, Animate opening applications), Timing (with Reset to Defaults in the header), macOS Dock (toggle plus two helper lines incl. the Cmd+Option+D note). Fits without scrolling (686pt content), so Timing stays on General.
- [x] Magnification row and "Coming soon" removed; `magnificationEnabled` stays in dock.json.
- [x] Widgets: one list, icon + name + switch. Up/down arrows removed; Move Up and Move Down are accessibility actions.
- [x] Groups: hover options (sliders and footer only while hover is on), then the group list: mini icon, inline name that looks like plain text until hovered or focused, app count, Ungroup, Delete (with confirmation). Centered empty state.
- [x] "Hide the macOS Dock?" alert (and the other native Dock alerts) use Portside's icon instead of the generic alias folder.
- [x] Check for Updates is a stub: shows "Update checks aren't set up yet." under the version line for 4s, no network calls. `UpdateChecker.check()` is the one function to fill in.
- [x] `swift build` clean, no warnings; launches and stays up

## Verification (agent)

- Screenshots of every tab, dark and light, with and without groups, plus the alert. Round 1 fixes: footers were trailing-aligned, the icon showed a clipped square shadow at small sizes (fixed with `AppIcon.bitmap`), title bar separator doubled the tab divider, macOS Dock helper wrapped. Round 2 fixes: footer inset to match section headers, header height pinned so the update status line does not resize the window, disabled widget icons dimmed, name field padding.
- Synthetic drags: Clock dragged below Weather and back; `widgetKinds` in dock.json followed both moves.
- Tab switch heights: General 686, Widgets 410, Groups 460 (top edge stays put). Cmd+W closed the window. A saved frame was restored at launch.
- dock.json backed up and restored byte for byte (`cmp`); native Dock restored on stop and hidden again on relaunch.

## Findings

- A grouped `Form` ignores `ForEach.onMove`; a plain `List` reorders but loses the grouped look and its content height cannot be read. Widget rows reorder with `onDrag`/`onDrop` instead and move live under the cursor, without the native insertion line.
- `AppIcon.image` redraws its vector handler at every size and its shadow blur does not scale, so small renders showed a square edge. `AppIcon.bitmap` renders it once at 512px.
- No git hash in the header: SwiftPM has no clean way to pass a build-time string without a build plugin, so it was skipped. (Later solved by the versioning slice: a generated, committed `BuildInfo.swift`.)

## Known gaps

- Fitting the window to the tab needs macOS 15 (`onScrollGeometryChange`). On macOS 14 every tab uses a fixed 470pt content height and scrolls if needed.
- Widget reorder is drag and drop, not the native list move (see Findings).
- Deferred: Update checker: compare AppInfo.version with the latest GitHub release tag, show 'up to date' or a link to the release.

## Hand test must also check

- [x] Each tab looks right in dark and light; switching tabs resizes smoothly with no jump
- [x] Drag a widget row to reorder; the dock follows. VoiceOver actions Move Up/Move Down work
- [x] Hover a group name: outline appears; click to rename, Return or click away saves; blank reverts
- [x] Delete still asks first; Ungroup puts apps back
- [x] Turning "Open groups on hover" off hides the two sliders and footer
- [x] Check for Updates shows the status line, which clears after a few seconds
- [x] Close and reopen Settings: always opens centered. Cmd+W closes
- [x] First-time "Hide the macOS Dock?" alert shows the Portside icon (reset `nativeDockExplained` to see it again)

---

# F slice: hide the macOS Dock (autohide-delay trick)

Status: done, hand-tested by James and committed. New files: `NativeDock.swift`, `NativeDockController.swift`.

## Deliverables

- [x] Settings > General > macOS Dock: "Hide the macOS Dock" (`hideNativeDock` in dock.json, off by default). The toggle only turns on after a verified hide.
- [x] First-time dialog (once, `nativeDockExplained`): what changes, that position and size are untouched, how to undo. Cancel leaves everything as is.
- [x] Before any write: exact values (with plist type) of `autohide`, `autohide-delay`, `autohide-time-modifier`, `orientation`, `tilesize`, `magnification`, `largesize`, `show-recents` saved to `native-dock-backup.json`, with keys that did not exist marked `existed: false`. The backup is read back before anything is written.
- [x] An existing backup is never overwritten. Hide refuses while one exists (unless it is ours and the Dock is still hidden, then it is a no-op).
- [x] Hide writes only `autohide = true` and `autohide-delay = 1000000` (real) through CFPreferences, runs `killall Dock`, reads both back, then marks the backup `hidden`.
- [x] Restore writes every saved key back (deletes ones that did not exist), restarts the Dock, verifies all 8 keys, then deletes the backup. On any failure the backup stays for a retry.
- [x] Restore triggers: toggle off, normal quit (applicationWillTerminate), SIGTERM, SIGINT, SIGHUP, menu bar "Restore macOS Dock", and `portside --restore-dock`.
- [x] Crash safety: at launch, before SwiftUI or AppKit start (`PortsideMain`), any backup (state `applying` or `hidden`) is restored. If the setting is still on, Portside then hides again with a fresh backup.
- [x] Hide failure (write, Dock restart, verify): rolls back from the backup, logs, setting stays off, alert shown.
- [x] Refuses to hide if `autohide-delay` is already 1000s or more (another app, for example a crashed Dockset, hid the Dock this way), since that value would be saved as the "real" one.
- [x] Every step logged under category `NativeDock`. Nothing outside `com.apple.dock` is written. No private APIs.
- [x] `swift build` clean, no warnings; `swift run` stays up

## Verified on the real Dock (agent)

`defaults read com.apple.dock` snapshot taken before, plus a full `defaults export` as a safety net. dock.json backed up and restored byte for byte (`cmp`).

- [x] Launch with the setting on: backup correct (autohide bool true, autohide-delay and three others `existed: false`, tilesize real 37), `autohide-delay` reads back 1000000 (float).
- [x] SIGTERM, SIGINT, normal quit (Apple Event quit, so applicationWillTerminate), and `kill -9` then relaunch (log: `launch: found a native Dock backup ... restoring`, then re-hide), and `kill -9` then `portside --restore-dock` (exit 0): each left the diff against the snapshot empty except `last-analytics-stamp`, and removed the backup.
- [x] `--restore-dock` with no backup prints "No backup ..." and exits 0.
- [x] Screenshot with the cursor resting on the bottom edge while hidden: only Portside's dock appears. After restore, the native Dock reveals normally.

## Verified on a scratch prefs domain (agent)

Copy of `NativeDock.swift` pointed at `com.james.portside.ndtest`, a temp backup folder, and `/usr/bin/true` instead of `killall` (13 checks, all pass, domain deleted after):

- [x] Prior state autohide off, `autohide-delay` 0.2 (real), `tilesize` 48 (integer), string, array and missing keys: restored exactly, types preserved.
- [x] Autohide flipped and tilesize changed mid-session: restore puts the saved values back.
- [x] Second hide while hidden leaves the backup untouched; restore with no backup is a no-op.
- [x] Refuses to hide when `autohide-delay` is already 1000000; refuses with an unrestored `applying` backup and leaves it byte for byte; launch recovery restores from `applying`.
- [x] A damaged backup is not treated as "none": restore throws and keeps it, hide refuses, prefs untouched.

## Findings

- The Dock rewrites `last-analytics-stamp` every time it restarts, so a `defaults read` diff after any Dock restart shows that key. It is not one of ours. Filter it out of the hand test diff.
- The system shortcut Cmd+Option+D ("Turn Dock hiding on/off") toggles the native Dock's `autohide`. While Portside is hiding the native Dock, pressing it turns native auto-hide off and the native Dock appears permanently until restore (restore puts the saved value back). It is also the same key combo as Portside's own auto-hide hotkey. Disable it in System Settings > Keyboard > Keyboard Shortcuts > Launchpad & Dock.
- Escape hatch if Portside is gone and the native Dock is stuck hidden: `portside --restore-dock`, or by hand `defaults delete com.apple.dock autohide-delay; killall Dock` (only if the delay did not exist before, which is the case on this Mac).
- The `CGWindowList` probe is useless for "is the native Dock revealed": a full-screen Dock window at layer 20 is on screen whenever the cursor is at any edge, hidden or not. Screenshots work.

## Known gaps

- If Portside crashes and is never relaunched, the native Dock stays hidden until `--restore-dock` or the next launch. Uncaught crashes (SIGSEGV, SIGABRT) are not handled in-process, since prefs writes are not safe in a signal handler.
- Restore puts back all 8 saved keys, so a native Dock change made in System Settings while hiding is on (for example size) is reverted on restore. Logged as `changed while hidden`.
- After a crash, relaunching with the setting on restarts the Dock twice (restore, then hide).
- `--restore-dock` while Portside is running restores anyway; the running copy still shows the setting on until it is toggled or quit (quit then finds no backup, which is fine).
- Launch at login and native Dock import (rest of F) not started.

## Hand test must also check

- [x] (a) to (f) from the report: before snapshot, enable, disable, quit, kill -9 plus relaunch, `--restore-dock`, each diff empty except `last-analytics-stamp`
- [x] First-time dialog appears once; Cancel leaves the toggle off and the Dock untouched
- [x] Menu bar "Restore macOS Dock" restores and turns the toggle off; with nothing to restore it says so

---

# P1 slice: spring-loaded groups during file drags

Status: done, hand-tested by James and committed. No new files.

## Deliverables

- [x] A file drag resting on a group tile opens its grid after 600ms (`GroupController.springLoadDelay`). One-shot cancelable `DispatchWorkItem`, armed when the drag reaches the tile, canceled when it leaves the tile, exits the strip or drops. No polling.
- [x] If another group is already open, the drag switches to the new group at once (same as hover).
- [x] Member cells in the grid take file drops with the strip's rules (`FileDropSession`): only a member that can open every dragged item highlights (same rounded highlight as a dock tile) and accepts the drop; the rest propose `.forbidden`.
- [x] Dropping on a member opens the file in that app and closes the grid. A not-running member bounces in the grid first (same as a click), then the grid closes when it lands.
- [x] The grid is part of the drag region: its drop delegate reports enter/exit to the engine as a fourth drag target (`"group"`), so the hide timer does not hide while the drag is over it. Tile to grid is seamless (the grid's bridge covers the gap).
- [x] Drag leaves both tile and grid: the hover close grace applies, then the grid closes; the dock hides on the normal delay.
- [x] A spring-loaded grid is transient (opened as by hover), so the existing hover-opened rules apply after the drag ends.
- [x] Non-app files dropped on the group tile itself: still rejected (op 0).
- [x] `.app` drags: unchanged. They never spring-load; dropping one on a group tile pins it as its own tile at that slot (pulling it out of a group if it was in one), as before. The grid rejects `.app` drags, which matches before (the overlay was not a drop destination). In practice a grid cannot be open during a `.app` drag from another app anyway: the mouse down that starts the drag closes any open grid (outside-click monitor).
- [x] Bottom, Left, Right, and hiding off. Overlay panel unchanged (non-activating); the target app came forward after each drop.
- [x] Hover reveal timing unchanged: mouseEntered to animation start 0.60 to 1.73ms.
- [x] `swift build` clean, no warnings; `swift run` stays up

## Changes

- `GroupController.swift`: `dragOverGroupTileChanged(_:)` (arms/cancels the spring-load), `dragOverGridChanged` (drag-region tracking, cancels or starts the grace close), `onDragOverGrid` callback, `launch` takes `documents`. The grace-close check also stays open while a drag is over the grid or the tile. A close while a drag is over the grid reports the drag exit, so the engine never keeps a stale drag target.
- `GroupViews.swift`: `GroupFileDropDelegate` on the card plus bridge (not the shadow), cell frames via a preference key in a named space, drop highlight on `GroupAppCell`.
- `DockStrip.swift`: the strip's drop delegate reports the group tile under an open-mode drag through `DockInteractions.onDragOverGroupTile` (nil on exit, drop, or pin mode).
- `DockEngine.swift`: wires the two new callbacks; `"group"` joins the drag targets.

## Verification (agent, synthetic drags)

Throwaway harness in `/tmp/portside-spring` (real drag session from its own window, CGEvents). A test group (TextEdit, Preview, Calculator) was added for the run; `dock.json` backed up and restored byte for byte (`cmp`).

- [x] Spring-load opened after 601 to 630ms on the tile, all edges. A 370ms pass over the tile: `spring-load: canceled`, no grid.
- [x] Bottom: `.txt` on TextEdit (not running): highlight in a screenshot, bounce in the grid, opened in 77ms, grid closed after landing, TextEdit frontmost, dock hid once the grid was gone. `.txt` on Calculator: op 0. `.txt` dropped on the group tile: op 0. `Chess.app` on the group tile: no spring-load, pinned (op 1).
- [x] Left: `.png` on Preview opened (op 1, Preview frontmost); `.txt` on Calculator op 0; drag away closed the grid then hid the dock.
- [x] Right: `.txt` on TextEdit (running) opened in 24ms; `.txt` on Preview op 0; drag away closed and hid.
- [x] Hiding off: spring-load, `.png` on Preview opened, `.txt` on Calculator rejected, grid closed after the drag left. No hide armed.
- [x] Strip to grid: `strip drag exited` arms the hide, then `group draggingEntered` cancels it within 1ms.

## Findings

- SwiftUI does not call `performDrop` when the last proposal was `.forbidden`, so rejected drops on the grid or group tile log nothing beyond the drag exit.
- After a drop SwiftUI sends one more `dropUpdated` after `performDrop`, which asks for a can-open answer with an empty session (logged as `can open: false`). Harmless; the next drag resets the cache.
- Plain-hover group opening could not be checked with synthetic `mouseMoved` events (it did not open on the unmodified build either), so it is in the hand test. Its code path only gained spring-load cancels.

## Known gaps

- Folder stacks do not exist yet, so only app groups spring-load.
- No visual cue while the 600ms delay runs (the native Dock flashes the tile).
- The delay is fixed at 600ms, not a setting.

## Hand test must also check

- [x] Bottom, Left, Right: drag a file from Finder onto a group tile; the grid opens after about 600ms
- [x] Move onto a member that can open it: highlight, drop opens it in that app, app comes forward, grid closes
- [x] Onto a member that cannot: no highlight, no green plus, drop does nothing
- [x] Drag away without dropping: grid closes, dock hides
- [x] With hiding off, the same, minus the hide
- [x] Plain hover-open of groups (no drag) still works

---

# P1 slice: drop files onto app tiles to open them

Status: done, hand-tested by James and committed. New file: `FileDrop.swift`.

## Deliverables

- [x] While a file drag is over an app tile (pinned or running-unpinned), the tile shows a rounded highlight only if the app can open every dragged item (`NSWorkspace.urlsForApplications(toOpen:)`). Finder also takes folders.
- [x] No capable tile under the cursor: no highlight, the proposal is `.forbidden` (no green plus), and the drop is rejected (drag session reports operation 0).
- [x] Drop opens the items with `NSWorkspace.open(_:withApplicationAt:configuration:)`, `activates = true`. A not-running pinned app launches with the existing bounce; running or unpinned apps just open.
- [x] `.app` drags keep pinning: empty strip space, between tiles, on a tile or on a widget all pin at the slot under the cursor (clamped to the end), as before.
- [x] Decision: a drag made only of `.app` bundles always pins, even when dropped right on another app tile (no highlight, no "open with"). Opening an app with another app is rare; pinning is what a dock drag almost always means. A mixed drag (apps plus other files) is treated as an open and needs a tile that can open every item.
- [x] Groups, Portside's own tile, widgets and separators reject non-app drops.
- [x] Drag tracking from the reveal slice unchanged: the dock stays up during the drag, the hide timer does not hide, normal hide after the drop.
- [x] Panel stays non-activating; drops worked with the test app frontmost.
- [x] Bottom, Left, Right, and hiding off.
- [x] `swift build` clean; `swift run` stays up

## Changes

- `FileDrop.swift` (new): `FileDropSession` reads the dragged file URLs from the drag pasteboard (`NSPasteboard(name: .drag)`) once per drag, picks pin or open mode, and caches the can-open answer per app for the rest of the drag. Reading the pasteboard is synchronous; `DropInfo`'s item providers only load asynchronously, which is too late for a highlight that follows the cursor.
- `DockStrip.swift`: `AppFileDropDelegate` became `FileDropDelegate`. Hit-tests the cursor against the hover target frames (same half-gap slop as labels, so no flicker between tiles), sets `dropTargetID`, proposes `.copy` or `.forbidden`, and opens or pins on drop. Still reports enter/exit/drop to `DockInteractions.onDragOverStrip`.
- `DockItem.swift`: `DockItemView.isDropTarget` draws the highlight (background with negative padding, so layout never moves). `AppLauncher.open` takes optional `documents`.
- `LaunchBounce.swift`: `launch` passes `documents` through to `AppLauncher.open`.

## Verification (agent, synthetic drags)

Throwaway app in `/tmp/portside-droptest` that starts a real file drag session from its own window, driven by CGEvents. TextEdit and Preview were pinned for the run; `dock.json` backed up and restored byte for byte (checked with `cmp`).

- [x] Sweep with a `.txt` along the bottom strip: targets only on apps that can open it (TextEdit, VS Code, Zed, Cursor, Claude, Notes, Brave); none on Finder, Preview, System Settings, Ghostty, the group, Portside's test app, widgets. Can-open check 0.4 to 8ms, once per tile per drag.
- [x] `.txt` on TextEdit (not running): bounce started, `launching TextEdit to open 1 item(s)`, opened in 104ms, bounce landed after 1 cycle. Drag session op=1.
- [x] `.png` on Preview (not running): same, with bounce. Folder on Finder: `activating Finder to open 1 item(s)`, opened in 32ms.
- [x] `.txt` on System Settings, on a widget, and on a non-capable app: op=0, no target logged, nothing opened.
- [x] Calculator.app dropped before the first tile, on the Preview tile, and on a widget: pinned each time (mode pin), op=1.
- [x] Left and Right: `.txt` on TextEdit (running) opened in 35ms; folder on Finder on the right; `.txt` on a non-capable tile rejected.
- [x] Hiding off: `.png` on Preview opened; non-capable tile rejected.
- [x] Screenshots during a held drag: rounded highlight and green plus on VS Code; neither on Ghostty.
- [x] Hover reveal timing unchanged: mouseEntered to animation start 0.73 to 2.46ms across the runs.
- [x] After each drop: `hide timer fired but cursor is still inside, staying revealed`, then hidden 300ms after the cursor left.

## Findings

- On side docks the icons hug the far side of the column (the column is as wide as the widest widget), so the drop area for a tile is its icon plus dot, not the whole column width.
- Moving out of the strip and back in starts a fresh session (re-reads the pasteboard, clears the cache), which costs one extra can-open check per tile.

## Known gaps

- Activation of the target app could not be confirmed from here (the frontmost check was taken over by a system prompt); needs the hand test.
- No drop-to-open on apps inside an open group grid, and a group tile does not spring open during a drag. (Both built in the spring-loading slice above.)
- No Cmd+Option "force open with any app" like the native Dock.
- File promises (images dragged out of Photos or Safari) are not file URLs: they neither reveal the dock nor open.
- Pasteboard read failure falls back to pin mode (old behavior: accepted, only `.app` bundles do anything). Not seen in testing.

## Hand test must also check

- [x] `.txt` onto TextEdit, an image onto Preview, a folder onto Finder: highlight shows, drop opens, app comes forward
- [x] A file onto an app that cannot open it: no highlight, no green plus, nothing happens
- [x] A `.app` onto empty strip space pins it; a `.app` onto another app's tile pins it next to that tile
- [x] First drop works with another app frontmost, and Portside never takes focus
- [x] Bottom, Left, Right, and with hiding off

---

# P1 slice: reveal on file drag to the edge

Status: done, hand-tested by James and committed. No new files.

## Deliverables

- [x] Dragging a file (`.fileURL`) to the edge reveals the dock on Bottom, Left and Right. The edge view is a drag destination; `draggingEntered` goes through the same `handleEnter` path as mouseEntered (reveal delay, slide, timing logs). It returns no drag operation, so it never accepts a drop itself.
- [x] Stays up while the drag is over the dock: the edge zone, the panel's margin (`PanelContentView`) and the strip (the existing SwiftUI drop delegate's enter/exit) all report enter/exit. Moving between them cancels any armed hide. While a drag is over any of them with the button held, exits do not arm the hide and the hide timer will not hide.
- [x] After a drop or drag exit, the normal hide delay applies. After a drop on the strip the dock stays while the cursor is over it and hides 300ms after the cursor leaves.
- [x] A drag elsewhere on screen does not reveal (only the 1pt zone is a destination).
- [x] Edge zone unchanged: still 1pt (`1728x1` bottom, `1x1084` sides), no new click handling. No "edge zone took a click" logs during the run.
- [x] Auto-hide off: no edge window; drops on the strip are accepted and nothing arms a hide.
- [x] No timers added. `wantsPeriodicDraggingUpdates` is off on both new destinations, so AppKit sends no periodic updates while the cursor rests.
- [x] Timing logs: `timing: draggingEntered -> animation start / panel interactive / animation finished`. Hover keeps its `mouseEntered` lines.
- [x] `swift build` clean; `swift run` stays up

## Changes

- `EdgeTracker.swift`: `EdgeView` registers `EdgeTracker.dragTypes` (`.fileURL`), reports `draggingEntered`, `draggingExited` and `draggingEnded` through `onDragEntered` / `onDragExited`.
- `DockPanel.swift`: `PanelContentView` registers the same types and reports the same way (covers the margin around the strip).
- `DockStrip.swift`: `AppFileDropDelegate` reports `dropEntered`, `dropExited` and `performDrop` through `DockInteractions.onDragOverStrip`. Its pinning behavior is unchanged.
- `DockEngine.swift`: `dragTargets` set, `handleDragEntered` / `handleDragExited`, drag guard in `handleExit` and in the hide work item, trigger name in reveal and timing logs.

## Verification (agent, synthetic drags)

Throwaway app in `/tmp` that starts a real file drag session from its own window (like Finder), driven by CGEvents. `dock.json` backed up and restored byte for byte (edge and auto-hide were changed for the run).

- [x] Drag-only path: with the edge view's mouseEntered temporarily disabled, `edge draggingEntered` revealed the dock on all three edges: draggingEntered to animation start 1.27, 1.43, 1.29, 1.75, 5.73, 1.12ms. Reverted before the final runs.
- [x] Drop on the strip (Bottom, Left, Right): stayed up from the edge, through the margin, onto the strip, for 1.5s rests at each; after the drop `hide timer fired but cursor is still inside, staying revealed`; moving the plain cursor away hid it 300ms later.
- [x] Drag to the edge and back without dropping (Bottom, Left, Right): `hide armed in 300ms` on leaving, then hidden.
- [x] Escape while at the edge: drag exit arms the hide, the timer finds the cursor still in the edge zone and stays; moving away hides it.
- [x] Drag around the middle of the screen: no reveal.
- [x] Auto-hide off: drop accepted, no hide armed.
- [x] Hover reveal timing unchanged: mouseEntered to animation start 2.98, 1.37, 1.63, 0.70, 0.77, 1.34, 0.74ms (launch bounce build: 0.51 to 3.21ms).

## Findings

- In these synthetic drags the edge's normal mouseEntered did fire during the drag, usually about 60ms before `draggingEntered`. Real Finder drags may differ (James reported it often does not fire), so both paths stay; whichever comes first reveals and the other logs `draggingEntered (dock already up)` or nothing.
- Tracking-area exits do arrive during drags (`mouseExited: drag still over the dock, hide not armed`), which is why exits are ignored while a drag is over the dock.
- Right edge only: about 700ms into resting at the edge, a system overlay (WindowManager and Bartender windows sweeping across the screen, seen with `CGWindowListCopyWindowInfo`) takes the drag for about 250ms, so the edge gets a drag exit and re-enter. The dock stayed up. If that lasted longer than the hide delay, the hide timer's "cursor still inside" check would still keep it up.
- The strip's drop delegate calls `dropExited` right after `performDrop`, so a drop arms the hide twice; both find the cursor inside and stay.
- Dropping a non-app file on the strip was accepted but did nothing. Fixed by the drop-to-open slice above.

## Known gaps

- Only file drags (`.fileURL`) reveal. Text, links and file promises (for example images dragged out of Photos or Safari) do not.
- No hover labels while dragging over the strip (mouseMoved does not arrive during a drag). Group spring-loading was added later through the strip's drop delegate.
- A drag over an open group grid is not tracked as a drag; the cursor-inside check still keeps the dock up there. (Fixed in the spring-loading slice: the grid is a drag target now.)

## Hand test must also check

- [x] Reveal from a real Finder drag on Bottom, Left and Right, and whether the log shows `edge draggingEntered` or `edge mouseEntered` first
- [x] Dock stays up while dragging along and over the strip, with pauses
- [x] Drag away without dropping: hides after the hide delay
- [x] Clicks right at the screen edge (window resize edges, bottom controls) still work

---

# P1 slice: launch bounce on side edges and in group grids

Status: done, hand-tested by James and committed. No new files.

## Deliverables

- [x] Left and Right edges: pinned strip tiles bounce sideways, away from the screen edge (right on Left, left on Right). Same animation as the bottom (700ms parabola, peak 0.33 of the icon), only the axis and sign change. The bounce window grows on the side the icon travels to.
- [x] Group grid cells: clicking a not-running app in an open grid bounces that cell's icon (52pt) away from the screen edge. The grid stays open while it launches and closes when the bounce lands, like any launch.
- [x] Grid closing mid-launch stops the bounce first, before the close animation: tile click, click elsewhere, click outside Portside, hover-out close, switching groups, dock hiding, dock moved. The cell's icon comes back; nothing is left floating.
- [x] "Animate opening applications" (and Reduce Motion) applies to strip and grid. Off: the grid launches and closes at once, as before.
- [x] Bottom edge unchanged: same window frame math (verified 33x46 window for a 32pt tile, as before), same keyframes.
- [x] `swift build` clean; `swift run` stays up

## Changes

- `LaunchBounce.swift`: a `BounceTarget` (key, window level, icon frame provider) replaces the hard-coded strip lookup. Strip tiles compute the icon rect per edge (the running dot sits on the screen-edge side). The animation uses `transform.translation.x` on side edges. `cancelGridBounce` and an `onEnd(landed)` callback for the grid.
- `GroupController.swift`: launches not-running apps through the bouncer; cancels a grid bounce on collapse start, finish and group switch; keeps cell icon frames reported by the grid.
- `GroupViews.swift`: cells hide their icon while bouncing and report the icon frame (`onGeometryChange`, global space).
- `OverlayPanel.swift`: `screenRect(forContentRect:)`.
- `DockEngine.swift`: bouncer created before the group controller and passed in.
- Reveal/hide path: untouched.

## Verification (agent, synthetic events)

Throwaway test app in `/tmp` that takes 3s to finish launching (run loop kept responsive), pinned temporarily plus a test group holding it and Calculator. `dock.json` backed up first and restored byte for byte after.

- [x] Bottom strip: bounced up, landed after bounce 5 at 3508ms. Bounce window 33x46, same as before the change.
- [x] Bottom grid cell: bounced up inside the grid (window x lines up with the cell icon), landed at 3502ms, then `collapsed (opened SlowBounce)`.
- [x] Left strip: bounced right (window 35x25 = 24pt icon + 10pt travel). Left grid cell: bounced right.
- [x] Right strip: bounced left (window starts 10pt left of the icon). Right grid cell: bounced left.
- [x] Grid closed by tile click mid-launch: `bounce ended (group closed)` at 1012ms, no bounce window left, reopened grid shows the icon at rest.
- [x] Grid closed by a click elsewhere (right edge) mid-launch: `bounce ended (group closed)`, windows gone.
- [x] Dock hidden mid-launch from a grid (left edge): `bounce ended (dock hiding)`, `collapsed (dock hiding)`, only the edge window left.
- [x] Setting off: strip and grid launch with no bounce; grid closes at once.
- [x] Reveal timing (mouseEntered to animation start), same session and conditions: HEAD build 0.51 to 3.21ms over 18 reveals; this build 0.52 to 3.06ms over 24 reveals, all three edges.

## Findings

- Reopening the same group reuses its SwiftUI views, so `onGeometryChange` does not report the unchanged cell frames again. The first build cleared frames on close and then could not bounce on the second open ("tile not on screen"). Frames are now kept per group and only dropped when a cell disappears.
- A test app that blocks its main thread while launching also delays synthetic clicks on Portside by seconds (the window server holds events while that app activates). Real apps that hang at launch may do the same; worth watching in the hand test.

## Hand test must also check

- [x] Sideways bounce feels like the bottom one (speed, height)
- [x] Hover-opened grid: moving off the grid mid-launch closes it and stops the bounce cleanly

---

# P1 slice: launch bounce (bottom edge, pinned tiles)

Status: done, hand-tested by James and committed. New file: `LaunchBounce.swift`.

## Deliverables

- [x] Clicking a pinned tile whose app is not running bounces it on the bottom dock. Runs on Core Animation (`CAKeyframeAnimation`), no timers.
- [x] Motion matched to the native Dock by measurement (see Verification): each bounce is an exact parabola (two cubic Beziers that are exactly `1 - (1 - x)^2` up and `x^2` down), 700ms per bounce, peak 0.33 of the tile size (12.2pt at 37pt), no pause or settle at the bottom. The overlay icon is pre-rendered at the tile's exact pixel size with high quality interpolation, and its window is snapped to whole points with the fraction on the layer, so handing back to the tile does not shimmer.
- [x] Stops when the app finishes launching: KVO on `NSRunningApplication.isFinishedLaunching` (and `isTerminated`) from the `openApplication` result, plus `NSWorkspace.didLaunchApplicationNotification`, whichever comes first. The bounce in progress lands first (the animation is swapped for a copy with the same start time and just enough repeats).
- [x] Safety cap: 14 bounces (9.8s), built into the animation's repeat count.
- [x] Cancels immediately on launch failure, app quitting while launching, tile removed, dock hiding, dock moved, setting turned off, engine stopped.
- [x] Visual only: the bouncing icon is drawn in a click-through window over the tile (the panel has about 16pt of room above the icons, so a SwiftUI offset would clip). The tile hides its icon meanwhile but keeps its slot and its click target, so neighbors never move. The window follows the tile if the strip changes size or order.
- [x] Running apps, unpinned extras, side edges and group cells do not bounce. A second click while launching does not restart it. One bounce at a time (a new launch replaces the old one). Skipped under Reduce Motion.
- [x] Settings > General: "Animate opening applications" (default on, `animateOpeningApplications` in `dock.json`).
- [x] `AppLauncher.open` takes an optional main-queue completion with Launch Services' result.
- [x] `swift build` clean; `swift run` stays up

## Verification (agent, synthetic events)

Used a throwaway test app in `/tmp` that delays finishing launch by a configurable time, pinned temporarily.

- [x] Native reference: recorded the native Dock (37pt tiles, Portside not running, no Dock settings touched) while the test app launched for 5s, tracked the icon edge per frame (about 60fps) and fitted models over 7 bounces. Parabola: period 0.700s, peak 12.2pt, error 0.3pt (pixel rounding); a sine-shaped bounce fit worse (0.5pt). Native lands at the end of the bounce in progress, like ours.
- [x] Portside at 37pt, recorded the same way: period 0.700s, peak 11.9pt, error 0.17pt; per-phase heights within 0.2pt of the native curve. Landing: one 16ms frame differs from the resting tile by 2.6/255 on average (not visible).
- [ ] Not measured: whether the native peak scales with tile size (changing `tilesize` is off limits before F). Portside assumes it scales.

- [x] Notes: bounced once, landed at 626ms (launch notification at 221ms). Screenshots mid-bounce: icon above the dock, empty slot, neighbors in place. Frontmost app became Notes, as with any launch.
- [x] 3s launch: bounced continuously, landed after bounce 6 (3.7s). A second click mid-bounce registered on the tile and did not restart the bounce.
- [x] Dock hiding mid-launch: `bounce ended (dock hiding)`; nothing left floating; after re-reveal the tile sat at rest with its icon visible.
- [x] Safety cap with a 15s launch: `bounce ended (safety cap)` after 9922ms (at the earlier 16 x 620ms; now 14 x 700ms).
- [x] Remove from Dock mid-bounce (context menu): `bounce ended (tile removed)`, strip closed the gap, nothing left floating.
- [x] Finder (running) click: activates, no bounce. Setting off: launches, no bounce.
- [x] Reveal timing unchanged: mouseEntered to animation start 0.55 to 1.49ms over 5 reveals (E part 2: 0.63 to 1.32ms); after the motion change 0.49 to 2.37ms.
- [x] Test changes undone: `dock.json` restored from backup; test app quit.

## Findings

- KVO on an `NSRunningApplication` that deallocates while observed throws inside AppKit (`removeEntryAndReturnIfEmpty:` unrecognized selector) and crashed the first build. The bouncer now holds the instance until it removes its observers.

## Hand test must also check

- [x] Bounce side by side with the native Dock (for example launch an app from Finder with the native Dock revealed, then from Portside)
- [x] A slow app (for example Android Studio or Ableton Live) bounces until its window is about to appear, then lands

---

# Milestone E part 2: auto-hide toggle, real app while in Settings, group naming, hover open

Status: done, hand-tested by James and committed. New files: `HotKey.swift`, `AppIcon.swift` (plus `SettingsWindow.swift` from part 1).

## Deliverables

- [x] Auto-hide toggle (native "Automatically hide and show the Dock"): `DockModel.autoHide` (default on, saved in `dock.json`). Three controls stay in sync: the General tab toggle, the menu bar item "Turn Hiding Off/On", and the separator right-click menu.
- [x] Auto-hide off: the edge tracker is stopped (edge window ordered out, no tracking at all) and the panel stays revealed. Exits do nothing and the hide timer cannot fire. Switching edges re-reveals on the new edge. Turning it back on re-arms the tracker and hides if the cursor is outside. No new timers.
- [x] Cmd+Option+D global hotkey through Carbon `RegisterEventHotKey` (`HotKey.swift`, no permissions needed). See Known gaps for the conflict with the native Dock's own shortcut.
- [x] Settings makes Portside a real app: opening switches the activation policy to `.regular` (shows in the native Dock, Cmd+Tab and the app switcher); closing activates the app that was frontmost before (tracked while Settings is open, so Cmd+Tab detours are handled), then returns to `.accessory`. Reopening from the native Dock opens Settings.
- [x] Runtime app icon (`AppIcon.swift`): white `bird.fill` on a rounded blue gradient. `applicationIconImage` alone left the generic exec icon in the native Dock for an unbundled executable; setting `dockTile.contentView` and calling `display()` fixed it.
- [x] Portside's own dock shows a Portside tile with a running dot while Settings is open (extras section, after running apps). Click opens Settings; right-click has Settings... and Quit.
- [x] Inline group naming: creating a group opens its grid with an editable name field ("Group N" selected). The overlay panel becomes key only while editing (no app activation; the frontmost app stays frontmost), then orders out and back in to hand keys back. Return saves, Escape cancels, blank reverts. Clicking elsewhere saves and closes. The dock stays revealed while editing.
- [x] Group tile context menu: Rename (same field), Ungroup, Remove from Dock. The Settings Groups tab updates live.
- [x] Open groups on hover (Groups tab, off by default) with **Open delay** (0 to 1000ms, default **50ms**) and **Close grace** (0 to 500ms, default 50ms) sliders; both persist in `dock.json`. Group grid opens with a light spring (scale 0.9 to 1 plus fade, about 260ms, tile-side anchor) and closes with a 140ms ease-in; SwiftUI card shadow. Reduce Motion and dock hide stay instant.
- [x] `swift build` clean after every batch; launches and stays up

## Verification (agent, synthetic events)

- [x] Auto-hide off on Bottom, Left and Right: panel stays up through repeated exits and edge switches; edge window offscreen. On again: hides 300ms after leaving. Relaunch with it off: `engine started, auto-hide off, panel revealed, edge tracker idle`.
- [x] Hotkey mechanism: a test combo (Ctrl+Option+Cmd+J) fired the handler; Cmd+Option+D registers successfully. Not pressed for real (see Known gaps).
- [x] Settings: policy regular and active, bird icon in the native Dock (screenshot), Portside tile with a dot in our dock. Cmd+Tab away and back works. Closing: policy accessory, gone from both docks, focus back on the previous app.
- [x] Rename with a keystroke logger app frontmost, bottom, left and right: overlay key true while editing, typed name saved, keys after Return went to the logger, logger stayed frontmost throughout. Escape kept the old name; blank reverted; Settings showed the new name.
- [x] Hover open (prior run): opened 209 to 217ms after reaching the tile on all three edges; a fast sweep opened nothing; switch between groups immediate; tile to grid stayed open; grid placed 10pt off the tile on each side.
- [x] Hover-open transient close: close grace read from `DockModel.groupHoverCloseGrace` (settings slider); click-opened grids unchanged; rename and dock hide paths unchanged. `swift build` clean; `swift run` stays up.
- [x] Animation and timing fixes (after the first motion pass misbehaved):
  - The 10pt gap between tile and grid belonged to no window, and the grid barely took the mouse while fading in, so a slow crossing outlasted the grace and the grid closed. The overlay now includes a near-clear bridge across the gap. The hit fill sits outside the animation, so the whole grid region takes the mouse from the first frame. The shadow padding is excluded from `containsScreenPoint` and tracking (`OverlayPanel` hit insets).
  - Switching groups reused the SwiftUI view, so the open never replayed. Fixed with `.id(groupID)`.
  - During the close fade, hovering or clicking the tile (or re-entering a hover-opened grid) was ignored, then the grid vanished. Now it reopens from where it is. An instant collapse (dock hiding) cuts a running fade short.
  - The close completion moved from a view-side `asyncAfter` (it could finish a later close early) to one cancelable `DispatchWorkItem` in `GroupController`.
  - The window shadow was computed from the transparent first frame. Replaced with a SwiftUI shadow that animates with the card.
- [x] Hover close re-verified with synthetic glides on Bottom, Left and Right: a slow tile-to-grid crossing (about 0.2pt/ms) stays open, leaving the grid or sliding sideways onto an app closes after grace plus fade, an out-and-back during the fade logs `reopened while closing by hover`, a click after hover-open pins it, and a second click closes it.
- [x] Reveal timing unchanged: mouseEntered to animation start 1.7 to 3.6ms over 5 reveals (D was 0.3 to 3.6ms); after the motion fixes 0.63 to 1.32ms. Dock click with Settings closed: frontmost app unchanged.
- [x] Test changes undone: `dock.json` restored from the pre-E2 backup.

## Known gaps

- [ ] No screen-space reservation with hiding off. The native Dock shrinks `NSScreen.visibleFrame` so maximized and zoomed windows stop above it; macOS has no public API for a third-party app to do that (the Dock does it inside WindowServer). Doing it ourselves would mean moving other apps' windows through Accessibility, which fights every app's own zoom. Shipped as an always-visible overlay; windows can extend under it. The Settings toggle says so.
- [ ] Cmd+Option+D conflict: the system shortcut "Turn Dock hiding on/off" (System Settings > Keyboard > Keyboard Shortcuts > Launchpad & Dock) is enabled by default and most likely wins, toggling the native Dock instead. Disable it there for ours to work. Milestone F hides the native Dock anyway; F should decide whether to claim the shortcut.
- [ ] Unbundled `swift run`: the icon is set at runtime and Bartender treats the menu bar item as new. A real `.app` bundle (F) fixes both.

## Hand test must also check

- [x] Cmd+Option+D (with the system shortcut disabled) toggles hiding on all three edges
- [x] With Settings open, Portside shows in Cmd+Tab and both docks; closing returns you to where you were
- [x] New Group and Rename feel natural: typing goes into the field, the app you were in keeps focus afterward
- [x] Hover open delay feels right; hover-opened grids close when you leave them but stay open tile to grid; click-opened grids stay until you dismiss them; sweeping never pops groups open

---

# Milestone E part 1: settings window and model

Status: done, hand-tested by James and committed.

## Deliverables

- [x] `SettingsWindow.swift`: `SettingsWindowController` owns a normal titled window hosting a SwiftUI `SettingsView` with General, Widgets and Groups tabs. Opened from the menu bar item "Settings..." (Cmd+, shown on the item).
- [x] Focus: opening calls `NSApp.activate()` and `orderFrontRegardless()` (activation is cooperative and can be declined; the window still comes up on top, one click makes it key). Closing hands activation back to the app that was frontmost when Settings opened (`activate(from:)`); `NSApp.deactivate()` alone left Portside active. The dock panel is unchanged and still non-activating.
- [x] General tab: Position (Bottom/Left/Right segmented, same `setEdge` as the menu bar picker, both stay in sync); Icon size; Magnification toggle, disabled, "Coming soon." (stored as `magnificationEnabled`, nothing reads it yet); Timing: reveal delay 0 to 1000ms, hide delay 0 to 2000ms (50ms steps), animation 0 to 500ms (10ms steps, 0 shows "Instant"), Reset to Defaults (0, 300, 150ms). Footer notes Reduce Motion always wins.
- [x] Icon size and separator stay in sync: the strip publishes its fit limit (`DockLayout.fitTileSize`, the same `maxTileSize` the separator drag clamps to). The slider runs 16pt up to that limit, shows `min(iconSize, fit)` like the strip renders, and stores at most the fit. A caption shows the limit when it is under 128pt. It updates live when the edge, apps or widgets change.
- [x] Sliders update the model live while dragging and save once on release (like the separator). Keyboard changes have no drag and save immediately.
- [x] `DockModel`: timing values and `magnificationEnabled` are now `@Published private(set)` with setters (`setRevealDelay`, `setHideDelay`, `setAnimationDuration`, `resetTimingToDefaults`, `setMagnificationEnabled`). Defaults and ranges live in one place (`DockModel.Defaults`, `*Range`). Values loaded from `dock.json` are clamped to the ranges. Same top-level keys as before, so no migration.
- [x] Widgets tab: "In the Dock" list in display order with a switch per widget, up/down arrow buttons, and drag to reorder (`moveWidgets`, `moveWidget(_:by:)`); "Available" lists disabled widgets. Re-enabling keeps the existing catalog-order insert.
- [x] Groups tab: each group with member icons, an editable name field (commits on Return or when focus leaves; blank reverts), app count, Ungroup, and Delete... with a confirmation sheet. Empty state explains how to create a group. `DockModel.renameGroup(groupID:to:)` added.
- [x] Menu bar: title is now just "Portside"; Widgets and Position menus stay as quick switches. Temporary label (sailboat icon plus "Portside" text) so the item is easy to find.
- [x] Separator right-click: "Settings..." (the start of P1's divider menu). Needed because Bartender parks the item off screen while Portside runs unbundled through `swift run` (same spot as its Always Hidden items). From a real right-click, Settings opens focused and closing returns focus.
- [x] No new timers anywhere; the engine and panel already read the timing values at use time, so nothing in the reveal/hide path changed.
- [x] `swift build` clean after every batch; `swift run` launches and stays up

## Verification (agent, synthetic events)

- [x] Settings window opens on top of the frontmost app; a click in it makes Portside frontmost; closing returns focus to the previous app (3 of 3 runs).
- [x] Timing live, no relaunch, Settings window still open: reveal 200ms gave mouseEntered to animation start 212ms; animation Instant gave start to finished 4ms; hide 1000ms logged `hide armed in 1000ms` and fired on time. Reset to Defaults saved 0 / 0.3 / 0.15.
- [x] Reveal timing unchanged at defaults: mouseEntered to animation start 0.57 to 1.17ms over 4 reveals (D was 0.3 to 3.6ms).
- [x] Position Left from Settings: edge window moved to the left edge, panel revealed there, saved `left`; fit limit changed live from 61 to 33pt (two 2560x1440 displays attached during testing).
- [x] Icon size: slider to the minimum saved 16pt (panel 63pt wide on the left); dragged past the end saved exactly 33pt, the fit limit (panel 1390pt tall in a 1410pt visible frame). A separator drag from 33 to 23pt moved the slider and its label live.
- [x] Widgets: switch off removes it from the dock and moves it to Available; drag and arrow reorder both saved and the strip reordered live (screenshots before and after); re-enable works.
- [x] Groups: rename on Return and on focus loss both saved and the dock tile's label updated live; a blank name reverted; Ungroup returned the apps in place; Delete's Cancel changed nothing, Delete removed the group and its apps.
- [x] Relaunch: edge, icon size, timing and widget order all came back from `dock.json`.
- [x] Dock click with Settings closed: frontmost app unchanged.
- [x] Test changes undone: `dock.json` restored from the pre-E backup.

## Hand test must also check

- [x] "Settings..." from the real menu bar click comes up focused (activation from a real menu click could not be tested here; Bartender owns the status item area)
- [x] Every setting applies live and survives a relaunch
- [x] With Settings closed, clicking the dock never takes focus from the frontmost app

## Findings

- SwiftUI sliders and switches here ignore Accessibility value sets and increments (`AXIncrement` returns success, value unchanged); real mouse input works. Worth a look for VoiceOver in P3.
- A grouped `Form`'s rows cannot be drag-reordered with `.onMove`; the enabled widgets use a real `List` inside the section.

---

# Milestone D: app groups

Status: done, hand-tested by James and committed.

## Deliverables

- [x] `FolderGroup.swift`: `FolderGroup` (id, name, apps) and `DockEntry` (an app or a group). Deviations from PLAN.md section 6: members are full `PinnedApp`s instead of `appIDs` strings (apps without a bundle id need their path), and `isExpanded` is not persisted (the expanded grid is transient and closes whenever the dock hides).
- [x] `DockModel`: the pinned section is now `entries` (apps and groups in display order). `allPinnedApps` flattens groups, so grouped apps count as pinned and never show again in the running section. Mutations: `pin`, `unpin`, `move(entryID:)`, `createGroup(with:)`, `addToGroup`, `removeFromGroup` (puts the app back right after the group), `ungroup` (apps return in place), `removeGroup`. A group left empty is removed. New groups are named "Group 1", "Group 2" and so on.
- [x] Migration: an existing `dock.json` with the old `pinnedApps` key loads as app entries and is saved as `entries` on the next change. Verified on the real file (27 apps, order unchanged).
- [x] Group tile (`GroupViews.swift`): rounded tile with up to 9 member icons (2x2, or 3x3 above four), a running dot if any member runs (placed per edge like app dots), brighter while expanded. Hover label shows the group name. Reorders by drag like an app tile.
- [x] Expanded group: a grid in a second `OverlayPanel` (interactive): group name, 52pt icons with names and running dots, hover highlight. Columns: up to 3 in one row, 4 as 2x2, 3 wide up to 9, 4 up to 16, then 5. Opens with a 120ms scale and fade from the tile side; instant with Reduce Motion.
- [x] Placement follows the B.5/B.6 label rules: 10pt (`DockHover.labelGap`) beyond the tile's far edge, centered on the tile along the dock's axis, clamped inside the visible frame. Above the tile on the bottom, to the right on a left dock, to the left on a right dock. Follows the tile if the strip moves while open (resize, items added).
- [x] `OverlayPanel` gained what an interactive use needs: first-click hosting view, enter/exit tracking, sizing from the content's own measured size (`onGeometryChange`, same reason as the clipping fix), and `reanchor`.
- [x] `GroupController.swift`: open state, presentation and every close path: tile clicked again, app opened from the grid, click elsewhere on the strip, click in another app (global mouse-down monitor, installed only while a group is open; mouse events need no permission), dock hiding, dock moved, group ungrouped or removed. Hover labels are suppressed while a group is open (they would sit where the grid is).
- [x] Hide path: entering the grid cancels a pending hide and leaving it arms one, through the same handlers as the edge zone and panel. The hide timer's one-shot check and the re-arm check count the grid as inside. Closing a group re-checks the cursor, because a panel ordered out under the cursor sends no exit. No new timers.
- [x] Group management until E: app context menu "Add to Group" (existing groups, New Group; works for pinned and unpinned running apps); grid item menu: Remove from Group, Remove from Dock, Show in Finder, Quit; group tile menu: Ungroup, Remove from Dock. Renaming waits for E's settings window (a text prompt would have to activate Portside).
- [x] `swift build` clean after every batch; `swift run` launches and stays up

## Verification (agent, synthetic events)

- [x] Created "Group 1" through the real context menus: New Group on Discord, then Add to Group for Messages, Mail and Brave. Saved as entries.
- [x] Bottom: click expands in 1 to 16ms; grid centered on the tile (tile mid x 794, grid mid x 794), grid bottom exactly 10pt above the tile top; label hidden while open; frontmost app unchanged.
- [x] Left: grid starts exactly 10pt right of the tile, vertically centered on it (mid y 560 both). Right: grid ends exactly 10pt left of the tile, centered. Only the expected windows on screen while open.
- [x] Close paths, each logged: tile clicked again, click on the separator, click in the menu bar (another process), app opened from the grid (Mail activated in 34ms on the first click, grid closed), dock hiding, group ungrouped while open.
- [x] Hide path: tile to grid logs `panel mouseExited: hide armed`, then `group enter: pending hide canceled`; dock stays up with the cursor in the grid; leaving the grid hides the dock and closes the group.
- [x] Remove from Group from the grid menu: Brave returned right after the group; the open grid resized live to one row.
- [x] Group tile drag reorder moves it one slot and back without toggling the grid.
- [x] Ungroup restored the exact original app order (compared with the pre-D `dock.json`).
- [x] Reveal timing unchanged: mouseEntered to animation start 0.3 to 3.6ms.

## Hand test must also check

- [x] Create a group from an app's right-click menu, add more apps, open and close it on all three edges
- [x] Moving from the tile into the grid never hides the dock, and leaving both hides it after the delay
- [x] Clicking an app in the grid opens it on the first click without a "wake up" click
- [x] Clicking another app or the desktop closes the grid
- [x] Grid looks right next to the tile on Bottom, Left and Right (no label overlapping it)

## Findings

- Known harmless: `panel mouseExited` logs twice per exit (about 30 microseconds apart). Pre-existing (same on the last committed build in a separate worktree). The second call restarts the same one-shot hide timer; not fixed in D.
- Not built in D: dragging an app onto a group tile to add it, keyboard navigation in the grid (P3), scrolling for very large groups.

## Deferred to Milestone E (all three built in E part 2)

- [x] Open groups on hover (optional setting, off by default). When on, hovering a group tile opens its grid after a hover-intent delay (default about 200ms, configurable) so sweeping across the dock does not pop groups open. Hover-opened grids close when the cursor leaves the tile and grid (100ms grace across the gap). Hovering a different group tile switches the open grid immediately. Click-opened grids keep D's close rules; a tile click after hover-open pins sticky. No polling: cancelable one-shot delays only, like the hide timer.
- [x] Name prompt on group creation. When a group is first created, prompt for its name, with the default "Group N" so skipping is harmless. Preferred: inline rename (editable name field in the open grid or on the tile) where the panel takes key focus only while editing and returns focus to the previously frontmost app afterward. Fallback: a name field in the settings window. Must not break the non-activating panel behavior for normal use.
- [x] Group rename (deferred from D). Rename from the settings window (done in E part 1), and from the group tile's context menu using the same inline mechanism as the creation prompt (E2).

---

# Milestone B.5: hover labels and overlay panel

Status: done. Hand-tested by James, including the label placement fix; committed.

## Deliverables

- [x] `OverlayPanel.swift`: reusable floating panel for content outside the strip. Borderless, non-activating, never key or main, click-through by default (`ignoresMouseEvents`, settable for D's interactive popover). Level 103, above the edge tracker. `present(content, anchor:, edge:, gap:)` places content beside a screen rect on the side away from the dock edge (`DockEdge` bottom/left/right) and clamps it to the screen. `dismiss()`, `containsScreenPoint`.
- [x] `DockHover.swift`: `.dockHoverTarget(id:title:)` modifier reports item frames through a preference key in the strip's root coordinate space; `DockHover` hit-tests the cursor against them and shows a `DockLabel` (dark rounded pill, 13pt regular, 10pt above the icon) in the overlay
- [x] App tiles use `.dockHoverTarget` and `.accessibilityLabel`; the `.help` tooltip on app tiles is gone (widgets keep theirs for now)
- [x] `swift build` clean (no warnings); `swift run` launches and stays up

## Follow-up (label placement)

- [x] Hover label placement is wrong: it sits nearly flush against the dock's top edge and is oversized. Fix: anchor the label to the hovered icon (not the panel top) with roughly a 6 to 10pt gap above the icon's top edge; match the native Dock label size (about 13pt system font, small horizontal and vertical padding, rounded pill, dark translucent background); keep it horizontally centered on the icon; clamp it inside the screen's visible frame so it never clips at the screen edges.
  - Cause: the label was already anchored to the icon, but its 6pt gap equaled the strip's 6pt padding above the icons, so the label's bottom landed exactly on the dock background's top edge.
  - Fix: gap 10pt above the icon top (4pt of air above the dock background); label 13pt regular, padding 8 by 2, radius 6, `Color(white: 0.12, opacity: 0.78)`, max width 320 with middle truncation; clamped to `visibleFrame` with a 4pt margin; origin rounded to whole points.
  - Measured: ChatGPT icon top y 1064 (top-left coords), label 1034 to 1054 (20pt tall, was 24), dock background top 1058. Centered within 0.5pt (ChatGPT icon center 501, label center 501.5; Finder 61 vs 61.5).
  - [x] Hand test confirms placement and size look native

## Reveal/hide path changes (events only, no logic changes)

- `DockPanel`: the panel's existing tracking area also requests `.mouseMoved` and forwards it (converted to strip coordinates). Mouse-down and right-mouse-down on the strip are reported. Added `isRevealed` and coordinate conversion helpers. `show`/`hide` are untouched.
- `DockEngine`: clears the label on panel exit, on mouse down, before the hide slide, and on stop. Hover only runs once the panel is fully revealed, plus a one-shot cursor check when the reveal slide finishes. No new timers.

## Verification (agent, synthetic events)

- Sweeping across icons swaps the label per icon (about 8ms apart in the log) with no hide armed between icons. Half of the 6pt gap between tiles counts toward each neighbor, so there is no blank flicker.
- Label is centered on its icon: ChatGPT icon x 482 to 520, label x 463 to 539 (both centered at 501), 6pt above the icon top.
- Cursor parked during the reveal slide: the label appears at "animation finished" (one-shot check), not mid-slide.
- Moving up into the panel's top inset (under the label) hides the label and logs no panel mouseExited, so the overlay does not affect hide.
- Click while hovering: `panel mouseDown (key window: false, portside active: false)`, label hides, returns on the next move.
- Reveal timing unchanged: mouseEntered to animation start 0.5 to 1.4ms.
- An app labeled `[untitled]` is real: `/Applications/[untitled].app`.

## Notes

- Moving the cursor above the panel (onto the label itself) leaves the dock, same as the native Dock. That starts the normal hide delay; it is not caused by the overlay.
- Left/right edge placement in `OverlayPanel.frame` is exercised by B.6 (see below).
- Labels run only on hover targets; widgets and D's folders opt in with the same modifier.

---

# Milestone B.6: dock position and separator resize

Status: done, hand-tested by James and committed. Verified with synthetic mouse events, Accessibility reads and logs on all three edges.

## Deliverables

- [x] Dock position: bottom, left, or right. `DockEdge` (new `DockEdge.swift`, raw values match the native Dock's `orientation` for F's import), persisted as `edge` in `dock.json`, switchable live from the menu bar's temporary "Position on Screen" submenu until Milestone E
- [x] `EdgeTracker`: edge window and tracking area per edge. Bottom is a full-width row; left and right are full-height columns that stop below the menu bar. Moves live via `setEdge`.
- [x] `DockPanel`: frames per edge. Flush against the screen frame's edge, centered along it inside `visibleFrame` (so side docks stay below the menu bar), slides in from and hides toward that edge. Insets follow the edge (6 on the screen side, 10 on the far side, 12 along). `show`/`hide` state machine unchanged.
- [x] `DockStrip`: `AnyLayout` switches between a horizontal row (bottom) and a vertical column (sides). Items align to the far side; running dots sit between the icon and the screen edge; separators become horizontal lines on side docks; reorder and Finder drops use the dock's axis; tile fitting uses the dock's length (side docks count every item as one tile tall).
- [x] Labels follow orientation: above the icon on the bottom, to the right on a left dock, to the left on a right dock (hit slop along the dock's axis). The overlay's `edge` parameter is the anchor D's folder popover will use.
- [x] Magnification direction: `DockEdge.growthAnchor` (bottom, leading, trailing) so tiles grow away from the screen edge. Magnification itself is not built yet (E/P2); today the anchor drives the reorder "lift" scale.
- [x] Separator drag to resize: drag away from the edge to grow, toward it to shrink, about 1pt per 1pt of cursor travel. Tracked in screen coordinates because the panel moves while it resizes. Clamped to 16 to 128 (native `tilesize` range) and to the largest size that fits on screen. Live while dragging, saved once on release. The dock stays revealed for the whole drag.
- [x] Resize cursor on the separator: set with `NSCursor` on every hover move and during the drag, working while another app is frontmost via `BackgroundCursor` (see follow-ups).
- [x] `swift build` clean, no warnings; `swift run` launches and stays up

## Verification (agent, synthetic events)

- [x] Click swallowing, before and after, with a test window against the bottom-left edge and clicks 0.5 to 4.5pt above the screen bottom. Committed B.5 build (4pt strip): clicks at 0.5, 1.5, 2.5 and 3.5pt never reached the window, only 4.5pt did. B.6 build (1pt strip): 1.5, 2.5, 3.5 and 4.5pt all reached the window; only the 0.5pt row (the trigger row itself) is taken, and it is logged as `edge zone took a click`.
- [x] A 1pt zone still triggers: 3 of 3 reveals with the cursor pushed past the bottom edge, 3 of 3 on the left edge.
- [x] Reveal timing unchanged: mouseEntered to animation start 1.0 to 2.0ms on the bottom and left edges, 2.6ms on the first reveal after a switch; slide finished at 143 to 150ms. B.5 measured 0.5 to 1.4ms and ~149ms.
- [x] Live switching via the menu (pressed through Accessibility): Bottom, Left, Right, Bottom. Edge zone moved each time (bottom 1728x1; left and right 1x1084 starting below the 33pt menu bar), panel re-laid out and parked off the new edge, `dock.json` updated.
- [x] Left dock: 77x1050 column flush left, centered below the menu bar; icons right-aligned; Finder's dot on the left of its icon; labels open 10pt to the right of the icon, vertically centered within 0.5pt; sweeping down the column swaps labels with no hide armed.
- [x] Right dock: panel flush right (x 1651 to 1728); icons left-aligned; dot on the right; labels open to the left.
- [x] Resize on the bottom: drag down 12pt shrank icons 38 to 28pt; dragging 130pt above the dock grew them back and clamped at 38 (the screen-fit limit). Hide timer fired mid-drag with the cursor outside and stayed revealed; release outside re-armed the hide and the dock slid away 300ms later. Size saved.
- [x] Resize on the left: drag 8pt toward the edge shrank 23 to 17pt; drag away grew back to 23 (fit limit).
- [x] Vertical reorder: Siri dragged one slot down mid-drag, dropped back, saved order unchanged. Lift scale grows away from the left edge.
- [x] Widgets render in the side column (clock, calendar, weather, stats read back through Accessibility).
- [x] Clicks on the strip still leave focus alone: `panel mouseDown (key window: false, portside active: false)`.
- [x] Restart loads the saved edge (launched on the left from `dock.json`).
- [x] Test settings restored afterwards: edge bottom, iconSize 48, 27 pins.

## Hand test must also check

- [x] (a) The edge strip does not swallow clicks: try resizing a window from its bottom edge and clicking a control at the very bottom of an app. If blocked, shrink the strip to 1 to 2pt or switch to an event-driven global mouse-moved monitor. (Strip is now 1pt; agent test above passed.)
- [x] (b) Reveal timing logs are unchanged.
- [x] Resize cursor shows on the separator and during the drag
- [x] Left and right docks look and feel right (both docks react on the left edge while the native Dock lives there)

## Follow-ups (deferred)

- [x] Resize cursor doesn't show when Portside isn't frontmost (`BackgroundCursor.swift`, SkyLight `SetsCursorInBackground`). At launch, `CGSMainConnectionID` and `CGSSetConnectionProperty` are resolved via `dlopen`/`dlsym` (falling back to the `SLS` names) and the property is set on our connection; any missing symbol or error logs once and leaves normal behavior. The separator now sets the cursor itself on every hover move (`onContinuousHover`), because `pointerStyle` and cursor rects only apply to the active app. Agent check with another app frontmost: the system cursor reads `resizeLeftRight` on the left and right separators, `resizeUpDown` on the bottom one, and the arrow off them. Log: `SetsCursorInBackground enabled on connection ..., read back: 1`. Deliberately early private API use (requested ahead of F).
- [x] Menu bar item title/accessibility label shows "Bird" instead of "Portside". `MenuBarExtra("Portside", systemImage: "bird")` exposed the symbol name; now a label closure with `accessibilityLabel("Portside")`. Accessibility reads `AXTitle = Portside`.
- [x] Some icons changed style with dock size (Splice white at 32pt and below, dark ghosted glyph from about 36pt up). Cause: `NSWorkspace.icon(forFile:)` returns 32 Icon Services reps (16 to 1024pt), and the system icon style (Dark here, `AppleIconAppearanceTheme = RegularDark`) is applied to Splice's 128px and larger reps but not to the small ones baked into its legacy `app.icns`, so the rep AppKit picked per tile size decided the look. Not an `NSAppearance` variant: forcing aqua or darkAqua changed nothing. The native Dock shows the dark version (screenshot at tilesize 36), so dark is the correct style. Fix: `IconCache` renders each icon once at 128pt times the screen scale into one sRGB bitmap and the tile only scales that bitmap. Verified during a live separator drag from 16 to 38pt (the bottom dock's fit limit): Splice stays dark, Finder, Settings, Notion and Live unchanged. Cache drops an entry when the app's `Info.plist` modification date changes (checked at most every 5s per app, so drags stay off the disk; verified with a test bundle) and drops everything when the screen scale changes (not testable here without a non-Retina display). Rendering 29 icons takes about 350ms at launch, before the edge tracker arms, so the first reveal is unaffected.
- [x] Hand test: drag a separator from 16 to the largest size and confirm Splice looks the same throughout
- [x] Dock ends clipped when growing it by dragging a separator. Cause: the panel only resized from `invalidateIntrinsicContentSize` on the hosting view, and on this macOS `NSHostingView` never calls it (zero calls logged across drags, app launches and quits). So the window kept the size it got at reveal: shrinking looked fine (content just sat inside a wider panel), growing past the reveal size clipped both ends until the next reveal recomputed the frame. It looked like a first-drag-only bug because later drags usually stayed within that size. Fix: the strip reports its measured size with `onGeometryChange` after its `.fixedSize()`, and `DockPanel` resizes to it immediately (centered on its edge, clamped to the visible frame); during a slide the completion handler catches up. Verified on a fresh launch for each edge by comparing every strip element's Accessibility frame to the panel window at each drag step (bottom 38 to 16 to 38pt, left and right 29 to 22 to 29pt): no clipping. Also verified right after launch on the bottom: app launched and quit, Clock widget removed and re-added, panel resized each time. Reveal timing unchanged (about 2.5ms to animation start).
- [x] Hand test: launch fresh, immediately drag a separator small to large and back on all three edges, no clipping

## Findings

- Live edge switching first left the strip stale (horizontal panel slid in from the left). `@Published` emits from willSet, before the property holds the new value; moving the panel inside the subscriber forced a synchronous SwiftUI layout that read the old edge, and nothing invalidated it afterwards. Fixed by applying the edge change on the next main loop turn (`.receive(on: DispatchQueue.main)`). Same trap applies to any future `$property` subscriber that touches the panel.
- Synthetic cursor moves past the screen edge (x = -50) are reported unclamped, so the 1pt zone looked like it lost the cursor and the hide timer fired. Real cursors are clamped onto the edge pixel; tests now place the cursor exactly on it.
- The resize cursor could not be verified by the agent: a probe of `NSCursor.currentSystem` reported the arrow even for a frontmost control app that sets the resize cursor, so the probe does not work with synthetic moves. If the cursor does not change for a real mouse, the likely cause is that macOS ignores cursor changes from background apps; the public options are exhausted (`pointerStyle` and `NSCursor.set`), and the known workaround is a private CGS connection property, which belongs in Milestone F behind `dlsym`. Update: done early in `BackgroundCursor.swift` (see follow-ups). With the property set, the same probe does see the resize cursor, so the earlier probe failure was the background restriction itself.
- Native Dock `orientation` is currently `left` (tilesize 36) on this machine. Read only, never written. With Portside also on the left, both docks react to that edge until F.
- At the fit limit, side docks get small tiles (23pt with 27 pins and 5 widgets on this display), and widget text gets tiny (about 4 to 5pt). Readable widgets on side docks need per-widget layouts or fewer items; candidate for Settings (E) or later polish.
- The separator grab target grew from 5pt to 9pt along the dock, so the bottom dock is 8pt wider (1692pt).
- The resize handle only exists when there is a separator (running unpinned apps or widgets). With neither, icon size is only adjustable in Settings (E).

## Changes outside B.6's own scope

- `DockModel.iconSize` is now `@Published` (needed so a live resize re-renders the strip). `edge` is new.
- `EdgeTracker` thickness 4pt to 1pt, and swallowed clicks are logged.
- `DockEngine` hide path: the hide timer is skipped while a resize drag is active (same pattern as open menus) and re-armed on release if the cursor is outside. No new timers.
- `DockHover`: hit slop and label side follow the edge.
- `PortsideApp`: "Position on Screen" submenu; title reads Milestone B.6.

## Notes

- Dock on left/right and the resize handle moved here from P2/P3.
- Temporary menu bar position control is replaced by Settings in Milestone E.
- Multi-display behavior stays primary-display only until P3.
- Known issue: widgets on side docks are too small (see UX cleanup: Side-dock widget layout). Left/Right otherwise verified.

---

# UX cleanup

Deferred polish after the milestone and parity backlog. Mirrors `docs/PLAN.md` §10.

## Side-dock widget layout

- [ ] Side-dock widget layout
  - Problem: on Left and Right, widgets share one column with the apps. With 27 apps and 5 widgets, tiles shrink to about 23pt, widget text is about 4 to 5pt and unreadable, and the dock looks cramped compared to the bottom layout. Fix deferred from Milestone B.6.
  - Constraint: the bottom edge must stay unchanged. Side docks should keep native-style icon sizing from the saved size, with no global shrink-to-fit just to make widgets fit.
  - Candidates (evaluate, do not decide yet): (a) second column/segment with own sizing; (b) compact single-line side variants; (c) flyout from a widgets icon via the overlay panel; (d) overflow scroll/paginate at real icon size; (e) hide widgets on side edges as a per-edge setting.
  - Open question: which widgets matter most on a side dock (clock, calendar, battery, system stats)?
  - Acceptance: on Left and Right with 27+ apps and 5 widgets, icons match the configured size, widget text is at least 11pt equivalent, nothing is clipped, and reveal/hide timing is unchanged.

---

# Milestone C: widget system

Status: built, launched with `swift run`, widgets verified rendering live data (read back through the Accessibility API). Hand test passed; committed.

## Deliverables

- [x] `WidgetProtocol.swift`: `DockWidget` protocol (kind, name, icon, size, refreshInterval, alignsRefreshToInterval, refresh/start/stop/activate, body), `WidgetSize` in tile units (small 1, medium 2, large 3), `dockTileSize` environment value, `WidgetTile` chrome
- [x] `WidgetHost.swift`: `WidgetHost` owns one widget's lifecycle and repeating `Timer` (tolerance up to 1s, optional wall-clock alignment); `WidgetCatalog` maps kind -> factory; `WidgetStore` starts/stops hosts as `DockModel.widgetKinds` changes
- [x] `Widgets/ClockWidget.swift` (medium): time + date, refreshes exactly on each minute
- [x] `Widgets/CalendarWidget.swift` (medium): date tile + next event in 24h via EventKit. Access requested only on click. Live updates via `EKEventStoreChanged`
- [x] `Widgets/WeatherWidget.swift` (small): Open-Meteo, no key; location from the time zone city (New York), no Location prompt; every 15 min
- [x] `Widgets/SystemStatsWidget.swift` (medium): CPU (tick deltas) and memory (app + wired + compressed) via Mach host statistics, every 3s
- [x] `Widgets/BatteryWidget.swift` (small): percent ring + charging bolt via IOKit power sources; event-driven with `IOPSNotificationCreateRunLoopSource`, 5 min fallback
- [x] Widget context menu "Remove Widget"; menu bar "Widgets" submenu with a checkbox per widget; list persisted as `widgetKinds` in `dock.json`
- [x] Strip fits the screen: tiles shrink below `iconSize` when everything would not fit, like the native Dock. Widgets are sized in tiles so they shrink with it.
- [x] `Info.plist` embedded into the binary (`__TEXT,__info_plist` via linker flag in `Package.swift`) so the Calendar usage description exists
- [x] `swift build` clean (no warnings); `swift run` launches and stays up

## Verified

- [x] All five widgets started; read back from the revealed panel: `8:58 PM`, `Mon, Oct 26`, `MON 26`, `Calendar / Click to connect`, `59°`, `CPU 39%`, `MEM 55%`, battery `100`
- [x] Weather fetch logged `58.7deg code 0` (clear); battery logged `100% charging=false ac=true`
- [x] Panel fits on screen: 1684pt with all widgets on a 1728pt display (was 1665 to 1719pt for apps alone at 48pt)
- [x] Saved list honored: with weather removed from `widgetKinds`, weather never started and the strip re-fit to 1712pt
- [x] Reveal/hide timings unchanged (slide completes in ~150ms)
- [x] Calendar permission prompt and next-event display (needs a human to approve)
- [x] Clock flipping on the minute, widget clicks, Remove Widget / re-enable

## Changes outside the new files

- `DockPanel.swift`: init now takes the prebuilt `DockStrip` instead of building it. No show/hide changes.
- `DockEngine.swift`: creates `WidgetStore` and `DockLayout`, stops widgets on quit. No hide-path changes.
- `PortsideApp.swift`: `DockModel` is created by the app delegate so the menu bar can observe it; Widgets submenu.
- `Package.swift` / `Info.plist`: embedded plist with `NSCalendarsFullAccessUsageDescription`.
- `EdgeTracker.swift`: unchanged.

## Findings

- Without a usage-description string, asking for Calendar access kills the process. An SPM executable has no bundle, so the plist is linked into the binary.
- Because Portside runs unbundled from a terminal, macOS may attribute the Calendar permission to the terminal app (T3 Code or Ghostty) instead of Portside. A real .app bundle fixes that later.
- A suspected "dock hides while hovering" bug during testing turned out to be James moving the real mouse while synthetic events ran (logged exit positions did not match the synthetic cursor). No change made.
- Widget timers run while the dock is hidden. All are cheap (3s stats is the most frequent); pausing them while hidden is a possible later optimization.

---

# Milestone B: pinned apps + running indicators

Status: done.

## Deliverables

- [x] `DockModel.swift`: `PinnedApp` (bundle id + path), `@Published pinnedApps`, `pin`/`unpin`/`move`, custom Codable that tolerates missing keys, saved to `dock.json` on every change
- [x] First launch seeds pins from the native Dock's `persistent-apps` (read with `CFPreferencesCopyAppValue`, never written), Finder first. Seeded 27 apps.
- [x] `RunningApps.swift`: regular-policy running apps, refreshed only on NSWorkspace didLaunch / didTerminate / didActivate notifications. No timers.
- [x] `DockItem.swift`: real icons (`NSWorkspace.icon(forFile:)`, cached), running dot, tap to launch or activate, context menu (Remove from Dock / Keep in Dock, Show in Finder, Quit)
- [x] `DockStrip.swift`: pinned apps, divider, running-but-unpinned apps; drag to reorder; Finder `.app` drops pin at the drop slot
- [x] Menu bar: "Add App to Dock..." (open panel, multi-select)
- [x] `swift build` clean, no warnings; `swift run` launches and stays alive

## Verified with synthetic events

- [x] Click running app (Notes) while ChatGPT frontmost: Notes became frontmost in ~29ms. Portside stayed inactive.
- [x] Click non-running app (Zed): launched, indicator count 15 -> 16; quit Zed: 16 -> 15
- [x] Drag Finder from slot 0 to slot 2 and back: live reorder, saved once on release, no accidental click
- [x] Right-click menu: dock stays up while the menu is open even with cursor outside panel; Escape re-arms the hide
- [x] Remove from Dock (Notes) via menu: 27 -> 26 pinned, Notes moved to the running section
- [x] Keep in Dock (CleanMyMac) via menu: appended and saved
- [x] Restart loads `dock.json` (27 pinned, order kept)
- [x] Launch Calculator while dock hidden, reveal: panel widened 1665 -> 1719pt, new tile clickable at its computed position; quit shrinks it back
- [x] Finder drag-and-drop of an .app (cannot be simulated reliably, hand test)
- [x] Hand test by James

## Changes outside the new files

- `DockPanel.swift` (layout only, no show/hide changes): init takes `runningApps`; the hosting view reports intrinsic size changes so the panel resizes when the strip width changes; hosting view autoresizes with the panel so the strip is not clipped after a width change.
- `DockEngine.swift` (hide path): the hide timer is skipped while any Portside menu is open (`NSMenu.didBegin/EndTrackingNotification`), and re-armed when the menu closes with the cursor outside the dock. Needed for context menus; still no polling.
- `EdgeTracker.swift`: unchanged.

## Findings

- SwiftUI `.onDrag` never starts a drag session from this panel (mouseDragged events do arrive; likely because Portside is never the active app), and it has no "drag ended" callback. Reorder uses a `DragGesture` in the strip instead, with `onTapGesture` for clicks.
- `NSWorkspace.openApplication` activates other apps even though Portside is inactive, so it is used for both launch and activate. For a running app it also sends the reopen event, so an app with no windows opens one, like the native Dock.
- On `didTerminateApplication`, `runningApplications` can still list the app; the terminated pid is excluded explicitly or the indicator sticks.
- With 27 pins at 48pt icons the strip is 1665 to 1719pt wide on a 1728pt screen. Pinning several more will overflow the screen edge. Icon size (native Dock tilesize is 36) is a Milestone E setting.
- One early synthetic click on a cold tile was lost before reaching Portside (no mouseDown logged); 5 later attempts all worked. Likely the native Dock popping over Portside at the bottom edge. Watch for it in the hand test.

---

# Milestone A: edge tracker + non-activating panel + slide

Status: done and hand-tested by James.

## Deliverables

- [x] `Sources/portside/DockEngine.swift`: coordinator, owns the one cancelable hide timer and all timing logs
- [x] `Sources/portside/EdgeTracker.swift`: 4pt edge window with NSTrackingArea, event-driven, no polling
- [x] `Sources/portside/DockPanel.swift`: non-activating NSPanel, slide animation, own tracking area
- [x] `Sources/portside/DockModel.swift`: minimal Codable settings (revealDelay, hideDelay, animationDuration, iconSize)
- [x] `Sources/portside/DockStrip.swift`: 5 placeholder buttons that log the frontmost app on click
- [x] `Sources/portside/PortsideApp.swift`: accessory activation policy, MenuBarExtra with Quit
- [x] `swift build` passes with no warnings (clean build verified)
- [x] `swift run` launches and stays alive (previous version crashed with SIGSEGV, exit 139)
- [x] mouseEntered verified to fire (log stream, synthetic CGEvent mouse moves)
- [x] reveal timing verified: mouseEntered -> animation start 0.2 to 0.9ms, slide completes at ~146ms
- [x] hide verified: 300ms after leaving panel, panel re-enter cancels the pending hide
- [x] mid-hide-animation re-enter verified: new reveal starts, stale completion ignored
- [x] click verified: synthetic click on item 1 logged with frontmost app unchanged, panel never key, Portside never active
- [x] hand test by James (hover feel, click while typing in another app)

## Bugs fixed (order from AGENTS.md)

1. Crash: `DockEngine` had two lazy properties referencing each other. Now `DockPanel(dockModel:)` and `EdgeTracker()` are plain stored properties wired with closures.
2. Panel never appeared: `show()` now calls `orderFrontRegardless()`; `hide()` orders out after the slide completes.
3. Edge window was alpha 0 with clear background, so it never received mouse events. Now alpha 1 with `NSColor(white: 0, alpha: 0.01)`.
4. Hide while hovering: the panel has its own tracking area (`PanelContentView`). Both edge and panel enter cancel the single `DispatchWorkItem` hide timer. Edge window sits one level above the panel so the bottom 4pt always belongs to the tracker.
5. `NSApp.activate` removed. `NSApp.setActivationPolicy(.accessory)` set in `applicationWillFinishLaunching`.
6. Logging: numeric interpolation with `format: .fixed(precision:)`, strings marked `privacy: .public`.
7. Real slide via `NSAnimationContext.runAnimationGroup` with `panel.animator().setFrame`, easeOut in, easeIn out, default 150ms from `DockModel.animationDuration`. `animated: false` and Reduce Motion both snap instantly.
8. Engine starts with the panel hidden (`prepareHidden()`), only the edge window is shown.

## Extra bugs found while verifying

- `hostingView.sizingOptions = []` made the SwiftUI intrinsic size zero, so the panel was 24x16. Now `[.intrinsicContentSize]`.
- Hosting view frame was set before the window had a size, so autoresizing inflated it and the strip rendered off-center. Clicks at the expected spot fell on transparent pixels and passed through the panel to the window behind. `layout()` now sizes the window first, then fits the hosting view.
- Panel background is `NSColor(white: 0, alpha: 0.01)` rather than clear so the whole panel is hit-testable (the window server makes fully transparent pixels click-through).
- `NSScreen.main` is unreliable from an accessory app; geometry uses `NSScreen.screens.first` (the primary display).
- Native Dock conflict: with the native Dock auto-hiding at the bottom, parking the cursor on the bottom pixel reveals it on top of Portside and it eats the click. Expected until Milestone F. Moving up into the panel right after touching the edge avoids it.

## Findings

| File | Description |
|------|-------------|
| **DockEngine.swift** | Owns `EdgeTracker` + `DockPanel`. `handleEnter` cancels the pending hide and reveals (optionally after `revealDelay`). `handleExit` arms the one-shot hide; when it fires it does a single `NSEvent.mouseLocation` sanity check and stays up if the cursor is still over the panel or edge. Logs mouseEntered -> animation start -> interactive -> finished. |
| **EdgeTracker.swift** | 4pt-tall borderless `NSWindow` across the bottom of the primary screen at level popUpMenu+1. `EdgeView.updateTrackingAreas` installs `[.mouseEnteredAndExited, .activeAlways, .inVisibleRect]`. Swallows clicks in the strip. Repositions on screen parameter changes. |
| **DockPanel.swift** | `PortsidePanel` (NSPanel subclass, `canBecomeKey` false, `constrainFrameRect` passthrough) at level popUpMenu, `.nonactivatingPanel`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`. State machine hidden/revealing/revealed/hiding with a generation counter so an interrupted animation's completion is ignored. `FirstMouseHostingView` accepts first mouse and logs mouse downs. |
| **DockModel.swift** | Codable class, persisted to `~/Library/Application Support/com.james.portside/dock.json`. Defaults: hideDelay 0.3, animationDuration 0.15, iconSize 48. |
| **DockStrip.swift** | SwiftUI strip on `.ultraThinMaterial`. Each tile is a `Button` that logs `item N clicked, frontmost app: X, portside active: Y`. |
| **PortsideApp.swift** | `@main` SwiftUI App whose only scene is a `MenuBarExtra` (bird icon) with Quit. `AppDelegate` sets accessory policy, starts the engine, stops it on terminate. |

## Notes

- Zero polling in the reveal/hide path. Timers present: one hide-delay `DispatchWorkItem`, one reveal-delay `DispatchWorkItem` only when `revealDelay > 0` (default 0).
- Logs: `/usr/bin/log stream --level info --predicate 'subsystem == "com.james.portside"'` (use the full path; zsh has a `log` builtin).
- `Info.plist` at the repo root is not used by the SPM executable; the accessory policy is set in code instead.
- Panel is 316x80 for the 5 placeholder tiles, centered horizontally on the primary display.

## Follow-up: widget contrast and side label tail

- [x] Replace the compact System Stats percentage stack's negative spacing with a positive gap proportional to the tile size (4%), so the CPU and memory rows stay separated on side docks. Wide layout unchanged. Planned features reviewed; no backlog change.
- [x] Increase the compact rings' diameter, reduce their stroke and inter-ring gap, and narrow the centered text with a slightly smaller bold font so the percentages have clearance from the inner ring.
- [x] `swift build` succeeded after the clearance changes; `swift run portside` launched without a reported error and was stopped with Ctrl+C. Wide ring geometry is unchanged.
- [ ] Hand-check the percentage gap and inner-ring clearance at the user's icon size on Left and Right, including three-digit percentages.
- [x] System Stats percentages use larger, heavier white text and the wide legend uses brighter, larger labels for contrast against its dark widget card. The bottom layout is unchanged.
- [ ] Verify on-device at the user's icon size, especially the two percentages in the compact side-dock tile.
- [ ] Verify hover label tail points toward the dock on both Left and Right; the path maps the bottom tail to the inner edge for each side orientation.
