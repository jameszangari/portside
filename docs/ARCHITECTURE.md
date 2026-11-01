# Architecture

How Portside is put together. See also [PLAN.md](PLAN.md) for the original milestones.

## How it works

- `EdgeTracker` owns a thin, near-invisible window along the chosen screen edge. An `NSTrackingArea` on it reports `mouseEntered` and `mouseExited`, so reveal starts the moment the window server delivers the event. It is also a drag destination for files, since tracking areas are unreliable during another app's drag.
- `DockPanel` is a non-activating `NSPanel` that slides in from the edge. It has its own tracking area so hovering it cancels the hide timer.
- `DockEngine` coordinates both. The only timers are the one-shot hide delay, widget refresh, and group hover/close/spring-load delays, none of which poll.
- `OverlayPanel` is a second non-activating panel used for hover labels, group grids, and the drag-out "Remove" label. It sits outside the strip so its content can extend past the strip's bounds.

## Notes

- The separator's resize cursor needs a private SkyLight call, because macOS ignores cursor changes from a background app. `BackgroundCursor.swift` loads it with `dlopen`/`dlsym`. If the framework or symbols are missing, the cursor feature is disabled and nothing crashes.
- Notification badges read each app's badge from LaunchServices (`_LSASNCreateWithPid`, `_LSCopyApplicationInformationItem`), the store the Dock itself draws from. `LaunchServicesBadges.swift` loads them with `dlopen`/`dlsym`; if they are missing, badges turn off and Settings says so. No other private APIs are used.
- The native Dock is modified only while "Hide the macOS Dock" is on: Portside writes `autohide` and `autohide-delay` in `com.apple.dock` (public CFPreferences, then `killall Dock`) and restores every saved value on the way out. With the option off, no `com.apple.dock` settings are touched and both docks can react to the same edge. Portside is separate from the third-party Dockset app.
- The system's Cmd+Option+D shortcut toggles the native Dock's auto-hide. While Portside hides the native Dock, it makes the native Dock appear until restore.
- Opening Settings turns Portside into a regular app (visible in Cmd+Tab and the native Dock) until the window closes. While Settings is the key window, auto-hide is suppressed so the strip stays visible; the saved preference is unchanged.
- Cmd+Option+D may conflict with the system's own "Turn Dock hiding on/off" shortcut. Disable that one in System Settings to use Portside's.

## Project layout

```
Sources/portside/
  PortsideApp.swift         Entry point (--restore-dock, --export-icon, crash recovery, signals), menu bar, About panel, app delegate
  DockEngine.swift          Coordinator for tracker, panel, hide timer, and model
  EdgeTracker.swift         Per-screen edge windows with NSTrackingArea (event-driven reveal)
  DockPanel.swift           Non-activating NSPanel, slide animation, panel tracking, multi-display relocate
  DockModel.swift           Codable settings and entries, persistence to dock.json
  DockEdge.swift            Bottom/Left/Right enum and DockScreen (active display)
  DockStrip.swift           SwiftUI strip: tiles, widgets, separator, reorder, drops
  DockItem.swift            App tile, icon cache, launch/activate
  DockBadges.swift          Notification badges: visible-only reads and the badge chip
  LaunchServicesBadges.swift Private LaunchServices badge reader (dlopen/dlsym guarded)
  TileActions.swift         Modifier clicks (Cmd, Option) and the AppKit right-click menu with Force Quit
  AppLoginItem.swift        Open at Login checkbox: SMAppService for Portside, System Events for other apps
  FileDrop.swift            Per-drag state for pin apps/folders, open, deposit, and Trash drops
  AppSpringLoad.swift       File drag resting on a running app brings it forward
  Trash.swift               Native Trash tile, directory watcher, Finder actions
  TrashDrop.swift           Confirm when a dock tile is dropped on Trash
  FolderStack.swift         Folder stack model and FSEvents contents
  StackController.swift     Stack open/close, drag-open, deposit into folder
  StackViews.swift          Stack tile and grid popover
  DragOut.swift             Drag an item out to remove it: "Remove" label, poof, Escape
  DockHover.swift           Hover target frames and label placement
  Magnifier.swift           Dock magnification: per-tile scale and shift from the cursor, shelf widening, panel room
  FolderGroup.swift         Group, spacer, and entry models
  GroupController.swift     Group open/close state and every close path
  GroupRemoval.swift        "Remove group?" confirmation alert and focus hand-back
  GroupViews.swift          Group tile and expanded grid views
  OverlayPanel.swift        Reusable non-activating overlay panel
  LaunchBounce.swift        Native-style launch bounce animation
  RunningApps.swift         Running app tracking via NSWorkspace notifications
  NativeDock.swift          Native Dock hide/restore: prefs backup, writes, Dock restart, verify
  NativeDockController.swift  "Hide the macOS Dock" toggle, first-time dialog, alerts
  NativeDockImport.swift    Reads the native Dock (apps, position, size) and the import sheet
  LaunchAtLogin.swift       "Open Portside at login" via SMAppService.mainApp
  SettingsWindow.swift      Settings window: sidebar and panes (General, Appearance, Widgets, Groups, System)
  DockAppearance.swift      Icon style and dock background options, background modifier, icon style observer
  HotKey.swift              Global hotkeys (Carbon RegisterEventHotKey), chord model, Settings shortcut recorder
  BackgroundCursor.swift    Guarded SkyLight call for the resize cursor
  AppIcon.swift             App icon: system-rendered in Portside.app, bundled PNGs under swift run, PNG export
  BrandAssets.swift         Safe resource bundle lookup (no Bundle.module), menu bar template icon
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
    SystemStatsWidget.swift Combined concentric rings and separate CPU / Memory gauges
  Support/                  Bundled resources: AppIcon-<px>.png (actool's flat render of AppIcon.icon) and MenuBarIcon-<px>.png
Sources/AppLoginItemList/   C helper: read session Open at Login list (LSSharedFileList)
scripts/
  swift-env.sh              Shared SPM env (disables Explicitly Built Modules by default)
  gen-version.sh            Writes BuildInfo.swift from VERSION and git
  release.sh                Bumps VERSION, commits, tags, and notarizes Portside-X.Y.Z.dmg
  publish-release.sh        Notarizes if needed, pushes the tag, GitHub release with the .dmg
  setup-notary.sh           Stores notarytool keychain profile (portside-notary)
  build-app.sh              Builds and signs build/Portside.app (--install, --package, --notarize)
  make-dmg.sh               Builds the drag-to-Applications DMG (layout, background, volume icon)
  DMGBackground.swift       Renders the DMG background (arrow + drop zone) at 1x and 2x
  setup-signing.sh          Creates or reuses the stable local code signing identity
  ensure-codesign-key-access.sh  Native Okay consent + Touch ID, then silent key unlock
  SigningConsent.swift      Stock NSAlert + LocalAuthentication for build consent
  check-tile-input.swift    Synthetic Accessibility check: clicks, hold menu, label centering
Portside.entitlements       Hardened Runtime entitlements for Developer ID / notarized builds
design/brand/               Approved Portside sail icon, wordmarks, menu bar assets, and tokens; see its README
```
