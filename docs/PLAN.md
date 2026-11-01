# Portside: Custom macOS Dock (Architecture Plan)

**Project:** `portside` (personal use, Apple Silicon M4, macOS 27.0.1, Xcode 27.1)
**Goal:** A fast, event-driven dock replacement inspired by Dockset 0.2.7: all the core features (widgets, folders, indicators) with none of the polling-based sluggishness.

> Rename note: the app is **Portside**, NOT "Dockset". Dockset is the third-party app being replaced; it lives in /Applications with bundle id `dev.benja.dockset`. Use a distinct name/bundle id (`com.james.portside`) everywhere so there are no keychain, signing, or UserDefaults collisions with it. If you see "Dockset" anywhere in filenames, types, or bundle paths below or in generated code, it's a mistake: fix it to Portside.

---

## 0. CRITICAL BUILD RULES (read first, these prevent the loops)

1. **Do NOT hand-write an Xcode project.** Never author `project.pbxproj` or a `.xcodeproj` by hand. This is a dead end and causes infinite loops. Use **Swift Package Manager** instead:
   - `swift package init --type executable`
   - A `Package.swift` with an executable target, `platforms: [.macOS("26.0")]` (or current), and resources.
   - All source under `Sources/portside/`.
   - If an `.xcodeproj` is ever strictly needed, generate it with **XcodeGen** from a `project.yml`, never by hand.
2. **Build after every single file-creation batch.** After writing files, run `swift build` and paste the result. Do not write more than ~3 files without compiling. If it doesn't compile, fix it before adding anything new.
3. **If you catch yourself repeating the same sentence or tool call, STOP.** Output "STUCK: <one line on why>" and wait. Do not retry the same action more than twice.
4. **One milestone at a time.** Finish, build, and get sign-off on milestone A before touching B. Do not scaffold later milestones early.
5. **Public APIs by default.** Private APIs (CoreDock, SkyLight, badges) only as small guarded shims (`dlopen`/`dlsym`, graceful fallback so an OS update degrades instead of crashing), each in its own file and listed in the checklist. Currently: `BackgroundCursor.swift`.

---

## 1. REA Findings (reverse-engineered from Dockset 0.2.7)

### Root cause of sluggishness
Dockset detects edge reveal with **repeating polling timers** (~50ms armed / 250ms idle) in `CustomDockWindowController.updateVisibilityTimer`, plus a non-instant window activation. The fix is event-driven detection + a non-activating panel.

### What to reuse vs. rebuild
| Aspect | Dockset | Portside |
|--------|---------|-------|
| Language / UI | Swift + AppKit/CoreGraphics | Same |
| Window type | `NSPanel` (non-activating) | Same, built correctly from scratch |
| Edge reveal | **Polling NSTimer** | **NSTrackingArea** `mouseEntered`/`mouseExited` (zero polling) |
| Native dock hiding | `CoreDockSetAutoHideEnabled` (private) | **autohide-delay trick only** (see §4); pick ONE mechanism |
| Persistence | `DockStore` Codable JSON + UserDefaults | Same pattern |
| Widgets | `WidgetHost` → `CustomWidgetView` | Clean plugin protocol (§5) |
| Folders | `DockSwipeTransition` + `DockItemCollapse` | SwiftUI `withAnimation` |
| Badges | private `NSRunningApplication` APIs | Milestone F only, guarded |

### Private APIs (Milestone F only, behind dlopen/dlsym)
- CoreDock: `CoreDockGetAutoHideEnabled`, `CoreDockSetAutoHideEnabled`, `CoreDockGetOrientationAndPinning`
- SkyLight (Spaces/fullscreen, only if needed): `CGSMainConnectionID`, `CGSCopyManagedDisplaySpaces`, etc.
- NSWorkspace (public): `runningApplications`, `URLForApplicationWithBundleIdentifier:`

---

## 2. Architecture

```
PortsideApp (SwiftUI App, LSUIElement)
  ├─ DockEngine            ← central coordinator (replaces CustomDockWindowController)
  │   ├─ EdgeTracker       ← NEW: NSTrackingArea edge window, event-driven (THE FIX)
  │   ├─ DockPanel         ← non-activating NSPanel (.nonactivatingPanel, right level, canJoinAllSpaces, fullScreenAuxiliary)
  │   └─ DockModel         ← Codable: pinned apps, widgets, folders, settings
  ├─ DockStrip (SwiftUI)   ← renders items, indicators, widgets, folders
  ├─ SettingsWindow
  └─ MenuBarItem
```

### Event flow (the fix)
```
cursor hits edge → NSTrackingArea.mouseEntered (instant)
  → EdgeTracker.reveal() → DockPanel.show() (Core Animation slide, default 150ms)
  → panel immediately clickable (non-activating, no focus steal)
cursor leaves panel → mouseExited → one-shot hide timer (default 300ms, cancel on re-enter)
  → DockPanel.hide()
```
Only timers allowed: the one-shot hide delay, widget refresh (off critical path), running-app cache refresh (off critical path). **No polling in the reveal/hide path.**

---

## 3. File Structure (SPM, no xcodeproj)

```
portside/
├── Package.swift
├── VERSION
├── scripts/
│   ├── gen-version.sh              # writes BuildInfo.swift
│   └── release.sh                  # version bump, commit, tag
├── Sources/portside/
│   ├── PortsideApp.swift           # entry point, menu bar, app delegate
│   ├── DockEngine.swift            # coordinator
│   ├── EdgeTracker.swift           # event-driven edge detection (THE FIX)
│   ├── DockPanel.swift             # non-activating NSPanel
│   ├── DockModel.swift             # Codable model, persistence
│   ├── DockEdge.swift              # bottom/left/right
│   ├── DockStrip.swift             # SwiftUI strip
│   ├── DockItem.swift              # app tile, launch/activate
│   ├── DockHover.swift             # hover targets and labels
│   ├── FileDrop.swift              # file drop state: pin vs open
│   ├── FolderGroup.swift           # group models
│   ├── GroupController.swift       # group open/close state
│   ├── GroupViews.swift            # group tile and grid
│   ├── OverlayPanel.swift          # reusable overlay panel
│   ├── LaunchBounce.swift          # launch bounce animation
│   ├── RunningApps.swift           # NSWorkspace running-app tracking
│   ├── NativeDock.swift            # native Dock hide/restore (prefs backup)
│   ├── NativeDockController.swift  # hide toggle, dialog, alerts
│   ├── SettingsWindow.swift        # settings UI
│   ├── HotKey.swift                # Carbon global hotkey
│   ├── BackgroundCursor.swift      # guarded SkyLight shim (resize cursor)
│   ├── AppIcon.swift               # runtime app icon
│   ├── AppInfo.swift               # name, author, version line
│   ├── BuildInfo.swift             # generated version info
│   ├── UpdateChecker.swift         # update check stub
│   ├── WidgetProtocol.swift        # plugin protocol
│   ├── WidgetHost.swift            # widget lifecycle + refresh
│   └── Widgets/
│       ├── ClockWidget.swift
│       ├── BatteryWidget.swift
│       ├── CalendarWidget.swift
│       ├── WeatherWidget.swift
│       └── SystemStatsWidget.swift
└── README.md
```

---

## 4. Native Dock Hide/Restore (Milestone F): ONE mechanism

Hide the native Dock with the **autohide-delay trick only** (do NOT also toggle CoreDock autohide; redundant and they fight):
- On launch: read and SAVE the user's exact current values (`autohide`, `autohide-delay`, `orientation`, `magnification`, `tilesize`) before changing anything.
- Set a very large `autohide-delay` so the native Dock never reveals.
- On quit/uninstall: restore every saved value exactly as it was. Never assume stock defaults.

**User's current native Dock settings to match in Portside AND restore to on quit:**
position bottom, small size, magnification OFF, indicators ON, recents OFF, minimize animation = Scale Effect, minimize-into-icon ON, title-bar double-click = Minimize, auto-hide ON, animate-opening ON. Capture precise values at runtime with `defaults read com.apple.dock` rather than hardcoding.

Also in Milestone F: import the user's native Dock items by reading (never writing) `persistent-apps` and `persistent-others` from `com.apple.dock`, and offer launch at login via `SMAppService`. On that same import, also read the native Dock's orientation and tilesize and use them as Portside's initial position and icon size.

Use `dlopen`/`dlsym` for any private call so an OS update degrades gracefully (show both docks) instead of crashing.

---

## 5. Widget Plugin Protocol

```swift
protocol DockWidget: Identifiable {
    var id: String { get }
    var name: String { get }
    var icon: Image { get }
    var refreshInterval: TimeInterval { get }
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}
```
- `WidgetCatalog` maps ids → types. `WidgetHost` owns one widget's lifecycle + its own refresh timer (off critical path).
- Start widgets: Clock, Battery, Calendar, Weather, SystemStats. Size small/medium/large.

---

## 6. Folder / Stack Model

```swift
struct FolderGroup: Codable, Identifiable {
    let id: String
    var name: String
    var appIDs: [String]        // bundle ids or paths
    var isExpanded: Bool
}
```
Expand/collapse with SwiftUI `withAnimation`; grid pops above the strip. (Dockset uses a custom `DockSwipeTransition`; we don't need it.)

---

## 7. Build Order (milestones: build and sign-off each before next)

**A: Edge tracker + non-activating panel + slide (foundation).** DONE.
DockEngine, EdgeTracker (NSTrackingArea), DockPanel, minimal DockModel (delays/animation only), timing logs (mouseEntered -> animation start -> interactive). *Test: edge -> reveal ~16ms; leave -> hides after delay; clicking a placeholder works without focus steal.* **This is the whole point: do not move on until the reveal feels instant.**

**B: Pinned apps + running indicators.** DONE.
DockStrip, DockItem, indicators via `NSWorkspace.notificationCenter`, drag-reorder, persistence. *Test: add/remove/reorder, click to launch/activate.*

**C: Widget system + 3+ widgets.** DONE.
WidgetProtocol, WidgetHost, Clock/Battery/Calendar (+Weather/SystemStats). *Test: live data in strip.*

**B.5: Hover labels with a reusable overlay panel.** DONE.
Shared overlay that can show an app name (and later window previews) above the hovered tile without stealing focus. Build it as a reusable panel so later features plug into the same host. *Test: hover an icon, label appears quickly, leave and it dismisses; dock hide delay still respects the overlay.* Follow-up: label must sit 6 to 10pt above the hovered icon's top edge (not flush with the panel), match native Dock label size, stay horizontally centered on the icon, and clamp inside the screen's visible frame.

**B.6: Dock position and separator resize.**
Bottom, left, or right position (persisted; switchable live via a temporary menu bar item until Milestone E). EdgeTracker edge window and tracking area per edge. DockPanel frames from `visibleFrame` (avoid the menu bar), sliding in from and hiding toward the chosen edge. DockStrip horizontal on the bottom and vertical on the sides, with indicators, labels, magnification direction, and the future folder popover anchor following orientation. Native-style separator drag to resize icon size live (resize cursor, clamped, persisted; dock stays revealed during the drag). *Test: switch edges live; strip orientation and labels follow; drag the separator to resize; (a) the edge strip does not swallow clicks (try resizing a window from its bottom edge and clicking a control at the very bottom of an app; if blocked, shrink the strip to 1 to 2pt or switch to an event-driven global mouse-moved monitor); (b) reveal timing logs are unchanged.*

**D: App groups.** DONE.
FolderGroup + expand/collapse (user-defined groups of apps, not filesystem stacks). *Test: click expands/collapses.*

**E: Settings + persistence.** DONE.
SettingsWindow/Model: reveal delay, hide delay, animation duration, icon size, magnification toggle, dock position, widget and group management. Also:
- Optional "Open groups on hover" setting (off by default). When on, hovering a group tile opens its grid after a hover-intent delay (default about 200ms, configurable) so sweeping across the dock does not pop groups open; hovering a different group tile switches the open grid immediately; moving from the tile into the grid keeps it open. Reuses D's close rules. No polling timers: one cancelable one-shot delay, like the hide timer.
- "Name prompt on group creation": when a group is first created, prompt for its name, defaulting to "Group N" so skipping is harmless. Preferred: inline rename (editable name in the open grid or on the tile) where the panel takes key focus only while editing and returns focus to the previously frontmost app afterward. Fallback: a name field in the settings window. Must not break non-activating panel behavior for normal use.
- "Group rename" (deferred from D): rename from the settings window, and from the group tile's context menu using the same inline mechanism.
*Test: live changes apply; with hover-open on, a slow hover opens the group and a fast sweep does not; creating a group offers a name (default Group N); rename from settings and from the tile menu updates the tile and popover title; normal dock clicks still do not steal focus.*

**F: Native Dock hide/restore + launch at login + import.** Hide/restore part DONE (`NativeDock.swift`, `NativeDockController.swift`); .app bundle (`scripts/build-app.sh`) and launch at login (`LaunchAtLogin.swift`) built, hand test pending; native Dock import still open.
NativeDock (autohide-delay trick only, save/restore exact prior values), LaunchAtLogin (`SMAppService`), import of the user's native Dock items by reading `persistent-apps` and `persistent-others` from `com.apple.dock` (never write those keys). On import, also read the native Dock's orientation and tilesize and use them as Portside's initial position and icon size. Private APIs only here, behind `dlopen`/`dlsym`. *Test: quit restores native Dock exactly; re-login auto-launches; imported pins match the native list; initial position and icon size match the native Dock.*

**Live on it (checkpoint).**
Daily-drive Portside with A through F in place. Collect what hurts before starting the native Dock parity backlog (P1 to P3). Do not start P1 until this checkpoint has real notes.

Then: **P1**, **P2**, **P3** (see §8 Native Dock parity).

---

## 8. Native Dock parity

Features that make Portside feel like the real Dock. Ordered by daily-driver impact. Public APIs preferred; Accessibility and private APIs only where noted.

### P1 (daily driver basics)
- Right-click context menu: Keep in Dock, Open at Login, Show in Finder, Hide, Quit, Remove
- Click-and-hold on an icon opens the same menu as right-click
- Right-click on the divider: Turn Hiding On/Off, Magnification, Position on Screen, Dock Settings
- Holding Option turns Quit into Force Quit
- Drag apps in from Finder to pin
- Drag icons out of the strip to remove
- Drop files onto app icons to open them with that app
- Launch bounce animation
- Modifier clicks: Cmd-click reveals in Finder, Option-click hides other apps
- Cmd-Option-D show/hide shortcut

### P2 (polish and stacks)
- Trash with full/empty state and drag-to-trash (note: Full Disk Access prompt)
- Right-click Trash shows Empty Trash
- Filesystem folder stacks (fan/grid/list), separate from app groups in Milestone D
- Section divider
- System glass/translucent material matching the native Dock, with Reduce Transparency and Reduce Motion support
- Spring-loaded drag (hovering a dragged file over an icon brings that app forward)
- Magnification polish

### P3 (multi-display and badges)
- Follow the display the cursor hits
- Fullscreen apps and Spaces behavior
- Badge counts via the real Dock's accessibility tree (needs Accessibility permission; private APIs only as a fallback)
- Window list in the right-click menu with click to focus (titles need Screen Recording permission)
- VoiceOver labels and keyboard navigation
- Do not reveal the dock while the user is dragging a window or holding the mouse button, except for file drags headed to the Dock

### Explicitly out of scope
- Minimized windows in the Dock (user has "minimize into app icon" on)
- Attention bouncing from other apps (needs private APIs, not wanted for now)
- Two-finger swipe App Expose gesture
- Assigning apps to Spaces from the menu
- The recents section

### Windows respect Portside (reserved space)

Goal: with Portside's hiding off, Rectangle Maximize, Window > Fill and tiling stop at the dock's edge, like the native Dock. No public API lets an app shrink `NSScreen.visibleFrame`, so Portside fits windows itself through Accessibility (event-driven, no polling).

- **Phase 0 (done):** measurements, see CHECKLIST "Windows respect Portside: Phase 0".
- **Phase 1 (done):** `DockReservation`: reserved depth per edge on the dock's display (panel thickness minus its transparent far padding, plus a 4pt gap; magnification excluded). Active only when hiding is off. Recomputed on hiding, icon size, edge, and display changes.
- **Phase 2 (done; permission UI moved to Phase 6):** `WindowFitter`: AX permission flow; per-app `AXObserver` (window created, moved, resized), apps from `RunningApps`. Fit only windows flush with the screen edge (within 2pt). Coalesce per window: one cancelable work item about 60ms after the last event, then set size and position together (fixing on the first event loses to Rectangle's follow-up move and to Fill's animation). Skip Portside, fullscreen, non-resizable, and windows that refuse; one retry, then leave the window alone.
- **Phase 3 (done; also releases windows on quit):** toggle reflow, matching macOS: hiding turned off shrinks windows flush with the screen edge; hiding turned on grows windows flush with the reserved edge back to the screen edge.
- **Phase 4 (dropped):** Rectangle gap sync. Rectangle caches `screenEdgeGapBottom` and does not pick up a `defaults write` while running.
- **Phase 5 (done):** Portside's own Settings and overlays place themselves inside the usable frame.
- **Phase 6:** Settings toggle "Keep windows clear of the dock" (`reserveSpace`), docs.

---

## 9. Enhancements

Portside-specific features beyond native Dock parity:
- Widgets (shipped in Milestone C; more kinds later)
- App groups (Milestone D)
- Window previews on hover (builds on the B.5 overlay panel)
- Profiles (saved layouts / pin sets)

---

## 10. UX cleanup

Deferred polish after the milestone and parity backlog. Evaluate options before picking one.

### Side-dock widget layout
**Problem:** On Left and Right, widgets share one column with the apps. With 27 apps and 5 widgets, tiles shrink to about 23pt, widget text is about 4 to 5pt and unreadable, and the dock looks cramped compared to the bottom layout. Fix deferred from Milestone B.6.

**Constraint:** The bottom edge must stay unchanged. Side docks should keep native-style icon sizing from the saved size, with no global shrink-to-fit just to make widgets fit.

**Candidates (evaluate, do not decide yet):**
- (a) Widgets move to a separate second column or segment on the inner side of the dock, with their own sizing.
- (b) Widgets become compact single-line variants on side docks (time, battery %, and so on) at readable text sizes.
- (c) Widgets move into a flyout/popover opened from a single widgets icon, using the overlay panel.
- (d) Overflow handling: apps keep the real icon size and the column scrolls or paginates, instead of shrinking everything.
- (e) Hide widgets entirely on side edges as a per-edge setting.

**Open question:** Which widgets matter most on a side dock (clock, calendar, battery, system stats)?

**Acceptance:** On Left and Right with 27+ apps and 5 widgets, icons match the configured size, widget text is at least 11pt equivalent, nothing is clipped, and the reveal and hide timing is unchanged.

---

## 11. Acceptance Criteria
- Edge → reveal begins within ~16ms (timing logs prove it).
- First click after reveal works immediately, no focus-stealing pre-click.
- 3+ widgets rendering live data; 1+ working folder.
- Settings changes apply live.
- Quit restores native dock to the saved values exactly.
- Reveal/hide path contains zero polling timers (verify in review).
- `swift build` succeeds at every milestone.

---

*Revised for SPM build, Portside naming, single native-dock mechanism, public-API-first, B.5 overlay, B.6 position/resize, P1-P3 parity backlog, and UX cleanup. macOS 27.0.1, Xcode 27.1, Apple Silicon M4.*
