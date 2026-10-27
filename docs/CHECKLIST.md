# Portside: Checklist

Roadmap mirrors `docs/PLAN.md`. Milestones A to C and B.5 are done. B.6 is built and waiting on the hand test. Next up is D.

## Roadmap

- [x] **A:** Edge tracker + non-activating panel + slide
- [x] **B:** Pinned apps + running indicators + drag reorder + persistence
- [x] **C:** Widget protocol and widgets (clock, calendar, weather, system stats, battery)
- [x] **B.5:** Hover labels with a reusable overlay panel (including the label placement fix)
- [x] **B.6:** Dock position (bottom/left/right) and separator resize (built, hand test pending)
- [ ] **D:** App groups (expand/collapse)
- [ ] **E:** Settings window (reveal/hide delay, animation, icon size, magnification, dock position, widgets, groups) applying live
- [ ] **F:** Native Dock hide/restore (autohide-delay trick only), launch at login (`SMAppService`), import `persistent-apps` and `persistent-others` from `com.apple.dock`, plus native orientation and tilesize as Portside's initial position and icon size
- [ ] **Live on it:** Daily-drive checkpoint with notes before starting P1
- [ ] **P1:** Right-click context menu (Keep in Dock, Open at Login, Show in Finder, Hide, Quit, Remove); click-and-hold opens the same menu; divider right-click (Turn Hiding On/Off, Magnification, Position on Screen, Dock Settings); Option turns Quit into Force Quit; drag apps in from Finder; drag icons out to remove; drop files onto app icons to open them; launch bounce; Cmd-click (Reveal in Finder); Option-click (Hide Others); Cmd-Option-D show/hide
- [ ] **P2:** Trash (full/empty + drag-to-trash, Full Disk Access note); right-click Trash shows Empty Trash; filesystem folder stacks (fan/grid/list, separate from app groups); section divider; system glass/translucent material matching the native Dock (Reduce Transparency and Reduce Motion); spring-loaded drag; magnification polish
- [ ] **P3:** Follow the display the cursor hits; fullscreen apps and Spaces; badge counts via the real Dock's accessibility tree (Accessibility permission; private APIs only as fallback); window list in right-click menu with click to focus (Screen Recording for titles); VoiceOver labels and keyboard navigation; do not reveal while dragging a window or holding the mouse button (except file drags headed to the Dock)
- [ ] **Out of scope (do not build):** minimized windows in the Dock; attention bouncing from other apps; two-finger swipe App Expose gesture; assigning apps to Spaces from the menu; the recents section
- [ ] **Enhancements:** more widgets; app groups (D); window previews on hover (on B.5 overlay); profiles
- [ ] **UX cleanup:** Side-dock widget layout (deferred from B.6; see phase below)

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

Status: built, launched with `swift run`, verified with synthetic mouse events, Accessibility reads and logs on all three edges. Waiting on the human hand test before Milestone D.

## Deliverables

- [x] Dock position: bottom, left, or right. `DockEdge` (new `DockEdge.swift`, raw values match the native Dock's `orientation` for F's import), persisted as `edge` in `dock.json`, switchable live from the menu bar's temporary "Position on Screen" submenu until Milestone E
- [x] `EdgeTracker`: edge window and tracking area per edge. Bottom is a full-width row; left and right are full-height columns that stop below the menu bar. Moves live via `setEdge`.
- [x] `DockPanel`: frames per edge. Flush against the screen frame's edge, centered along it inside `visibleFrame` (so side docks stay below the menu bar), slides in from and hides toward that edge. Insets follow the edge (6 on the screen side, 10 on the far side, 12 along). `show`/`hide` state machine unchanged.
- [x] `DockStrip`: `AnyLayout` switches between a horizontal row (bottom) and a vertical column (sides). Items align to the far side; running dots sit between the icon and the screen edge; separators become horizontal lines on side docks; reorder and Finder drops use the dock's axis; tile fitting uses the dock's length (side docks count every item as one tile tall).
- [x] Labels follow orientation: above the icon on the bottom, to the right on a left dock, to the left on a right dock (hit slop along the dock's axis). The overlay's `edge` parameter is the anchor D's folder popover will use.
- [x] Magnification direction: `DockEdge.growthAnchor` (bottom, leading, trailing) so tiles grow away from the screen edge. Magnification itself is not built yet (E/P2); today the anchor drives the reorder "lift" scale.
- [x] Separator drag to resize: drag away from the edge to grow, toward it to shrink, about 1pt per 1pt of cursor travel. Tracked in screen coordinates because the panel moves while it resizes. Clamped to 16 to 128 (native `tilesize` range) and to the largest size that fits on screen. Live while dragging, saved once on release. The dock stays revealed for the whole drag.
- [x] Resize cursor on the separator: SwiftUI `pointerStyle(.rowResize)` / `.columnResize` (macOS 15+), NSCursor fallback below 15 and during the drag. Not verifiable by the agent (see findings).
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

- [ ] (a) The edge strip does not swallow clicks: try resizing a window from its bottom edge and clicking a control at the very bottom of an app. If blocked, shrink the strip to 1 to 2pt or switch to an event-driven global mouse-moved monitor. (Strip is now 1pt; agent test above passed.)
- [ ] (b) Reveal timing logs are unchanged.
- [ ] Resize cursor shows on the separator and during the drag
- [ ] Left and right docks look and feel right (both docks react on the left edge while the native Dock lives there)

## Follow-ups (deferred)

- [ ] Resize cursor doesn't show when Portside isn't frontmost (`BackgroundCursor.swift`, SkyLight `SetsCursorInBackground`)
- [ ] Menu bar item title/accessibility label shows "Bird" instead of "Portside"

## Findings

- Live edge switching first left the strip stale (horizontal panel slid in from the left). `@Published` emits from willSet, before the property holds the new value; moving the panel inside the subscriber forced a synchronous SwiftUI layout that read the old edge, and nothing invalidated it afterwards. Fixed by applying the edge change on the next main loop turn (`.receive(on: DispatchQueue.main)`). Same trap applies to any future `$property` subscriber that touches the panel.
- Synthetic cursor moves past the screen edge (x = -50) are reported unclamped, so the 1pt zone looked like it lost the cursor and the hide timer fired. Real cursors are clamped onto the edge pixel; tests now place the cursor exactly on it.
- The resize cursor could not be verified by the agent: a probe of `NSCursor.currentSystem` reported the arrow even for a frontmost control app that sets the resize cursor, so the probe does not work with synthetic moves. If the cursor does not change for a real mouse, the likely cause is that macOS ignores cursor changes from background apps; the public options are exhausted (`pointerStyle` and `NSCursor.set`), and the known workaround is a private CGS connection property, which belongs in Milestone F behind `dlsym`.
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
