<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="design/wordmarks/portside-horizontal-dark.png">
    <img src="design/wordmarks/portside-horizontal-light.png" alt="Portside" width="440">
  </picture>
</p>

<p align="center"><b>A dock that's already there when you reach for it.</b></p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-10283F?logo=apple&logoColor=white" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Swift-5.10%2B-F06A42?logo=swift&logoColor=white" alt="Swift 5.10 or later">
</p>

# Portside

A fast, event-driven dock replacement for macOS, written in Swift (SwiftUI and AppKit) and built with SwiftPM. Touch the edge and it starts sliding in within a frame. Move away and it gets out of the way. No polling, no focus stealing, no lag.

Free and open source (MIT). Requires **macOS 26 or later on Apple Silicon**. Brand assets and the two-page [brand guide](design/presentation/portside-approved-identity-v2.pdf) live in [`design/`](design/README.md).

## Install

Download the latest `Portside-X.Y.Z.dmg` from [Releases](https://github.com/jameszangari/portside/releases/latest), open it, and drag Portside to Applications (or `~/Applications`). Releases are signed with a Developer ID and notarized. Later versions install from inside the app: Settings > Check for Updates.

macOS asks for permissions as features need them; see [Privacy and permissions](#privacy-and-permissions).

## Features

- **Reveal:** event-driven edge tracking, non-activating panel, slide animation, multi-display, file-drag reveal, notification badges, windows fit clear of the pinned dock (Accessibility)
- **Apps:** pin, reorder, drag-out remove, Finder drops, running apps, recent apps, indicator and hidden-app options, Open at Login, native modifier clicks, launch bounce, native-style tile menu (recents with icons, windows, Options, Show All Windows; Accessibility)
- **Activity icons:** camera (green), microphone (orange), animated speaker while audio output is active (opt-in measurement hides silent streams), working dots (CPU-based, per app)
- **Layout:** Bottom / Left / Right, live icon size and gap, magnification with shelf
- **Widgets:** Clock, Battery, Calendar, Weather, System Stats, CPU, Memory, Now Playing, Agents, AI Usage with Claude, Codex and Copilot, your pick (Small / Wide / Extra Wide on the bottom dock)
- **Groups and stacks:** app groups with grids and optional custom icons (SF Symbol + palette color); folder stacks (grid / native-style fan / list) with FSEvents, drag items out to any app; network shares that mount again on click; Network server and web link tiles; Trash tile
- **Appearance:** match macOS icon style or Original; Liquid Glass (matches the native Dock in dark mode, or Custom with every part adjustable) or Solid (color or gradient, optional backdrop blur) background; one color picker everywhere (Brand, Neutrals, macOS and RGB presets, hex, hue, saturation, tint, shade, opacity)
- **Native Dock:** hide via autohide-delay (save/restore, also right after a crash), import apps and folders, open at login via `SMAppService`, optional Settings on launch
- **Agent notch:** optional island attached to the notch (inside the menu bar on displays without one) or floating with a snake-box thinking loader while agents work, audio bars while Spotify/Music play, attention counts, expandable session cards, plan-usage gauges, and a full Settings > Agent Notch customization pane
- **Command Center:** optional (Settings > Integrations, off by default) ⌥Space search panel without leaving the current app: installed and running apps (launch or switch), Portside's commands, Settings panes, your own quicklinks (https, http, mailto and System Settings links only), snippets you save (copied as plain text), your Apple Shortcuts (optional Shortcuts module, run only when picked), file names inside folders you choose (optional Files module), your copied text (optional, encrypted Clipboard History module), a calculator (`2+2`, copies the result) and emoji search (`emoji rocket`, `:rocket`, copies the character) and, with the optional Local Servers module, the TCP servers your account runs (search a port or process, copy the address or port, open on loopback as http or https only when you pick it, manual refresh, confirmed graceful stop of one validated owned process, separately confirmed Force Stop only after its SIGTERM timeout), and with Local Intelligence also on, port questions such as "What's using port 5173?" read by Apple's on-device model, with the answer always from the native listing and a numeric search offered when the model cannot run; fuzzy matching with deterministic ranking boosted by recent and frequent picks (clearable history); keyboard first (arrows, Return, Esc ladder, Cmd+K actions), unavailable reasons, IME safe, VoiceOver labels, configurable shortcut with conflict warnings
- **App Switcher:** optional (Settings > Integrations, off by default) ⌥Tab switcher over running apps, most recently used first, drawn like the macOS ⌘Tab switcher: tap for the previous app (repeated taps alternate the last two), hold ⌥ and press Tab or Shift-Tab or point at an entry to choose, ↓ for one of the app's windows, let go to switch, Esc to cancel even with ⌥ held; optional window-first mode (one row per window with title, icon, display, minimized and full screen) and / for title search that stays open after you let go; apps need no Accessibility (windows do), Portside never takes focus, native ⌘Tab untouched; optional window previews (off by default, needs Screen Recording): one still picture of each visible window row while the switcher is open, icons for anything else
- **Settings:** mouse and keyboard sidebar navigation, app title aligned with the Layout heading, live apply, an Integrations pane (modules, live permission status with reasons and fallbacks, restricted mode for work Macs, and a Local Intelligence switch with live availability of Apple's on-device model, on-device only with no cloud fallback; only Command Center's port questions use it), global hotkeys (Settings ⌘⇧D, Command Center ⌥Space, App Switcher ⌥Tab), automatic daily update checks and notifications, plus Check for Updates (a newer release opens a modal that downloads, verifies, and installs it in place from the GitHub release DMG, then reopens Portside)

Full detail: [docs/FEATURES.md](docs/FEATURES.md).

## Planned

The proposed [Portside 2.0 roadmap](docs/ROADMAP_2_0.md) extends the Command Center with further optional tools, extends the App Switcher with an optional ⌘Tab replacement and Dock hover previews, and adds the rest of the developer server manager (project association, exit events and bounded visible refresh), smart workspaces, studio companion and agent supervisor, with optional local-only AI. Menu bar management is gated on public API feasibility. See the [incremental tickets and first PRs](docs/IMPLEMENTATION_PLAN_2_0.md) for implementation order. These capabilities are planned, not shipped.

Existing [docs/CHECKLIST.md](docs/CHECKLIST.md) backlog remains:

- Hand-check signed-app update notifications and installation, notch positioning on built-in displays, and corporate-proxy Copilot access
- Hand-check Calendar consent, Downloads permission retention, and Settings header spacing in the signed app
- Import plain file tiles from `persistent-others` (folders already import)
- VoiceOver / keyboard navigation
- Side-dock widget layout; Dock hover window previews; profiles; Trash Option-click Empty

## Privacy and permissions

Portside has no telemetry and no account. Everything stays on your Mac except the requests below.

**Network** (only these hosts):

| Host | When | What is sent |
| --- | --- | --- |
| `api.github.com`, `github.com`, `*.githubusercontent.com` | At launch and daily when automatic checks are on, Check for Updates, Install Update | A version check and the release DMG download. No identifiers. |
| `api.open-meteo.com`, `geocoding-api.open-meteo.com` | Weather widget on | The city you type, then its coordinates |
| `api.anthropic.com` | AI Usage widget with Claude, after you allow it | Claude Code's sign-in token, to ask for your usage |
| `api.github.com` | AI Usage widget with Copilot, after you allow it | The GitHub CLI's token, to ask for your Copilot quota. The optional Copilot CLI source is off by default. |
| Spotify's artwork host (`https` only) | Now Playing with Spotify | A cover art request for the current track |

**Permissions** (macOS asks when a feature first needs them):

- **Accessibility:** fit maximized windows clear of the dock; raise an agent's window; read and press items in the native Dock's tile menu.
- **Notifications:** available update alerts. If declined, the menu bar still marks an available update.
- **Full Disk Access:** optional, granted manually through General > Permissions for protected files such as Trash. It does not override corporate security policy.
- **System Audio Recording:** optional actual-playback measurement. Audio buffers are reduced to levels locally and discarded, never saved or sent. Full Disk Access does not grant this permission.
- **Calendar:** the Calendar widget's next event.
- **Automation:** Finder (empty Trash, Trash count), System Events (Open at Login), Spotify or Music (Now Playing), Terminal or iTerm (bring an agent's tab forward).

**Files Portside writes:**

- `~/Library/Application Support/com.james.portside/`: `dock.json` and its backups, plus `agent-hook.sh` and `agents/` if you install the agent hooks.
- `~/Library/Logs/Portside/update.log`.
- Only if you click Install Hooks: entries in `~/.claude/settings.json`, `~/.codex/hooks.json` and `~/.codex/config.toml`, each backed up once to `<file>.portside.bak`. Remove Hooks undoes it.
- With "Hide the macOS Dock" on: `autohide` and `autohide-delay` in `com.apple.dock`, restored on quit.

**What widgets read:** AI Usage reads Claude Code's keychain token only after you agree, Codex's local session logs in `~/.codex/sessions`, and, only after you agree, your Copilot quota using `gh auth token`, or the Copilot CLI if separately enabled. Agents reads the hook files above. Battery, System Stats, CPU and Memory read local system counters. Now Playing asks Spotify or Music what is playing.

**Local Servers** (optional, off by default): when you search a port or server in Command Center, or pick Refresh, Portside runs `/usr/sbin/lsof` once to list the TCP servers your account runs and reads each one's start time, owner and executable path from macOS. It also reads each one's working directory and names the project from the nearest Git repository above it (shown as inferred, or Unknown). It never reads their arguments or environment, never connects to them, and keeps the list only while the panel is open. While server results are showing, a listener that exits disappears right away (a macOS process-exit event, confirmed before removal) and a background re-list finds new ones every few seconds, backing off when nothing changes and stopping after a few quiet rounds; nothing runs when the panel is closed, the query shows no servers, or the module is off. Stop Server requires your confirmation of the process, PID and port, rechecks ownership and identity, and sends only SIGTERM; protected, unknown and changed targets are refused. Only its still-running receipt unlocks a separate Force Stop (SIGKILL) confirmation, defaulting to Cancel and warning about data loss. Force Stop revalidates the exact process and listener again, sends once, then refreshes all server results. No automatic escalation or retry exists. With Local Intelligence on, a port question you type is read by Apple's on-device model on this Mac (never a hosted service); the model only names the port, and nothing it writes is run or shown.

## Build from source

You need macOS 26+, Apple Silicon, and the Xcode command line tools. No Xcode project and no signing identity required:

```
source scripts/swift-env.sh
swift build
swift run portside
```

For a `.app` bundle: `SIGN_IDENTITY=- scripts/build-app.sh` (ad hoc signed, so macOS re-asks for permissions after each rebuild), then `open build/Portside.app`. The maintainer's own signing setup is in [docs/BUILD.md](docs/BUILD.md).

Logs: `log stream --level info --predicate 'subsystem == "com.james.portside"'`

Restore the native Dock without UI: `swift run portside --restore-dock`

Contributing: [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md). Build, signing, DMG, and release steps: [docs/BUILD.md](docs/BUILD.md).

## Docs

| Doc | What |
| --- | --- |
| [FEATURES.md](docs/FEATURES.md) | Full feature list |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it works, private-API notes, project layout |
| [BUILD.md](docs/BUILD.md) | Requirements, SPM, `.app`, signing, versioning |
| [DATA.md](docs/DATA.md) | `dock.json`, backups, signing identity paths |
| [PLAN.md](docs/PLAN.md) | Original milestones A to F |
| [ROADMAP_2_0.md](docs/ROADMAP_2_0.md) | Phases, UX journeys, release gates and replacement scope |
| [IMPLEMENTATION_PLAN_2_0.md](docs/IMPLEMENTATION_PLAN_2_0.md) | Small tickets, dependencies, acceptance criteria and first PRs |
| [ARCHITECTURE_2_0.md](docs/ARCHITECTURE_2_0.md) | Proposed registries, permissions and local-only intelligence |
| [TEST_MATRIX_2_0.md](docs/TEST_MATRIX_2_0.md) | Validation matrix, performance budgets and rollout gates |
| [REA_RESEARCH_2_0.md](docs/REA_RESEARCH_2_0.md) | Reference-app investigation and evidence workflow |
| [CHECKLIST.md](docs/CHECKLIST.md) | Status and backlog |
| [Brand](design/README.md) | Sail identity, wordmarks, tokens |

## License

[MIT](LICENSE). Provided as is, with no warranty. Portside moves and resizes windows, edits the macOS Dock's auto-hide settings when you ask it to, and can edit your agent hook files; read the permissions above before you enable those features.
