# Portside: Checklist

# Milestone C: widget system

Status: built, launched with `swift run`, widgets verified rendering live data (read back through the Accessibility API). Waiting on the human hand test before Milestone D.

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
