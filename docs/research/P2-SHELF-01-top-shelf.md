# P2-SHELF-01: Bartender Top Shelf research

2026-11-11. Research only. No Swift source changed. Nothing from the reference is reproduced beyond short identifiers and UI strings needed as evidence. Follows [P2-REA-03](P2-REA-03-bartender.md), which covered menu bar item hiding, not Top Shelf.

Evidence labels used below: **O** observed at runtime on this Mac, **C** code evidence from the shipped artifact (strings, Swift reflection metadata, imports, plists), **I** inference, **U** unknown.

## Report header

```text
Reference:        Bartender 7, com.surteesstudios.Bartender, 7.1.0 (build 700013), /Applications/Bartender 7.app
Executable:       "Bartender 7", universal (x86_64, arm64), arm64 slice UUID BE69F2E2-5505-3582-AD51-FD771A2B5F12
SHA-256:          febad19b0bae13b55bd3e814fa5f416e4f5546a8a3929e8e48609ecf5328e3ea (same build as P2-REA-03)
Host:             macOS 27.0.1 (26A434), arm64, notched built-in display
REA:              open_binary + inspect_macho (evidence ev_d05ef8ae..., summary ev_8bfc3ae3...). No deep provider
                  configured (Ghidra needs GHIDRA_INSTALL_DIR and Java, Hopper missing, IDA and Kuna unconfigured),
                  through REA. Strings and Swift reflection strings were read from the thinned arm64 slice with
                  `strings` and `otool` (section __TEXT,__swift5_reflstr). Decompilation (chunk 5) used Ghidra 12.2
                  headless directly on that slice with JDK 27 (full auto-analysis 546 s), outside REA, because the
                  REA server's Ghidra settings come from its launch environment. Swift symbols are stripped;
                  Objective-C entry points of the NotchBar classes are named.
Bartender state:  Not running at start of research. Not launched, not configured. Its preferences were not read.
```

## Chunk 0: artifact, symbols, resources, settings, entry points

### Identity and packaging (C)

- Top Shelf is Bartender's internal **NotchBar** subsystem. Strings: `Bartender/NotchBar`, `NotchBar.NotchPanel`, `NotchBar.TopShelfEnabledChanged`, source paths `NotchBar/*.swift`. Resource bundles `NotchBar_NotchBar.bundle` (Assets.car, `default.metallib`, so Metal shaders) and `NotchBar_BartenderMusic.bundle` (an embedded `MediaRemoteAdapter.framework` plus a perl helper).
- Marketing copy calls it "the Dynamic Island for Mac", "with or without a notch", a **Bartender Pro** upgrade ("Unlock Top Shelf").
- Pitch string lists the scope: "music, weather, calendar, files, clipboard, agents, and quick context".

### Surface model (C)

State enum cases next to `NotchState`: `hidden`, `compact`, `hover`, `expanded`, `tray`. Types: `NotchPanel`, `NotchView`, `NotchContentView`, `NotchShape`, `TopShelfSurfaceShape`, `NotchSurfaceFrameMetrics`, `NotchIndicatorController`, `ActivityManager`, `ActivityPriority`, `ActivityLifecycleState`.

I: a borderless panel sized to the notch shows a **compact** strip with leading and trailing views beside the notch (`*CompactView`, `*TrailingCompactView`), grows to a **hover** card (`*HoverView`, `*HoverCardView`) and opens a **tray** (the "shelf") with pages. Activities compete by priority for the compact slot.

### Content modules (C)

| Area | Types / strings |
| --- | --- |
| Live activities in the compact strip | Music, Weather, Calendar, Battery, AirPods, Volume, Brightness, Agent (`*Activity`), banners (`MusicSongBanner`, `AgentCompletionBanner`, `CalendarWarningBanner`) |
| Tray pages | `TrayPage`, `ShelfDefaultPage` cases `none widgets files clipboard lastUsed`; `TrayWidgetsView`, `TrayFilesView`, `TrayClipboardView` |
| Tray widgets | `TrayWidgetType`, one widget per side (`trayLeadingWidget`, `trayTrailingWidget`): music, `VinylWidget`, `TrayWeatherWidget`, calendar |
| Files | drag files onto the notch for temporary storage, drag out to use, optional AirDrop target, retention duration, delete after successful drag |
| Clipboard | history with search tokens (app, kind), sensitive filter, ignored apps, max items, retention; also a command-bar search panel |
| Agents | Codex and Claude Code hooks posting to a local HTTP bridge on 127.0.0.1 (`AgentStatusBridge`, provider `both codex claude`); installer edits the agent config with a `.topshelf-agents.bak` backup |
| HUDs | volume and brightness indicator in the notch (`SystemVolumeKeyInterceptor`, event tap) |

### Settings model (C, Swift reflection field names of the settings object)

`topShelfEnabled`; music: `musicProvider musicEnabled musicHideWhenPaused musicShowBannerOnChange musicHoverVividMode`; agents: `agentStatusProvider agentCompletionNotificationsEnabled agentCompletedTaskDismissDuration`; calendar: `calendarEnabled calendarWarningMinutes enabledCalendarIdentifiers calendarUseCalendarColor calendarMeetingTimerEnabled calendarAlertDuration calendarCustomColor`; surface: `backgroundStyle autoHideDelay hapticsEnabled showOnScreensWithoutNotch displayTargetMode openSettingsOnLaunch shrinkNonNotchWhenIdle hideInFullscreen nonNotchBackgroundColor nonNotchBackgroundStyle nonNotchBackgroundMaterial`; HUDs: `volumeHUDEnabled volumeHUDDuration brightnessHUDEnabled brightnessHUDDuration`; AirPods, weather alerts (rain, snow, ice), battery alerts with thresholds and durations; tray: `trayEnabled defaultShelfPage trayLeading/TrailingWidget`, per-side `SimpleTitles ShowGradient ShowControls`; files and clipboard retention and drag options; hotkeys: `hotkeyTrayDuration hotkeyFilesDuration hotkeyClipboardDuration`.

Duration enum: `fifteenSeconds thirtySeconds oneMinute fiveMinutes tenMinutes`. Material enum: `ultraThin thin regular thick ultraThick`.

U: on-disk key names and defaults domain (not read, per AGENTS.md rule 7).

### Display placement (C)

`DisplayTargetMode` cases `followFocused preferNotch showAll`, plus `showOnScreensWithoutNotch`. UI copy pairs them: "Prefer Display With a Notch", "Moves Top Shelf to the monitor you're currently using (only if that display has a physical notch)", "Shows Top Shelf on every connected display that has a physical notch" or "every eligible display, including floating capsule displays". Non-notch screens get a **floating capsule** ("Display as a floating capsule on screens without a physical notch", "Use a smaller capsule while compact and idle") with its own background style and material. Fields: `notchWidth notchHeight notchClearance notchObscured hasNotch isOnNotchedDisplay activeDisplayBounds windowControllersByDisplay`.

### Interaction (C)

- Strings: "The shelf appears when you click the notch", "Show shelf pages on click", "Hover the notch center to open tray widgets", "Hover delay before activating", "Hover over the indicators or album art". Fields `hoverHapticCooldown lastHoverHapticAt hapticsEnabled` (`NSHapticFeedbackManager` imported), `autoHideDelay`, `hoverOutTask`.
- Hotkeys: "Open or close the shelf", "Open tray directly to Files page", "Open Clipboard search from anywhere"; each hotkey-opened tray stays for its own duration setting.
- Full screen: "Hide NotchBar while the active space is fullscreen", `isSuppressedForFullscreen`, `fullscreenClearDelay`, "Suppressing screen-change recompact while fullscreen state is settling".
- Drag and drop: `isFileDragOverNotch`, `DragDropBridge`, `NotchBarDragExports`.

### Menu bar coupling (C)

`TopShelfMenuBarCoordinator`, `topShelfSpacerItem`, `HiddenMenuItemsAndThoseNotVisibleByNotchOrMenu`, "Prevents clicked items from being hidden behind the notch by placing them after your always-shown items". I: Bartender reserves a spacer status item so its own menu bar layout leaves room for the shelf, and treats items obscured by the notch as hidden. U: exact behavior; no call path.

### Platform dependencies (C)

| Need | Mechanism | Public? |
| --- | --- | --- |
| Now playing and control | `MediaRemote.framework` (private), embedded MediaRemoteAdapter, Apple Events to Music/Spotify | Private + Automation consent |
| Volume/brightness HUD | `CGEventTapCreate` for volume keys, `DisplayServices`/`CoreDisplay` brightness (private) | Tap needs Accessibility or Input Monitoring; brightness private |
| Full-screen detection | `CGSGetActiveSpace`, `CGSSpaceGetType`, `CGSCopyManagedDisplaySpaces`, `CGSCopyActiveMenuBarDisplayIdentifier`, SkyLight | Private |
| Weather | WeatherKit + CoreLocation | Public, entitlement |
| Calendar | EventKit | Public, Calendars consent |
| AirPods battery | Bluetooth | Public, Bluetooth consent |
| Agents | local HTTP bridge + hook install into agent configs | Public |
| Haptics, hover | `NSHapticFeedbackManager`, `NSTrackingArea` | Public |

Usage descriptions in Info.plist: Bluetooth, Location, Apple Events, Calendars. No Screen Recording requirement is tied to Top Shelf in strings (U).

### Chunk 0 unknowns

- No code paths: no deep REA provider, so ordering of state transitions, hover delays, panel window level and collection behavior are unread.
- Whether hotkeys open the tray without activating Bartender (focus behavior).
- Whether the tray is keyboard navigable.
- Licensing gate on this install (Pro or not) and whether Top Shelf is enabled.

## Runtime limitation (chunks 1 to 4)

Bartender was not running, and the installed Portside (`/Applications/Portside.app`, pid 27626 with its native Dock watcher) was. Launching Bartender would start its own menu bar hiding next to Portside's, so it was **not launched or driven** without the maintainer's approval. No **O** rows exist for Top Shelf itself. Behavior below combines code evidence (C) with published reviews (R), labeled per row. Reviews: Six Colors (Moren, 2026-05), 9to5Mac (2026-05-12), macbartender.com Bartender Pro post, Michael Tsai link post (2026-05-29). They describe Bartender 6 Pro; this artifact is Bartender 7.1.0, so details may have changed (U).

## Chunk 1: content, actions, customization, ordering, persistence

| Topic | Finding | Basis |
| --- | --- | --- |
| Pages | Three tray pages: Widgets, Files, Clipboard. Selected by icons at the top left of the expanded shelf | R, C (`TrayPage`) |
| Default page | Settable: none, widgets, files, clipboard, or last used | R, C (`ShelfDefaultPage`) |
| Widgets page | Exactly two slots, leading and trailing. Choices: Now Playing (Music or Vinyl style), Weather, Calendar. Per slot: simple titles, gradient, controls | R, C |
| Ordering | No free reordering found. Order is the fixed page list and the two fixed widget slots | R, C (I: no list editor) |
| Files | Drop files on the notch; up to six items, kept up to a week (retention setting); drag out or copy; optional delete after drag; AirDrop drop target | R, C |
| Clipboard | Up to 100 items, kept up to a week, survives reboot; search (app and kind tokens), pinning, drag out; sensitive filter; ignored apps. A separate floating clipboard search window copies but does not paste | R, C |
| Live activities | Compact strip beside the notch: music (art + waveform, hover for controls), calendar (warning N minutes before, join link, meeting timer), weather alerts (rain, snow, ice), battery (charging, low threshold up to 30 %), AirPods, volume and brightness HUD, Codex and Claude Code agents with completion banners | R, C |
| Actions | Join meeting URL, music transport, AirDrop, copy clip, drag file. No user-defined actions or app launchers found | R, C (U for completeness) |
| Persistence | Settings on an observable settings object (field list in chunk 0). Clipboard persisted to disk. File tray persistence across relaunch U | C, R |

## Chunk 2: opening, dismissal, hover, keyboard, click

| Topic | Finding | Basis |
| --- | --- | --- |
| Open by hover | Pointer up to the notch expands the surface. "Hover delay before activating" is a setting. Hover on the notch center opens tray widgets; hover on music art opens controls | R, C |
| Open by click | "The shelf appears when you click the notch" and a "Show shelf pages on click" option exist; reviews mention hover only. I: hover shows the hover card, click (or an option) opens the full tray | C, I |
| Dismissal | `autoHideDelay`, `hoverOutTask`: pointer leaving collapses after a delay. Hotkey-opened tray stays for its own duration (15 s to 10 min enum) | C, I |
| Keyboard | Hotkeys: open or close the shelf, open directly to Files, open clipboard search. No evidence of arrow or Tab navigation inside the tray | C, R (U) |
| Haptics | Optional haptic on hover, with a cooldown | C |
| Automatic expansion | Volume, brightness, battery and song change briefly expand the capsule | R, C |
| Focus | Whether the panel activates Bartender or takes key status: U | U |

## Chunk 3: layout around the notch and on other displays

| Topic | Finding | Basis |
| --- | --- | --- |
| Notched display | Black surface continuous with the notch (`NotchShape`), compact content left and right of the notch, grows down when hovered or open. Background style: solid black when collapsed, fading to glass as it expands | C, R |
| Non-notched display | Floating capsule centered in the menu bar, own background style, color and material; optional smaller capsule when idle | C, R |
| Which displays | `followFocused`, `preferNotch`, `showAll`, combined with "show on screens without a notch" | C |
| Metal | `default.metallib` in the NotchBar bundle: some effects are shaders | C |

## Chunk 4: hidden menu bar items, full screen, multiple displays, permissions, OS

| Topic | Finding | Basis |
| --- | --- | --- |
| Hidden items | Top Shelf gets out of the way when the Bartender Bar expands; a spacer status item and "items hidden by notch" handling keep items from sitting behind the notch | R, C |
| Hover conflict | On a Studio Display, hover was ambiguous between revealing hidden items and opening Top Shelf | R |
| Full screen | Option "Hide in fullscreen", detected with private CGS space calls; a settle delay before re-layout | C |
| Mission Control / Spaces | Reported collisions with Mission Control on an external display | R |
| Multiple displays | One window controller per display; placement modes as in chunk 3 | C |
| Permissions | Calendars (EventKit), Location (WeatherKit), Bluetooth (AirPods), Automation (Music, Spotify), Accessibility (volume key event tap, menu bar work). Media via private MediaRemote; brightness via private DisplayServices | C |
| OS | Reviews tie Bartender 6 Pro to macOS 26; this 7.x build targets macOS 27, minimum 14.0 in plist. MediaRemote access is restricted for third parties since macOS 15.4, hence the embedded adapter | C, R, I |

## Chunk 5: code paths (Ghidra)

Addresses are in the arm64 slice. Swift functions are unnamed (`FUN_...`); they were found as callers of named Objective-C stubs and imports, limited to the NotchBar address range (about 0x100e60000 to 0x101060000), and identified by the `NotchIndicatorController` fields they touch.

| ID | Finding | Evidence | Basis |
| --- | --- | --- | --- |
| G1 | `NotchPanel` init: style mask `0x80` (non-activating panel, borderless), buffered, clear background, no shadow, `setLevel(25)` (status bar level), `setCollectionBehavior(0x51)` = `canJoinAllSpaces \| stationary \| ignoresCycle`, not movable | `FUN_100e8e7ec` | C |
| G2 | No `fullScreenAuxiliary` in G1, so the window system keeps the panel off full-screen Spaces by itself; the CGS code below handles the remaining cases and the settle delay | G1 | C, I |
| G3 | `NotchPanel.canBecomeKeyWindow` returns true, `canBecomeMainWindow` false, private override `_hasActiveAppearance` returns true (always draws as active), `constrainFrameRect:toScreen:` returns the frame unchanged (lets it sit over the menu bar and notch) | `100e8e7d4`, `100e8e7dc`, `100e8e7e4`, `100eb1b6c` | C |
| G4 | A separate `InteractiveWindow` class can become key and main (I: onboarding or settings-like surfaces, not the shelf) | `100e8e72c`, `100e8e734` | C |
| G5 | `NotchIndicatorController.clickMonitor`: global `NSEvent` monitor, mask `2` (left mouse down). I: click outside closes the open tray. Global mouse monitors need no permission | `FUN_100ea8aec` | C, I |
| G6 | A local monitor with mask `0x414` (left mouse up, right mouse up, key down) exists in the NotchBar range. I: Esc and click handling while the panel is key | `FUN_100e6cc2c` | C, I |
| G7 | Hover handler (`FUN_100ea2078`) is per display (`hoverByDisplay`, `_activeDisplayID`), ignored while `_ignoresInteraction`. Haptic `performFeedbackPattern(1 /* alignment */)` at most every 0.35 s (`lastHoverHapticAt`) | `FUN_100ea2078` line 402 | C |
| G8 | On hover exit: in the hover state (`_state == 2`) it schedules a delayed collapse task; in the tray state (`_state == 4`) it cancels and reschedules `hoverOutTask`, **unless `openedViaHotkey`**, in which case hover exit does nothing and `hotkeyAutoCloseTask` (the per-page hotkey duration) closes it | `FUN_100ea2078` lines 165, 283 | C |
| G9 | State order from reflection: `hidden 0, compact 1, hover 2, expanded 3, tray 4`; matches the comparisons in G8 | reflection + G8 | C |
| G10 | Full screen: four functions call `CGSGetActiveSpace` and `CGSSpaceGetType` and drive `fullscreenClearTask` (debounce) and `isSuppressedForFullscreen`; one calls `CGSCopyManagedDisplaySpaces` | `FUN_100e9d720`, `FUN_100e9de78`, `FUN_100e9e338`, `FUN_100ea1c50` | C |
| G11 | Notch geometry uses public `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (8 callers in range) | `FUN_100eae488` and others | C |
| G12 | `NSTrackingArea` init has 10 callers app-wide; hover is tracking-area driven, not polled (I, callers outside NotchBar range not mapped) | caller count | C, I |

Not recovered: delay constants (they live in async task closures referenced by descriptor, not followed), the exact click-to-open path, and the CGS space type compared against.

## Chunk 6: supervised runtime run (2026-11-11)

Setup: the maintainer chose to quit Portside for the run (graceful quit; it removed its `autohide-delay` and left the user's own `autohide = 1`). Bartender 7.1.0 launched with Pro active, one notched display (1728 x 1117 pt), Dark mode, macOS 27.0.1. The pointer was driven with posted `mouseMoved` and left click events from a scratch tool; frames were captured with `screencapture` about every 110 ms; the pointer was logged every 20 ms. Clicks landed only on the notch, the shelf's own tabs and empty transcript text in T3 Code. Bartender's settings were not opened. Its "last used page" state ended on Clipboard. A Bartender "Software Update" window (7.2.0 available) appeared at launch and was left alone; quitting Bartender closed it. Afterwards Bartender was quit and Portside relaunched; Portside re-applied its native Dock hiding.

| ID | Observation | Basis |
| --- | --- | --- |
| R1 | Bartender runs `/usr/bin/perl mediaremote-adapter.pl ... stream --debounce=125` from its bundle: an Apple-signed host process reads MediaRemote, a workaround for the third-party restriction | O (`pgrep`) |
| R2 | Windows: one layer-25 panel 1728 x 500 at the top of the screen (a fixed transparent canvas; the shelf draws inside it), a layer-24 `MenuBarRoundedCover` 1728 x 45, and a desktop wallpaper helper | O (`CGWindowList`) |
| R3 | The panel's AX tree exposes almost nothing (one `AXStaticText`); shelf content is not accessible to VoiceOver or AX tools | O (AX walk) |
| R4 | Idle compact strip: an animated agent lamp left of the notch and an orange count "1" right of it (one agent session), animating on a ~2.5 s cycle | O (screens) |
| R5 | Posted (synthetic) `mouseMoved` events on the notch center or its sides never opened anything, twice per position, although the pointer really moved there. I: Bartender ignores synthetic pointer input for hover (event tap or tracking source filter). Earlier reading "hover does not open" was wrong; see R14 | O, I |
| R6 | A click on the notch opened the shelf: growth began within one frame (≤ 0.1 s) and finished in about 0.25 s; open size about 614 x 172 pt | O |
| R7 | Open layout: a top row at menu bar height with three page tabs at the left (Widgets, Files, Clipboard) and Search plus Settings buttons at the right (Search only on Files and Clipboard). Widgets page: two cards about 290 pt wide (Now Playing with art, title, artist, prev/play/next; Weather with temperature, place, local time, condition, high/low) | O (screens) |
| R8 | Files page: "Drop Files Here, Files kept for a day" zone plus an AirDrop card. Clipboard page: "Clipboard Empty, Items kept for a day" | O |
| R9 | The frontmost app stayed T3 Code through open, tab clicks and close: the shelf never activates Bartender | O (`NSWorkspace.frontmostApplication`) |
| R10 | Esc did not close the shelf (the panel never took key, so Esc went to the frontmost app) | O |
| R11 | A second click on the notch while open did **not** close it | O |
| R12 | Pointer leaving the shelf: collapse began about 0.85 s later and finished about 0.5 s after that. A click outside: collapse began within about 0.05 s of mouse down | O |
| R13 | Reopening shows the last used page (Clipboard after the tab test) | O |
| R14 | Second run (maintainer correction: hover lives on the notch **sides**). The maintainer's real pointer reached the left side of the notch (751, 20) at 12.40 s; a hover card started growing on the next frame (12.57 s) and was full by 12.77 s: hover delay about 0.1 to 0.2 s, no click | O |
| R15 | The side hover card belongs to the activity shown on that side: here the agent card (pixel lamp, thread name, "Executing task", provider badge "Claude", "now"), about 326 x 94 pt, left of and below the notch | O (screen) |
| R16 | Leaving the hover card downward collapsed it within about 0.1 to 0.3 s (faster than the open shelf's ~0.85 s grace) | O |
| R17 | Real pointer moved from the hover card up into the notch (859, 0): the full shelf opened within about 0.1 s, no click. Whether the notch center opens the shelf from idle (without a hover card first) was not isolated | O, U |

Limits: R1 to R13 used synthetic posted events, which Bartender's hover ignores (R5); R14 to R17 come from the maintainer's real pointer during a second run with the same setup (Portside quit and relaunched again, native Dock hiding re-applied). No music was playing, so the music compact and hover-on-art behavior were not seen. External displays and full screen were not run.

## Remaining unknowns

- Delay defaults (hover, collapse); answered for window level, Spaces and key behavior by G1 to G3.
- Whether click is required for the tray.
- File tray persistence across relaunch; keyboard navigation inside the tray.
- Bartender 7 changes since the reviewed 6.x release.

## Comparison with Portside (nightly at 653a948b)

| Top Shelf piece | Portside today | Gap |
| --- | --- | --- |
| Notch surface, non-notch capsule, per-display choice | Agent Notch: non-activating `NSPanel` at `.statusBar`, `[.canJoinAllSpaces, .fullScreenAuxiliary]`, attached or below, notch or menu bar capsule, display choice, hover expand with `hoverDelay` / `collapseDelay`, pin | Only agent content; no pages; no click-to-open tray; no hotkey |
| Widgets page | Widget set (`WidgetProtocol`, `Widgets/`): Now Playing, Calendar, Weather, Agents, AI Usage, Clock, System Stats, sizes Small/Wide/Extra Wide | Needs a host that renders two widgets in the shelf |
| Files tray | `FileDrop`, `DragOut`, `TrashDrop`, folder stacks with drag out | No temporary holding tray |
| Clipboard | Command Center `ClipboardHistory` (CMD-04, keychain-backed, opt-in module) | No shelf view |
| Live activities | Agent Notch agent states; Now Playing; Calendar next event | No shared priority strip |
| Hidden items coordination | Menu Bar module: triggers (hover, click, scroll), Portside Bar incl. `portsideBarOnNotch`, overflow panel at `.statusBar` | No notch exclusion zone; shelf and Portside Bar on notch would overlap |
| Hotkeys | `HotKey.swift`, `HotkeyConflicts` | none for a shelf |

Open PR **#73** (`fix/macos26-menu-bar` -> nightly, OPEN, mergeable CLEAN, not merged) changes `MenuBarShelf`, `MenuBarShelfModule`, `MenuBarOverflowPanel`, `MenuBarTriggerLive` and settings panes. Shelf work that touches menu bar coordination must start after it merges or rebase onto it.

## Locked v1 scope (maintainer decisions, 2026-11-11)

Working name "Notch Shelf". Decided in a grilling session; supersedes the earlier proposal.

### Ownership and surface

- **Grows Agent Notch.** One panel per eligible display owns the notch region. Agent Notch compact content becomes the compact strip; its placement and style settings carry over.
- States: compact, peek, open (shelf with pages). Panel stays non-activating; it may take key only after a click inside it, so Esc can close it.
- Window setup follows G1: `.statusBar` level, `canJoinAllSpaces`, `stationary`, `ignoresCycle`; `.fullScreenAuxiliary` only when "Show in full screen" is on.

### Opening and closing

- Setting **Open shelf**, three values: **Hover** (default; rest 0.25 s, adjustable), **Click**, **Hover opens, click pins**.
- Closes when the pointer leaves (existing collapse grace) unless pinned, on a click outside (global left-mouse-down monitor, G5), or on Esc while key.
- **No hotkeys in v1**, so no keyboard navigation inside the shelf. No haptics.

### Pages

- v1 pages: **Widgets**, **Agents**, **Clipboard**. Files tray is out of v1.
- Settings: reorder pages, turn pages off, choose the starting page (a fixed page or last used).
- **Widgets:** one row, 1 to 4 slots (default 2), reorderable. Eligible widgets: Now Playing, Calendar, Weather, AI Usage, System Stats, CPU, Memory, Battery, Clock.
- **Agents:** session list (provider, project, status, elapsed; click focuses the host through `AgentFocus`), recently done sessions for the existing dismiss duration, AI Usage summary, provider filter chips.
- **Clipboard:** a view of Command Center `ClipboardHistory`. The page is hidden while that module is off; Settings explains the dependency with a button to Integrations.

### Compact strip (live activities)

- Sources: agents working or done, now playing, meeting soon, battery and charging alerts.
- Default priority: short alerts (battery, plug in, agent finished) > working agents > meeting soon > now playing. The order can be rearranged in Settings.
- Defaults: meeting countdown starts 5 minutes before; low battery at 20 %; banners show 4 s. All adjustable.

### Displays and full screen

- Default: only the built-in notched display. Setting adds other displays (a capsule in the menu bar) or the pointer's display only, reusing the Agent Notch display options.
- Full-screen Spaces: hidden by default; "Show in full screen" keeps it.

### Menu bar hiding

- While the shelf is on, the Menu Bar module's "Show hidden items" is locked to **In the Portside Bar**, with a note in Settings explaining that the notch belongs to the shelf. Hovering the notch always goes to the shelf, never to hidden item reveal. Menu bar triggers exclude the notch rect plus a margin.
- Depends on PR #73 (open). SHELF-02 starts after it merges.

### Out of v1

Hotkeys and keyboard navigation, Files tray and AirDrop, haptics, volume and brightness HUD, AirPods and weather alerts, MediaRemote, Metal effects.

### Implementation sequence (one PR each)

1. **SHELF-01** surface state machine in Agent Notch (compact, peek, open), the three open modes, tests for transitions; behind a setting, no pages yet.
2. **SHELF-02** input and coordination: hover delay, click, pin, click outside, Esc, collapse grace; notch exclusion in Menu Bar triggers and the locked reveal location (after #73).
3. **SHELF-03** page host with tabs, order, visibility, starting page; Settings pane and preview.
4. **SHELF-04** Widgets page, 1 to 4 slots.
5. **SHELF-05** Agents page.
6. **SHELF-06** Clipboard page bound to `ClipboardHistory`.
7. **SHELF-07** compact strip priority with rearrangeable order, meeting and battery alerts.
8. **SHELF-08** displays, full screen, hardening, hand matrix on macOS 26 and 27; `docs/DATA.md` keys.

### Runtime-informed tuning (from chunk 6)

- Hover on the sides of the notch opens that side's activity card after about 0.1 to 0.2 s (R14, R15); moving up into the notch then opens the full shelf (R17). Portside's peek state maps to these side cards.
- Open animation about 0.25 s; collapse after the pointer leaves with about 0.85 s grace, animation about 0.5 s; click outside collapses at once. Portside's defaults follow these numbers.
- Portside improves on two observed gaps: Esc closes the shelf once it has key (R10), and a second click on the notch closes it in Click mode (R11).
- Shelf content must expose AX labels (R3 shows Bartender does not).
