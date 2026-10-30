# Portside

A fast, event-driven dock replacement for macOS, written in Swift (SwiftUI and AppKit) and built with SwiftPM.

Portside is a personal project for macOS on Apple Silicon. It is not packaged, signed, or meant for general distribution.

## Features

**Reveal and hide**
- Edge reveal driven by an `NSTrackingArea` on a thin edge window. No polling timers in the reveal/hide path.
- Non-activating panel: the first click works and the frontmost app keeps focus.
- Animated slide with a configurable duration, an instant option, and Reduce Motion support.
- Cancelable one-shot hide delay, canceled on re-entering the edge zone, the panel, or an open group grid.
- Dragging a file to the edge reveals the dock, and it stays up while the drag is over it. Hides with the normal delay after the drop or when the drag leaves.
- Timing logs for mouseEntered (or draggingEntered), animation start, and panel-interactive.
- Auto-hide toggle (menu bar item, separator right-click menu, Settings, or Cmd+Option+D). With hiding off, the dock stays revealed.

**Apps**
- Pinned apps with running indicators, updated from `NSWorkspace` notifications.
- Drag to reorder.
- Drag an .app from Finder onto the strip to pin it.
- Running apps that are not pinned show after the pinned section.
- Right-click menu: Keep in Dock or Remove from Dock, Add to Group, Show in Finder, Quit.
- Native-style launch bounce for pinned apps on any edge (sideways on the side docks) and for apps opened from a group grid (optional, off under Reduce Motion).
- Hover labels in a reusable non-activating overlay panel.
- "Add App to Dock..." from the menu bar item.

**Layout**
- Bottom, Left, or Right position, switchable live.
- Drag the separator to resize icons live (clamped to what fits, persisted).

**Widgets**
- Clock, Battery, Calendar, Weather, System Stats.
- Enable, disable, and reorder in Settings, or toggle from the menu bar item.

**Groups**
- User-defined groups of apps shown as one tile that opens a grid.
- Inline naming on creation, rename, ungroup, and remove-from-group from context menus.
- Optional open on hover, with configurable open delay and close grace.

**Settings window**
- General, Widgets, and Groups tabs. Changes apply live.

## Planned

From `docs/CHECKLIST.md` and `docs/PLAN.md`:
- Milestone F: hide the native Dock (autohide-delay trick only) with exact save and restore, launch at login, and import of the native Dock's items, position, and icon size.
- A real `.app` bundle.
- Magnification (the setting exists but is disabled).
- Native Dock parity: click-and-hold menu, drag icons out to remove, drop files onto icons, modifier clicks, Trash, folder stacks.
- Multi-display, fullscreen and Spaces behavior, badges.
- Better widget layout on side docks.

## Requirements and build

- macOS 14 or later (`Package.swift` targets `.macOS(.v14)`). Developed on macOS 27 with Xcode 27 on an M4 Max.
- Swift toolchain with `swift-tools-version` 5.10 support (Xcode command line tools are enough).

```
swift build
swift run portside
```

View logs while it runs:

```
log stream --level info --predicate 'subsystem == "com.james.portside"'
```

## How it works

- `EdgeTracker` owns a thin, near-invisible window along the chosen screen edge. An `NSTrackingArea` on it reports `mouseEntered` and `mouseExited`, so reveal starts the moment the window server delivers the event. It is also a drag destination for files, since tracking areas are unreliable during another app's drag.
- `DockPanel` is a non-activating `NSPanel` that slides in from the edge. It has its own tracking area so hovering it cancels the hide timer.
- `DockEngine` coordinates both. The only timers are the one-shot hide delay, widget refresh, and group hover/close delays, none of which poll.
- `OverlayPanel` is a second non-activating panel used for hover labels and group grids. It sits outside the strip so its content can extend past the strip's bounds.

## Where data lives

Settings and the dock layout are saved as JSON at:

```
~/Library/Application Support/com.james.portside/dock.json
```

The Settings window controls:
- Position, auto-hide, icon size, "Animate opening applications"
- Reveal delay, hide delay, animation duration (with reset to defaults)
- Widgets: on/off and order
- Groups: rename, ungroup, delete, open on hover, open delay, close grace

## Notes

- The separator's resize cursor needs a private SkyLight call, because macOS ignores cursor changes from a background app. `BackgroundCursor.swift` loads it with `dlopen`/`dlsym`. If the framework or symbols are missing, the cursor feature is disabled and nothing crashes. No other private APIs are used.
- The native Dock is not modified yet, and no `com.apple.dock` settings are touched. Until Milestone F, both docks can react to the same edge. Portside is separate from the third-party Dockset app.
- Opening Settings turns Portside into a regular app (visible in Cmd+Tab and the native Dock) until the window closes.
- Cmd+Option+D may conflict with the system's own "Turn Dock hiding on/off" shortcut. Disable that one in System Settings to use Portside's.

## Project layout

```
Sources/portside/
  PortsideApp.swift         SwiftUI entry point, menu bar item, app delegate
  DockEngine.swift          Coordinator for tracker, panel, hide timer, and model
  EdgeTracker.swift         Edge window with NSTrackingArea (event-driven reveal)
  DockPanel.swift           Non-activating NSPanel, slide animation, panel tracking
  DockModel.swift           Codable settings and entries, persistence to dock.json
  DockEdge.swift            Bottom/Left/Right enum and screen selection
  DockStrip.swift           SwiftUI strip: tiles, widgets, separator, reorder, drops
  DockItem.swift            App tile, icon cache, launch/activate, context menu
  DockHover.swift           Hover target frames and label placement
  FolderGroup.swift         Group and entry models
  GroupController.swift     Group open/close state and every close path
  GroupViews.swift          Group tile and expanded grid views
  OverlayPanel.swift        Reusable non-activating overlay panel
  LaunchBounce.swift        Native-style launch bounce animation
  RunningApps.swift         Running app tracking via NSWorkspace notifications
  SettingsWindow.swift      Settings window (General, Widgets, Groups)
  HotKey.swift              Global hotkey through Carbon RegisterEventHotKey
  BackgroundCursor.swift    Guarded SkyLight call for the resize cursor
  AppIcon.swift             Runtime-drawn app icon
  WidgetProtocol.swift      Widget plugin protocol and sizes
  WidgetHost.swift          Widget lifecycle and refresh timer
  Widgets/
    ClockWidget.swift       Time and date
    BatteryWidget.swift     Battery percent and charging state
    CalendarWidget.swift    Date and next event
    WeatherWidget.swift     Temperature and conditions (Open-Meteo)
    SystemStatsWidget.swift CPU and memory usage
  Support/                  Resources folder (empty placeholder)
```
