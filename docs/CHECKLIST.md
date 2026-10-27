# Portside: Checklist

Roadmap mirrors `docs/PLAN.md`. Milestones A to C are done. B.5 is built (hand test pending; label placement fix awaiting hand test). Next up is B.6, then D.

## Roadmap

- [x] **A:** Edge tracker + non-activating panel + slide
- [x] **B:** Pinned apps + running indicators + drag reorder + persistence
- [x] **C:** Widget protocol and widgets (clock, calendar, weather, system stats, battery)
- [x] **B.5:** Hover labels with a reusable overlay panel (built, hand test pending; label placement fix awaiting hand test)
- [ ] **B.6:** Dock position (bottom/left/right) and separator resize
- [ ] **D:** App groups (expand/collapse)
- [ ] **E:** Settings window (reveal/hide delay, animation, icon size, magnification, dock position, widgets, groups) applying live
- [ ] **F:** Native Dock hide/restore (autohide-delay trick only), launch at login (`SMAppService`), import `persistent-apps` and `persistent-others` from `com.apple.dock`, plus native orientation and tilesize as Portside's initial position and icon size
- [ ] **Live on it:** Daily-drive checkpoint with notes before starting P1
- [ ] **P1:** Right-click context menu (Keep in Dock, Open at Login, Show in Finder, Hide, Quit, Remove); click-and-hold opens the same menu; divider right-click (Turn Hiding On/Off, Magnification, Position on Screen, Dock Settings); Option turns Quit into Force Quit; drag apps in from Finder; drag icons out to remove; drop files onto app icons to open them; launch bounce; Cmd-click (Reveal in Finder); Option-click (Hide Others); Cmd-Option-D show/hide
- [ ] **P2:** Trash (full/empty + drag-to-trash, Full Disk Access note); right-click Trash shows Empty Trash; filesystem folder stacks (fan/grid/list, separate from app groups); section divider; system glass/translucent material matching the native Dock (Reduce Transparency and Reduce Motion); spring-loaded drag; magnification polish
- [ ] **P3:** Follow the display the cursor hits; fullscreen apps and Spaces; badge counts via the real Dock's accessibility tree (Accessibility permission; private APIs only as fallback); window list in right-click menu with click to focus (Screen Recording for titles); VoiceOver labels and keyboard navigation; do not reveal while dragging a window or holding the mouse button (except file drags headed to the Dock)
- [ ] **Out of scope (do not build):** minimized windows in the Dock; attention bouncing from other apps; two-finger swipe App Expose gesture; assigning apps to Spaces from the menu; the recents section
- [ ] **Enhancements:** more widgets; app groups (D); window previews on hover (on B.5 overlay); profiles

---

# Milestone B.5: hover labels and overlay panel

Status: built, launched with `swift run`, verified with synthetic mouse events and logs. Waiting on the human hand test. Label placement fix is built and needs hand-test confirmation before B.5 is done. Next after B.5 sign-off is B.6.

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
  - [ ] Hand test confirms placement and size look native

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
- Left/right edge placement is implemented in `OverlayPanel.frame` but untested until B.6 moves the dock.
- Labels run only on hover targets; widgets and D's folders opt in with the same modifier.

---

# Milestone B.6: dock position and separator resize

Status: not started. Blocked on B.5 hand test and label placement follow-up.

## Deliverables

- [ ] Dock position: bottom, left, or right (persisted; switchable live via a temporary menu bar item until Milestone E)
- [ ] `EdgeTracker`: edge window and tracking area per edge
- [ ] `DockPanel`: frames computed per edge from `visibleFrame` (avoid the menu bar); slide in from and hide toward the chosen edge
- [ ] `DockStrip`: horizontal on the bottom, vertical on the sides; indicators, labels, magnification direction, and the future folder popover anchor follow orientation
- [ ] Native-style separator drag to resize icon size live (resize cursor, clamped, persisted; dock stays revealed during the drag)
- [ ] `swift build` clean; `swift run` launches and stays up

## Hand test must also check

- [ ] (a) The edge strip does not swallow clicks: try resizing a window from its bottom edge and clicking a control at the very bottom of an app. If blocked, shrink the strip to 1 to 2pt or switch to an event-driven global mouse-moved monitor.
- [ ] (b) Reveal timing logs are unchanged.

## Notes

- Dock on left/right and the resize handle moved here from P2/P3.
- Temporary menu bar position control is replaced by Settings in Milestone E.

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
- [ ] Calendar permission prompt and next-event display (needs a human to approve)
- [ ] Clock flipping on the minute, widget clicks, Remove Widget / re-enable (hand test)

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
- [ ] Finder drag-and-drop of an .app (cannot be simulated reliably, hand test)
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
