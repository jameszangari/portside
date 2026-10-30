# Portside

A fast, event-driven dock replacement for macOS, written in Swift (SwiftUI and AppKit) and built with SwiftPM.

Portside is a personal project for macOS on Apple Silicon. It builds into a locally signed .app but is not notarized or meant for general distribution.

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
- Drop files on an app tile to open them in that app, like the native Dock. Only tiles whose app can open the files highlight and accept the drop (Finder takes folders). A not-running pinned app launches with the bounce.
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
- Spring-loading: resting a file drag on a group tile for about 600ms opens its grid. Drop on a member that can open the file (it highlights) to open it there. The grid closes when the drag leaves both the tile and the grid.

**Settings window**
- General, Widgets, and Groups tabs. Changes apply live.
- Header with the app icon, version, and author. Unreleased or modified builds show the short git hash. The window fits each tab and remembers its position.
- Drag widget rows to reorder them.

**Native Dock**
- "Hide the macOS Dock" (Settings > General): keeps the native Dock from ever appearing while Portside runs, using the autohide-delay trick. Its exact prior settings are saved first and restored when you turn this off, quit, or stop Portside with Ctrl+C or `kill`. After a crash or `kill -9`, the next launch restores them first.
- First launch (no `dock.json`): pinned apps, position, and icon size are taken from the native Dock (Finder first). If a Hide-the-Dock backup exists, position and size come from it instead of the live values.
- "Import from macOS Dock..." (Settings > General > Import): a confirmation sheet shows what was found. Add missing apps (appended, nothing reordered) or replace the apps (groups and widgets stay), and optionally take the native position and icon size. Apps no longer on disk, spacers, and folder/file tiles are skipped. Your dock is copied to `dock.json.before-import` first, and "Undo last import" restores it. Read only: nothing in `com.apple.dock` is written.
- "Restore macOS Dock" in the menu bar item, and `portside --restore-dock` (restores from the backup and exits, no UI).

**App bundle and startup**
- `scripts/build-app.sh` builds a signed `build/Portside.app` with its own icon, version from `VERSION`, and the Calendar usage strings. `--install` copies it to `~/Applications`.
- "Open Portside at login" (Settings > General > Startup) through `SMAppService`. macOS is the source of truth; the toggle shows its real status, links to Login Items when approval is needed, and is disabled under `swift run`.

## Planned

From `docs/CHECKLIST.md` and `docs/PLAN.md`:
- Milestone F, what is left: importing the native Dock's folders and files (`persistent-others`), once folder stacks exist.
- Magnification (the stored setting exists, no UI yet).
- Update checker: compare AppInfo.version with the latest GitHub release tag (vX.Y.Z), show 'up to date' or a link to the release. The Check for Updates button is a placeholder until then.
- Native Dock parity: click-and-hold menu, drag icons out to remove, modifier clicks, Trash, folder stacks.
- Multi-display, fullscreen and Spaces behavior, badges.
- Better widget layout on side docks.

## Requirements and build

- macOS 14 or later (`Package.swift` targets `.macOS(.v14)`). Developed on macOS 27 with Xcode 27 on an M4 Max.
- Swift toolchain with `swift-tools-version` 5.10 support (Xcode command line tools are enough).

```
swift build
swift run portside
```

Restore the native Dock from the backup without starting the app:

```
swift run portside --restore-dock
```

View logs while it runs:

```
log stream --level info --predicate 'subsystem == "com.james.portside"'
```

## Build the app

```
scripts/build-app.sh            # builds build/Portside.app
scripts/build-app.sh --install  # also copies it to ~/Applications/Portside.app
open build/Portside.app
```

- Runs `swift build -c release`, then assembles `Contents/MacOS/portside`, `Contents/Info.plist` (from the repo's `Info.plist` plus bundle keys and the version from `VERSION`), and `Contents/Resources/AppIcon.icns` (drawn by the app via the hidden `portside --export-icon <path.png>` flag). No network.
- `--install` copies to `~/Applications/Portside.app`, never `/Applications`. It refuses while that copy is running; quit Portside first. Without the flag nothing is installed.
- Signing is ad-hoc by default. Ad-hoc signatures change on every build, so macOS may ask for Calendar permission again after each rebuild, and may treat each build as a new login item. To avoid that, create a self-signed code signing certificate in Keychain Access (Certificate Assistant > Create a Certificate, type Code Signing) and build with `SIGN_IDENTITY="Your Cert Name" scripts/build-app.sh`.
- Turn on "Open Portside at login" from the copy you keep (normally `~/Applications/Portside.app`). macOS remembers the path it was registered from.
- `swift build` and `swift run portside` are unchanged and still work for development.

Restore the native Dock from the bundle's binary:

```
build/Portside.app/Contents/MacOS/portside --restore-dock
~/Applications/Portside.app/Contents/MacOS/portside --restore-dock
```

## Versioning and releases

- `VERSION` at the repo root is the single source of truth. Edit the version only there (or let the release script do it).
- `scripts/gen-version.sh` writes `Sources/portside/BuildInfo.swift` (generated, committed) with the version, short git hash, and dirty flag. Run it to refresh the hash before a build.
- Cut a release with `scripts/release.sh patch|minor|major`. It is a dry run by default; add `--apply` to bump `VERSION`, make one "Release vX.Y.Z" commit, and create an annotated tag. It refuses on a dirty tree and never pushes; it prints the `git push` and `gh release create` commands to run.
- Tags use the `vX.Y.Z` format. The future update checker compares the latest release tag against this version.

## How it works

- `EdgeTracker` owns a thin, near-invisible window along the chosen screen edge. An `NSTrackingArea` on it reports `mouseEntered` and `mouseExited`, so reveal starts the moment the window server delivers the event. It is also a drag destination for files, since tracking areas are unreliable during another app's drag.
- `DockPanel` is a non-activating `NSPanel` that slides in from the edge. It has its own tracking area so hovering it cancels the hide timer.
- `DockEngine` coordinates both. The only timers are the one-shot hide delay, widget refresh, and group hover/close/spring-load delays, none of which poll.
- `OverlayPanel` is a second non-activating panel used for hover labels and group grids. It sits outside the strip so its content can extend past the strip's bounds.

## Where data lives

Settings and the dock layout are saved as JSON at:

```
~/Library/Application Support/com.james.portside/dock.json
```

Before each "Import from macOS Dock", the previous layout is copied to `dock.json.before-import` in the same folder (overwritten by the next import, deleted by "Undo last import").

While "Hide the macOS Dock" is on, the native Dock's prior settings are backed up at:

```
~/Library/Application Support/com.james.portside/native-dock-backup.json
```

It is deleted after a verified restore. If it exists when Portside starts, Portside restores from it first.

The Settings window's position is kept in the app's defaults (`defaults read com.james.portside`, key `NSWindow Frame PortsideSettings`).

The Settings window controls:
- Position, auto-hide, icon size, "Animate opening applications"
- Reveal delay, hide delay, animation duration (with reset to defaults)
- Widgets: on/off and order
- Groups: rename, ungroup, delete, open on hover, open delay, close grace
- Hide the macOS Dock (`hideNativeDock`, plus `nativeDockExplained` once the first-time dialog was confirmed)
- Import from macOS Dock and Undo last import (nothing new stored in `dock.json`; imported apps, position, and icon size land in `entries`, `edge`, and `iconSize`)
- Open Portside at login: not stored by Portside. macOS keeps it (System Settings > General > Login Items).

The built app lives at `build/Portside.app` (ignored by git), and at `~/Applications/Portside.app` after `scripts/build-app.sh --install`.

## Notes

- The separator's resize cursor needs a private SkyLight call, because macOS ignores cursor changes from a background app. `BackgroundCursor.swift` loads it with `dlopen`/`dlsym`. If the framework or symbols are missing, the cursor feature is disabled and nothing crashes. No other private APIs are used.
- The native Dock is modified only while "Hide the macOS Dock" is on: Portside writes `autohide` and `autohide-delay` in `com.apple.dock` (public CFPreferences, then `killall Dock`) and restores every saved value on the way out. With the option off, no `com.apple.dock` settings are touched and both docks can react to the same edge. Portside is separate from the third-party Dockset app.
- The system's Cmd+Option+D shortcut toggles the native Dock's auto-hide. While Portside hides the native Dock, it makes the native Dock appear until restore.
- Opening Settings turns Portside into a regular app (visible in Cmd+Tab and the native Dock) until the window closes.
- Cmd+Option+D may conflict with the system's own "Turn Dock hiding on/off" shortcut. Disable that one in System Settings to use Portside's.

## Project layout

```
Sources/portside/
  PortsideApp.swift         Entry point (--restore-dock, --export-icon, crash recovery, signals), menu bar, app delegate
  DockEngine.swift          Coordinator for tracker, panel, hide timer, and model
  EdgeTracker.swift         Edge window with NSTrackingArea (event-driven reveal)
  DockPanel.swift           Non-activating NSPanel, slide animation, panel tracking
  DockModel.swift           Codable settings and entries, persistence to dock.json
  DockEdge.swift            Bottom/Left/Right enum and screen selection
  DockStrip.swift           SwiftUI strip: tiles, widgets, separator, reorder, drops
  DockItem.swift            App tile, icon cache, launch/activate, context menu
  FileDrop.swift            Per-drag state for file drops: pin vs open, can-open checks
  DockHover.swift           Hover target frames and label placement
  FolderGroup.swift         Group and entry models
  GroupController.swift     Group open/close state and every close path
  GroupViews.swift          Group tile and expanded grid views
  OverlayPanel.swift        Reusable non-activating overlay panel
  LaunchBounce.swift        Native-style launch bounce animation
  RunningApps.swift         Running app tracking via NSWorkspace notifications
  NativeDock.swift          Native Dock hide/restore: prefs backup, writes, Dock restart, verify
  NativeDockController.swift  "Hide the macOS Dock" toggle, first-time dialog, alerts
  NativeDockImport.swift    Reads the native Dock (apps, position, size) and the import sheet
  LaunchAtLogin.swift       "Open Portside at login" via SMAppService.mainApp
  SettingsWindow.swift      Settings window: header, tabs (General, Widgets, Groups)
  HotKey.swift              Global hotkey through Carbon RegisterEventHotKey
  BackgroundCursor.swift    Guarded SkyLight call for the resize cursor
  AppIcon.swift             Runtime-drawn app icon, PNG export for the .icns
  AppInfo.swift             App name, author, version line, and repo URL
  BuildInfo.swift           Generated by scripts/gen-version.sh: version, git hash, dirty flag
  UpdateChecker.swift       Update check (stub until GitHub releases are wired up)
  WidgetProtocol.swift      Widget plugin protocol and sizes
  WidgetHost.swift          Widget lifecycle and refresh timer
  Widgets/
    ClockWidget.swift       Time and date
    BatteryWidget.swift     Battery percent and charging state
    CalendarWidget.swift    Date and next event
    WeatherWidget.swift     Temperature and conditions (Open-Meteo)
    SystemStatsWidget.swift CPU and memory usage
  Support/                  Resources folder (empty placeholder)
scripts/
  gen-version.sh            Writes BuildInfo.swift from VERSION and git
  release.sh                Bumps VERSION, commits, and tags a release
  build-app.sh              Builds and signs build/Portside.app (--install to ~/Applications)
```
