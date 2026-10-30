# Portside: Checklist

Roadmap mirrors `docs/PLAN.md`. Milestones A to C and B.5 are done. B.6, D, E (parts 1 and 2), the launch bounce (all edges and group grids) and reveal on file drag are built and waiting on the hand test.

## Roadmap

- [x] **A:** Edge tracker + non-activating panel + slide
- [x] **B:** Pinned apps + running indicators + drag reorder + persistence
- [x] **C:** Widget protocol and widgets (clock, calendar, weather, system stats, battery)
- [x] **B.5:** Hover labels with a reusable overlay panel (including the label placement fix)
- [x] **B.6:** Dock position (bottom/left/right) and separator resize (built, hand test pending)
- [ ] **D:** App groups (expand/collapse) (built, hand test pending)
- [ ] **E:** Settings window (reveal/hide delay, animation, icon size, magnification, dock position, widgets, groups) applying live (part 1: built, hand test pending); part 2 (built, hand test pending): auto-hide toggle with Cmd+Option+D, Portside as a regular app while Settings is open, inline group naming and rename, open groups on hover
- [ ] **F:** Native Dock hide/restore (autohide-delay trick only), launch at login (`SMAppService`), import `persistent-apps` and `persistent-others` from `com.apple.dock`, plus native orientation and tilesize as Portside's initial position and icon size; bounce on attention request (`requestUserAttention`; no public API exposes another app's request, so it needs private APIs, dlopen/dlsym guarded)
- [ ] **Live on it:** Daily-drive checkpoint with notes before starting P1
- [ ] **P1:** Right-click context menu (Keep in Dock, Open at Login, Show in Finder, Hide, Quit, Remove); click-and-hold opens the same menu; divider right-click (Turn Hiding On/Off, Magnification, Position on Screen, Dock Settings); Option turns Quit into Force Quit; drag apps in from Finder; drag icons out to remove; drop files onto app icons to open them; launch bounce (all three edges plus group grid cells built, hand test pending); reveal when a file is dragged to the edge (built, hand test pending); Cmd-click (Reveal in Finder); Option-click (Hide Others); Cmd-Option-D show/hide
- [ ] **P2:** Trash (full/empty + drag-to-trash, Full Disk Access note); right-click Trash shows Empty Trash; filesystem folder stacks (fan/grid/list, separate from app groups); section divider; system glass/translucent material matching the native Dock (Reduce Transparency and Reduce Motion); spring-loaded drag; magnification polish
- [ ] **P3:** Follow the display the cursor hits; fullscreen apps and Spaces; badge counts via the real Dock's accessibility tree (Accessibility permission; private APIs only as fallback); window list in right-click menu with click to focus (Screen Recording for titles); VoiceOver labels and keyboard navigation; do not reveal while dragging a window or holding the mouse button (except file drags headed to the Dock)
- [ ] **Out of scope (do not build):** minimized windows in the Dock; two-finger swipe App Expose gesture; assigning apps to Spaces from the menu; the recents section
- [ ] **Enhancements:** more widgets; app groups (D); window previews on hover (on B.5 overlay); profiles
- [ ] **UX cleanup:** Side-dock widget layout (deferred from B.6; see phase below)

---

# P1 slice: reveal on file drag to the edge

Status: built and verified with synthetic drags; waiting on James's hand test. Not committed. No new files.

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
- Dropping a non-app file on the strip is accepted (green plus, drag session reports copy) but does nothing: the only drop handler pins `.app` bundles. "Drop files onto app icons to open them" is still not built.

## Known gaps

- Only file drags (`.fileURL`) reveal. Text, links and file promises (for example images dragged out of Photos or Safari) do not.
- No hover labels or group spring-loading while dragging over the strip (mouseMoved does not arrive during a drag).
- A drag over an open group grid is not tracked as a drag; the cursor-inside check still keeps the dock up there.

## Hand test must also check

- [ ] Reveal from a real Finder drag on Bottom, Left and Right, and whether the log shows `edge draggingEntered` or `edge mouseEntered` first
- [ ] Dock stays up while dragging along and over the strip, with pauses
- [ ] Drag away without dropping: hides after the hide delay
- [ ] Clicks right at the screen edge (window resize edges, bottom controls) still work

---

# P1 slice: launch bounce on side edges and in group grids

Status: built and verified with synthetic events; waiting on James's hand test. Not committed. No new files.

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

- [ ] Sideways bounce feels like the bottom one (speed, height)
- [ ] Hover-opened grid: moving off the grid mid-launch closes it and stops the bounce cleanly

---

# P1 slice: launch bounce (bottom edge, pinned tiles)

Status: built and verified with synthetic events; waiting on James's hand test. Not committed. New file: `LaunchBounce.swift`.

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

- [ ] Bounce side by side with the native Dock (for example launch an app from Finder with the native Dock revealed, then from Portside)
- [ ] A slow app (for example Android Studio or Ableton Live) bounces until its window is about to appear, then lands

---

# Milestone E part 2: auto-hide toggle, real app while in Settings, group naming, hover open

Status: built and verified with synthetic events; waiting on James's hand test. Not committed. New files: `HotKey.swift`, `AppIcon.swift` (plus `SettingsWindow.swift` from part 1).

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

- [ ] Cmd+Option+D (with the system shortcut disabled) toggles hiding on all three edges
- [ ] With Settings open, Portside shows in Cmd+Tab and both docks; closing returns you to where you were
- [ ] New Group and Rename feel natural: typing goes into the field, the app you were in keeps focus afterward
- [ ] Hover open delay feels right; hover-opened grids close when you leave them but stay open tile to grid; click-opened grids stay until you dismiss them; sweeping never pops groups open

---

# Milestone E part 1: settings window and model

Status: built and verified with synthetic events; waiting on James's hand test. Not committed.

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

- [ ] "Settings..." from the real menu bar click comes up focused (activation from a real menu click could not be tested here; Bartender owns the status item area)
- [ ] Every setting applies live and survives a relaunch
- [ ] With Settings closed, clicking the dock never takes focus from the frontmost app

## Findings

- SwiftUI sliders and switches here ignore Accessibility value sets and increments (`AXIncrement` returns success, value unchanged); real mouse input works. Worth a look for VoiceOver in P3.
- A grouped `Form`'s rows cannot be drag-reordered with `.onMove`; the enabled widgets use a real `List` inside the section.

---

# Milestone D: app groups

Status: built and verified with synthetic events; waiting on James's hand test. Not committed.

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

- [ ] Create a group from an app's right-click menu, add more apps, open and close it on all three edges
- [ ] Moving from the tile into the grid never hides the dock, and leaving both hides it after the delay
- [ ] Clicking an app in the grid opens it on the first click without a "wake up" click
- [ ] Clicking another app or the desktop closes the grid
- [ ] Grid looks right next to the tile on Bottom, Left and Right (no label overlapping it)

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

Status: built, launched with `swift run`, verified with synthetic mouse events, Accessibility reads and logs on all three edges. Waiting on the human hand test before Milestone D.

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

- [ ] (a) The edge strip does not swallow clicks: try resizing a window from its bottom edge and clicking a control at the very bottom of an app. If blocked, shrink the strip to 1 to 2pt or switch to an event-driven global mouse-moved monitor. (Strip is now 1pt; agent test above passed.)
- [ ] (b) Reveal timing logs are unchanged.
- [ ] Resize cursor shows on the separator and during the drag
- [ ] Left and right docks look and feel right (both docks react on the left edge while the native Dock lives there)

## Follow-ups (deferred)

- [x] Resize cursor doesn't show when Portside isn't frontmost (`BackgroundCursor.swift`, SkyLight `SetsCursorInBackground`). At launch, `CGSMainConnectionID` and `CGSSetConnectionProperty` are resolved via `dlopen`/`dlsym` (falling back to the `SLS` names) and the property is set on our connection; any missing symbol or error logs once and leaves normal behavior. The separator now sets the cursor itself on every hover move (`onContinuousHover`), because `pointerStyle` and cursor rects only apply to the active app. Agent check with another app frontmost: the system cursor reads `resizeLeftRight` on the left and right separators, `resizeUpDown` on the bottom one, and the arrow off them. Log: `SetsCursorInBackground enabled on connection ..., read back: 1`. Deliberately early private API use (requested ahead of F).
- [x] Menu bar item title/accessibility label shows "Bird" instead of "Portside". `MenuBarExtra("Portside", systemImage: "bird")` exposed the symbol name; now a label closure with `accessibilityLabel("Portside")`. Accessibility reads `AXTitle = Portside`.
- [x] Some icons changed style with dock size (Splice white at 32pt and below, dark ghosted glyph from about 36pt up). Cause: `NSWorkspace.icon(forFile:)` returns 32 Icon Services reps (16 to 1024pt), and the system icon style (Dark here, `AppleIconAppearanceTheme = RegularDark`) is applied to Splice's 128px and larger reps but not to the small ones baked into its legacy `app.icns`, so the rep AppKit picked per tile size decided the look. Not an `NSAppearance` variant: forcing aqua or darkAqua changed nothing. The native Dock shows the dark version (screenshot at tilesize 36), so dark is the correct style. Fix: `IconCache` renders each icon once at 128pt times the screen scale into one sRGB bitmap and the tile only scales that bitmap. Verified during a live separator drag from 16 to 38pt (the bottom dock's fit limit): Splice stays dark, Finder, Settings, Notion and Live unchanged. Cache drops an entry when the app's `Info.plist` modification date changes (checked at most every 5s per app, so drags stay off the disk; verified with a test bundle) and drops everything when the screen scale changes (not testable here without a non-Retina display). Rendering 29 icons takes about 350ms at launch, before the edge tracker arms, so the first reveal is unaffected.
- [ ] Hand test: drag a separator from 16 to the largest size and confirm Splice looks the same throughout
- [x] Dock ends clipped when growing it by dragging a separator. Cause: the panel only resized from `invalidateIntrinsicContentSize` on the hosting view, and on this macOS `NSHostingView` never calls it (zero calls logged across drags, app launches and quits). So the window kept the size it got at reveal: shrinking looked fine (content just sat inside a wider panel), growing past the reveal size clipped both ends until the next reveal recomputed the frame. It looked like a first-drag-only bug because later drags usually stayed within that size. Fix: the strip reports its measured size with `onGeometryChange` after its `.fixedSize()`, and `DockPanel` resizes to it immediately (centered on its edge, clamped to the visible frame); during a slide the completion handler catches up. Verified on a fresh launch for each edge by comparing every strip element's Accessibility frame to the panel window at each drag step (bottom 38 to 16 to 38pt, left and right 29 to 22 to 29pt): no clipping. Also verified right after launch on the bottom: app launched and quit, Clock widget removed and re-added, panel resized each time. Reveal timing unchanged (about 2.5ms to animation start).
- [ ] Hand test: launch fresh, immediately drag a separator small to large and back on all three edges, no clipping

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
