# Architecture

How Portside is put together. See also [PLAN.md](PLAN.md) for the original milestones.

## How it works

- `EdgeTracker` owns a thin, near-invisible window along the chosen screen edge. An `NSTrackingArea` on it reports `mouseEntered` and `mouseExited`, so reveal starts the moment the window server delivers the event. It is also a drag destination for files, since tracking areas are unreliable during another app's drag.
- `DockPanel` is a non-activating `NSPanel` that slides in from the edge. It has its own tracking area so hovering it cancels the hide timer.
- `DockEngine` coordinates both. The only timers are the one-shot hide delay, widget refresh, and group hover/close/spring-load delays, none of which poll.
- `OverlayPanel` is a second non-activating panel used for hover labels, group grids, and the drag-out "Remove" label. It sits outside the strip so its content can extend past the strip's bounds.

## Notes

- The separator's resize cursor needs a private SkyLight call, because macOS ignores cursor changes from a background app. `BackgroundCursor.swift` loads it with `dlopen`/`dlsym`. If the framework or symbols are missing, the cursor feature is disabled and nothing crashes.
- Notification badges read each app's badge from LaunchServices (`_LSASNCreateWithPid`, `_LSCopyApplicationInformationItem`), the store the Dock itself draws from. `LaunchServicesBadges.swift` loads them with `dlopen`/`dlsym`; if they are missing, badges turn off and Settings says so.
- Now Playing does not use MediaRemote: on macOS 27 `MRMediaRemoteGetNowPlayingInfo` returns an empty dictionary to Portside (non-Apple clients are refused since macOS 15.4). It reads Spotify and Music over AppleScript instead, triggered by their distributed notifications. `AEDeterminePermissionToAutomateTarget` is avoided there because it can block with no timeout while consent is undecided.
- AI Usage reads Claude limits from `https://api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`), an undocumented endpoint Claude Code itself uses, with the OAuth token Claude Code keeps in the login keychain (`Claude Code-credentials`, read through `/usr/bin/security` so no keychain prompt). The token is never logged and never refreshed by Portside. Any failure shows a note instead of meters.
- The see-through lens in Liquid Glass sets the private `_variant` of `NSGlassEffectView` to 19, the see-through lens (no blur, refraction at the rim). The public `.clear` glass still blurs heavily on macOS 27. `SeeThroughGlass.swift` checks the selectors at runtime and reads the value back; if anything is off, glass falls back to the public version. Variant numbers were measured on macOS 27.0.1 and may change in an OS update (worst case is a wrong look, not a crash). The lens bends its rim through chromatic aberration only, which fringes dark edges behind it with color, so `removeDispersion` moves those values to the plain refraction keys of its private `glassForeground` filter. It checks `inputKeys` first and runs after each layout, since the lens rewrites the filter when resized; if the keys change, the fringe returns. Match macOS also uses private APIs, see below.
- Match macOS rebuilds the native Dock's glass in `NativeDockGlass.swift`, because the Dock's `GlassMaterialProvider.Configuration.dock` (private DesignLibrary) is out of reach and no `NSGlassEffectView` variant matches it. It stacks a private `CABackdropLayer` with `CAFilter` blur and color filters, the see-through lens, a fixed gray, and a rim, all fitted to captures of the real Dock in dark mode on macOS 27.0.1. The classes are looked up at runtime; if any are missing, Match macOS and Custom fall back to the public glass. Match macOS also does in light mode. The blur follows the global `NSGlassTintAmount`, read through KVO.
- The group icon picker lists SF Symbols from the plists in `/System/Library/CoreServices/CoreGlyphs.bundle` (`symbol_order.plist`, `symbol_search.plist`), since there is no public API that lists symbols. They are undocumented files, not an API. If they are missing or change shape, `SymbolCatalog` falls back to a built-in list of suggested symbols, and a saved symbol that no longer exists draws as a folder.
- Activity icons use public APIs only. Mic and audio output come from CoreAudio process objects (`kAudioProcessPropertyIsRunningInput` / `Output`), the camera from CoreMediaIO (`kCMIODevicePropertyDeviceIsRunningSomewhere`), all as property listeners. A process is matched to its dock app by pid, then parent pid (Electron and browser helpers), then bundle id prefix. macOS has no public per-app camera owner, so a running camera is credited to apps also using the microphone. Working samples CPU of the app plus child processes every 2s (`sysctl` + `proc_pid_rusage`) only while a watched app runs; on at 8% of one core for two samples, off under 4% for two. That timer is outside the reveal/hide path.
- AI Usage asks first: `UsageConsent` shows a dialog before Portside reads `Claude Code-credentials` or contacts `api.anthropic.com`, and `usageClaudeConsent` in dock.json holds the answer. The Codex meter only reads local session logs and needs no prompt. The token stays in memory for one request.
- AI Usage for Copilot also asks first (`usageCopilotConsent`). ACP has no quota method (`copilot --acp` answers `account.getQuota` with "Method not found"), so Portside runs `copilot --headless --no-auto-update --log-level none --log-dir <temp> --stdio` for one `account.getQuota` call over `Content-Length` framed JSON-RPC, 10 second limit, using the CLI's own sign-in. The temp log dir keeps `~/.copilot/logs` from gaining a file per refresh. If the CLI is missing, signed out or fails, `gh auth token` goes to `https://api.github.com/copilot_internal/user`, an undocumented endpoint. The token stays in memory for one request and is never logged. The CLI can report a reset date of "now", so past dates are dropped rather than read as an expired window.
- Agent hooks write only to `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.codex/config.toml` (and one `.portside.bak` beside each), and `agent-hook.sh` plus `agents/` in Application Support. The hook command path is shell-quoted. The hook script stores the agent's stdin JSON as data inside a JSON file via `printf` arguments, never as code (tested with `$(...)` and backtick payloads). Agent tty names come from the kernel, not from agent text, before they reach AppleScript.
- Updater hardening (`UpdateChecker.swift`): the DMG URL must be `https` on `github.com` or `*.githubusercontent.com` (no userinfo, port 443 only), checked before the request and on every redirect. The work folder and mount point are created `0700`. Verification refuses a wrong bundle id, a wrong version, a version older than the running one, or a signature outside Developer ID team `WNZ8H4UHQE`, all before the installed app is touched. The swap helper re-runs the same signature check on the staged app immediately before the first rename. `swap.sh` single-quotes every path; this was tested against paths holding spaces, quotes, `$`, backticks, `;`, and newlines.
- The native Dock is modified only while "Hide the macOS Dock" is on: Portside writes `autohide` and `autohide-delay` in `com.apple.dock` (public CFPreferences, then `killall Dock`) and restores every saved value on the way out. With the option off, no `com.apple.dock` settings are touched and both docks can react to the same edge.
- The system's Cmd+Option+D shortcut toggles the native Dock's auto-hide. While Portside hides the native Dock, it makes the native Dock appear until restore.
- Opening Settings turns Portside into a regular app (visible in Cmd+Tab and the native Dock) until the window closes. While Settings is the key window, auto-hide is suppressed so the strip stays visible; the saved preference is unchanged.
- Cmd+Option+D may conflict with the system's own "Turn Dock hiding on/off" shortcut. Disable that one in System Settings to use Portside's.
- Reserved space uses public Accessibility only (`AXObserver`, `AXUIElementSetAttributeValue`), active while hiding is off and Accessibility is granted. No app can shrink `visibleFrame` for others, so windows land under the dock first and are fitted after they settle (60ms, or 300ms after an animation or a re-fit: macOS re-applies Window > Fill's frame for 150 to 300ms after its last event). AX calls block on the target app, so observers run on their own thread and fitting on a serial queue with 0.25s AX timeouts; the reveal path never waits on another app. A window that resets its size three times in 2s, or refuses the frame twice, is left alone. When the reservation changes, windows flush with the old dock edge follow it (new depth on the same edge, otherwise the `visibleFrame` edge) and windows flush with the screen edge are fitted; on quit (including SIGTERM/SIGINT/SIGHUP) fitted windows are released synchronously so no dead band is left behind.

## Project layout

```
Sources/portside/
  PortsideApp.swift         Entry point (--restore-dock, --export-icon, crash recovery, signals), menu bar, About panel, app delegate
  DockEngine.swift          Coordinator for tracker, panel, hide timer, and model
  EdgeTracker.swift         Per-screen edge windows with NSTrackingArea (event-driven reveal)
  DockPanel.swift           Non-activating NSPanel, slide animation, panel tracking, multi-display relocate
  DockModel.swift           Codable settings and entries, persistence to dock.json
  DockEdge.swift            Bottom/Left/Right enum and DockScreen (active display)
  DockReservation.swift     Space the pinned dock takes from its edge (depth, band, usable frame)
  AccessibilityTrust.swift  Observable Accessibility permission (system notification, no polling), prompt, Settings link
  WindowFitter.swift        Accessibility observers that fit other apps' flush windows clear of the pinned dock
  DockStrip.swift           SwiftUI strip: tiles, widgets, separator, reorder, drops
  DockItem.swift            App tile, icon cache, launch/activate
  DockBadges.swift          Notification badges: visible-only reads and the badge chip
  LaunchServicesBadges.swift Private LaunchServices badge reader (dlopen/dlsym guarded)
  AgentFocus.swift          Focuses an agent's window: Terminal/iTerm tab by tty, else AX window by project name
  WidgetPreviews.swift      Debug only: `--render-widget-previews <dir>` renders sample widget tiles to PNG
  AgentHooks.swift          Installs / removes the Agents widget hook in ~/.claude and ~/.codex (embedded script)
  AppActivity.swift         Per-app activity icons: mic, camera, audio (CoreAudio/CoreMediaIO listeners), Working (CPU sampler)
  TileActions.swift         Modifier clicks (Cmd, Option) and the AppKit right-click menu with Force Quit
  AppLoginItem.swift        Open at Login checkbox: SMAppService for Portside, System Events for other apps
  FileDrop.swift            Per-drag state for pin apps/folders, open, deposit, and Trash drops
  AppSpringLoad.swift       File drag resting on a running app brings it forward
  Trash.swift               Native Trash tile, directory watcher, Finder actions
  TrashDrop.swift           Confirm when a dock tile is dropped on Trash
  FolderStack.swift         Folder stack model and FSEvents contents
  StackController.swift     Stack open/close, drag-open, deposit into folder
  StackViews.swift          Stack tile, grid/list popover, and fan
  StackItemDrag.swift       Drag a stack item out as a file (AppKit dragging session)
  DragOut.swift             Drag an item out to remove it: "Remove" label, poof, Escape
  DockHover.swift           Hover target frames and label placement
  Magnifier.swift           Dock magnification: per-tile scale and shift from the cursor, shelf widening, panel room
  FolderGroup.swift         Group, spacer, and entry models
  GroupController.swift     Group open/close state and every close path
  GroupRemoval.swift        "Remove group?" confirmation alert and focus hand-back
  GroupViews.swift          Group tile and expanded grid views
  GroupIcon.swift           Custom group icon: model, SF Symbols catalog, artwork, picker
  PaletteColorEditor.swift  The one color picker: preview, hex, presets, Hue/Saturation/Tint/Shade/Opacity
  OverlayPanel.swift        Reusable non-activating overlay panel
  LaunchBounce.swift        Native-style launch bounce animation
  RunningApps.swift         Running app tracking via NSWorkspace notifications
  NativeDock.swift          Native Dock hide/restore: prefs backup, writes, Dock restart, verify
  NativeDockController.swift  "Hide the macOS Dock" toggle, first-time dialog, alerts
  NativeDockImport.swift    Reads the native Dock (apps, position, size) and the import sheet
  LaunchAtLogin.swift       "Open Portside at login" via SMAppService.mainApp
  SettingsWindow.swift      Settings window: sidebar and panes (Dock, Appearance, Widgets, Groups, General)
  DockAppearance.swift      Icon style and dock background options, background modifier, icon style observer
  SeeThroughGlass.swift     Guarded private glass variant, the see-through lens in Liquid Glass
  NativeDockGlass.swift     Guarded rebuild of the native Dock glass, measured against the real Dock
  HotKey.swift              Global hotkeys (Carbon RegisterEventHotKey), chord model, Settings shortcut recorder
  BackgroundCursor.swift    Guarded SkyLight call for the resize cursor
  AppIcon.swift             App icon: system-rendered in Portside.app, bundled PNGs under swift run, PNG export
  BrandAssets.swift         Safe resource bundle lookup (no Bundle.module), menu bar template icon
  AppInfo.swift             App name, author, version line, and repo URL
  BuildInfo.swift           Generated by scripts/gen-version.sh: version, git hash, dirty flag
  UpdateChecker.swift       Update check + in-place install (GitHub release DMG vs AppInfo.version)
  WidgetProtocol.swift      Widget plugin protocol, sizes, and the shared spacing rule (WidgetLayout, EvenRow)
  WidgetHost.swift          Widget lifecycle and refresh timer
  Widgets/
    ClockWidget.swift       Time and date
    BatteryWidget.swift     Battery percent and charging state
    CalendarWidget.swift    Date and next event
    WeatherWidget.swift     Temperature and conditions (Open-Meteo)
    SystemStatsWidget.swift Combined concentric rings and separate CPU / Memory gauges
    NowPlayingWidget.swift  Spotify / Music art, song, artist, controls (notifications + AppleScript)
    AgentStatusWidget.swift Coding agent provider, count, working/done (hook status files)
    UsageWidget.swift       Claude / Codex 5-hour and weekly, Copilot monthly usage meters
  Support/                  Bundled resources: AppIcon-<px>.png (actool's flat render of AppIcon.icon) and MenuBarIcon-<px>.png
Sources/AppLoginItemList/   C helper: read session Open at Login list (LSSharedFileList)
scripts/
  swift-env.sh              Shared SPM env (disables Explicitly Built Modules by default)
  gen-version.sh            Writes BuildInfo.swift from VERSION and git
  release.sh                Bumps VERSION on a release branch and opens a pull request
  publish-release.sh        After the PR merges: tags, notarizes, pushes the tag, GitHub release with the .dmg (runs check-repo-visibility)
  check-repo-visibility.sh  One gh call: docs/github-visibility vs live private/public
  setup-notary.sh           Stores notarytool keychain profile (portside-notary)
  build-app.sh              Builds and signs build/Portside.app (--install, --package, --notarize)
  make-dmg.sh               Builds the drag-to-Applications DMG (layout, background, volume icon)
  DMGBackground.swift       Renders the DMG background (arrow + drop zone) at 1x and 2x
  setup-signing.sh          Creates or reuses the stable local code signing identity
  ensure-codesign-key-access.sh  Native Okay consent + Touch ID, then silent key unlock
  SigningConsent.swift      Stock NSAlert + LocalAuthentication for build consent
  check-tile-input.swift    Synthetic Accessibility check: clicks, hold menu, label centering
  window-fit-probe/         Probe window + AX observer: how Rectangle, Window > Fill and Dock hiding resize windows (run.sh)
Portside.entitlements       Hardened Runtime entitlements for Developer ID / notarized builds
design/                    Approved Portside sail icon, wordmarks, menu bar assets, and tokens; see its README
```
