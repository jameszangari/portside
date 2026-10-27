# Portside — Custom macOS Dock (Architecture Plan)

**Project:** `portside` (personal use, Apple Silicon M4, macOS 27.0.1, Xcode 27.1)
**Goal:** A fast, event-driven dock replacement inspired by Dockset 0.2.7 — all the core features (widgets, folders, indicators) with none of the polling-based sluggishness.

> Rename note: the app is **Portside**, NOT "Dockset". Dockset is the third-party app being replaced; it lives in /Applications with bundle id `dev.benja.dockset`. Use a distinct name/bundle id (`com.james.portside`) everywhere so there are no keychain, signing, or UserDefaults collisions with it. If you see "Dockset" anywhere in filenames, types, or bundle paths below or in generated code, it's a mistake — fix it to Portside.

---

## 0. CRITICAL BUILD RULES (read first, these prevent the loops)

1. **Do NOT hand-write an Xcode project.** Never author `project.pbxproj` or a `.xcodeproj` by hand. This is a dead end and causes infinite loops. Use **Swift Package Manager** instead:
   - `swift package init --type executable`
   - A `Package.swift` with an executable target, `platforms: [.macOS(.v14)]` (or current), and resources.
   - All source under `Sources/portside/`.
   - If an `.xcodeproj` is ever strictly needed, generate it with **XcodeGen** from a `project.yml`, never by hand.
2. **Build after every single file-creation batch.** After writing files, run `swift build` and paste the result. Do not write more than ~3 files without compiling. If it doesn't compile, fix it before adding anything new.
3. **If you catch yourself repeating the same sentence or tool call, STOP.** Output "STUCK: <one line on why>" and wait. Do not retry the same action more than twice.
4. **One milestone at a time.** Finish, build, and get sign-off on milestone A before touching B. Do not scaffold later milestones early.
5. **Use only public APIs for Milestones A–E.** Private APIs (CoreDock, SkyLight, badge reading) are Milestone F only, isolated behind `dlopen`/`dlsym`.

---

## 1. REA Findings (reverse-engineered from Dockset 0.2.7)

### Root cause of sluggishness
Dockset detects edge reveal with **repeating polling timers** (~50ms armed / 250ms idle) in `CustomDockWindowController.updateVisibilityTimer`, plus a non-instant window activation. The fix is event-driven detection + a non-activating panel.

### What to reuse vs. rebuild
| Aspect | Dockset | Portside |
|--------|---------|-------|
| Language / UI | Swift + AppKit/CoreGraphics | Same |
| Window type | `NSPanel` (non-activating) | Same, built correctly from scratch |
| Edge reveal | **Polling NSTimer** | **NSTrackingArea** `mouseEntered`/`mouseExited` — zero polling |
| Native dock hiding | `CoreDockSetAutoHideEnabled` (private) | **autohide-delay trick only** (see §4) — pick ONE mechanism |
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
├── Sources/portside/
│   ├── PortsideApp.swift              # @main SwiftUI App, LSUIElement via Info.plist
│   ├── DockEngine.swift            # coordinator
│   ├── EdgeTracker.swift           # event-driven edge detection (THE FIX)
│   ├── DockPanel.swift             # non-activating NSPanel
│   ├── DockModel.swift             # Codable model
│   ├── DockStrip.swift             # SwiftUI strip
│   ├── DockItem.swift              # app icon view + launch/activate
│   ├── WidgetProtocol.swift        # plugin protocol
│   ├── WidgetHost.swift            # widget lifecycle + refresh
│   ├── Widgets/
│   │   ├── ClockWidget.swift
│   │   ├── BatteryWidget.swift
│   │   ├── CalendarWidget.swift
│   │   ├── WeatherWidget.swift
│   │   └── SystemStatsWidget.swift
│   ├── FolderGroup.swift           # grouped apps + expand/collapse
│   ├── SettingsWindow.swift
│   ├── SettingsModel.swift
│   ├── NativeDockManager.swift     # Milestone F: save/restore native dock (guarded)
│   ├── BadgeReader.swift           # Milestone F: private badge API (isolated)
│   └── Support/
│       ├── LaunchAtLogin.swift     # SMAppService
│       └── Info.plist              # LSUIElement = true
└── README.md
```

---

## 4. Native Dock Hide/Restore (Milestone F) — ONE mechanism

Hide the native Dock with the **autohide-delay trick only** (do NOT also toggle CoreDock autohide — redundant and they fight):
- On launch: read and SAVE the user's exact current values (`autohide`, `autohide-delay`, `orientation`, `magnification`, `tilesize`) before changing anything.
- Set a very large `autohide-delay` so the native Dock never reveals.
- On quit/uninstall: restore every saved value exactly as it was. Never assume stock defaults.

**User's current native Dock settings to match in Portside AND restore to on quit:**
position bottom, small size, magnification OFF, indicators ON, recents OFF, minimize animation = Scale Effect, minimize-into-icon ON, title-bar double-click = Minimize, auto-hide ON, animate-opening ON. Capture precise values at runtime with `defaults read com.apple.dock` rather than hardcoding.

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

## 7. Build Order (milestones — build & sign-off each before next)

**A — Edge tracker + non-activating panel + slide (foundation).**
DockEngine, EdgeTracker (NSTrackingArea), DockPanel, minimal DockModel (delays/animation only), timing logs (mouseEntered → animation start → interactive). *Test: edge → reveal ~16ms; leave → hides after delay; clicking a placeholder works without focus steal.* **This is the whole point — do not move on until the reveal feels instant.**

**B — Pinned apps + running indicators.**
DockStrip, DockItem, indicators via `NSWorkspace.notificationCenter`, drag-reorder, persistence. *Test: add/remove/reorder, click to launch/activate.*

**C — Widget system + 3+ widgets.** WidgetProtocol, WidgetHost, Clock/Battery/Calendar (+Weather/SystemStats). *Test: live data in strip.*

**D — Grouped folders.** FolderGroup + expand/collapse. *Test: click expands/collapses.*

**E — Settings + persistence.** SettingsWindow/Model: reveal delay, hide delay, animation duration, icon size, magnification toggle, widget & folder management. *Test: live changes apply.*

**F — Native dock hide/restore + launch at login (private APIs here only).** NativeDockManager (guarded), LaunchAtLogin (SMAppService). *Test: quit restores native dock exactly; re-login auto-launches.*

---

## 8. Acceptance Criteria
- Edge → reveal begins within ~16ms (timing logs prove it).
- First click after reveal works immediately, no focus-stealing pre-click.
- 3+ widgets rendering live data; 1+ working folder.
- Settings changes apply live.
- Quit restores native dock to the saved values exactly.
- Reveal/hide path contains zero polling timers (verify in review).
- `swift build` succeeds at every milestone.

---

*Revised for SPM build, Portside naming, single native-dock mechanism, public-API-first. macOS 27.0.1, Xcode 27.1, Apple Silicon M4.*
