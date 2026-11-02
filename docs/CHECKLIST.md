# Portside: Checklist

Status of the milestones in `docs/PLAN.md`, what still needs a hand check, and the backlog. The long dated build log that used to live here was removed for the public release; it is in the git history.

## Roadmap

- [x] **A:** Edge tracker, non-activating panel, slide animation
- [x] **B:** Pinned apps, running indicators, drag reorder, persistence
- [x] **B.5 / B.6:** Hover labels; dock position (bottom, left, right) and separator resize
- [x] **C:** Widget protocol and widgets (Clock, Calendar, Weather, System Stats, Battery, then CPU, Memory, Now Playing, Agents, AI Usage)
- [x] **D:** App groups (expand and collapse, custom icons)
- [x] **E:** Settings window (sidebar panes, live apply, global hotkey)
- [x] **F:** Hide the macOS Dock (autohide-delay only, exact save and restore), Open at Login (`SMAppService`), `.app` bundle, notification badges, Developer ID signing and notarization, DMG release, in-place Check for Updates
- [x] **P1-P3 parity:** context menus, Trash, folder stacks (grid, fan, list), spacers, spring-load, magnification, multi-display, fullscreen and Spaces, windows fit clear of the dock, activity icons

## Needs a hand check

These were built and tested with synthetic input; a person should confirm them on a real machine:

- Open at Login from the app tile menu (Automation prompt, no focus steal)
- Two displays: the dock follows the cursor's display; dragging a window across the edge does not reveal
- Fullscreen apps and Space switches keep the reveal working
- Magnification with 27+ apps, group grids, and menus
- Calendar consent and Downloads permission retention in the signed app
- Download the DMG from a release, drag to Applications, launch with no Gatekeeper prompt

## Backlog

- Import plain file tiles from the native Dock (folders already import)
- Window list in the app right-click menu
- VoiceOver labels and keyboard navigation
- Side-dock widget layout (side docks show Small widgets)
- Window previews on hover; profiles (saved layouts)
- Trash: Option-click Empty without the warning
- Move the older widgets (Clock, Calendar, Weather, Battery, System Stats) onto the shared `WidgetLayout` spacing
- Optional: hide badges when an app's own notification badge setting is off, if that becomes readable

Out of scope: minimized windows in the Dock, the two-finger App Expose gesture, assigning apps to Spaces, bounce on attention request (needs private APIs).

## Known gaps

- Camera usage has no public per-app owner API, so a running camera is credited to apps also using the microphone.
- Codex usage meters only move after a Codex turn that logs `rate_limits` numbers.
- The AI Usage Claude meter uses an undocumented Anthropic endpoint and may stop working without notice.
- The AI Usage Copilot meter uses the CLI's experimental `account.getQuota` or GitHub's undocumented `copilot_internal/user`, and either may change. ACP has no quota method, so `copilot --acp` use is counted through the account-wide quota, not read over ACP. Only tested on a free plan against live data; paid plan parsing is tested with a stub reply.
- The Copilot CLI is found in fixed install locations only (Homebrew, `~/.local/bin`, npm global, nvm, `gh copilot`, VS Code). Elsewhere the meter falls back to the GitHub CLI.
- The Agents widget does not track Copilot sessions; it covers Claude Code and Codex only.
- Copilot has no app icon unless Copilot for Xcode is installed, so its gauge shows a "C".
- A clicked-open group or folder closes only on a click. Cmd-Tab or a Space switch leaves it (and an auto-hiding dock) up until the next click.
- The Settings sidebar sits flush with the window edge and the toolbar can end in a hard line, unlike the floating sidebar and soft edge in System Settings.
- Window fitting is not measured with Stage Manager, edge-drag tiling, Raycast window commands, or apps with their own minimum height.
- Group tiles and Portside's own tile use SwiftUI `.contextMenu`, so right-click works only on their unmagnified area.
- The DMG layout script drives Finder; your Finder preferences (path bar, hidden files) show in the DMG window.
