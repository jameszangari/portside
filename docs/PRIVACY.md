# Privacy and permissions

The full list of what Portside sends, asks for, writes and reads. The [README](../README.md#privacy) has the short version.

Portside has no telemetry and no account. Everything stays on your Mac except the requests below.

## Network

Only these hosts:

| Host | When | What is sent |
| --- | --- | --- |
| `api.github.com`, `github.com`, `*.githubusercontent.com` | At launch and daily when automatic checks are on, Check for Updates, Install Update | A version check and the release DMG download. No identifiers. |
| `api.open-meteo.com`, `geocoding-api.open-meteo.com` | Weather widget on | The city you type, then its coordinates |
| `api.anthropic.com` | AI Usage widget with Claude, after you allow it | Claude Code's sign-in token, to ask for your usage |
| `api.github.com` | AI Usage widget with Copilot, after you allow it | The GitHub CLI's token, to ask for your Copilot quota. The optional Copilot CLI source is off by default. |
| Spotify's artwork host (`https` only) | Now Playing with Spotify | A cover art request for the current track |

## Permissions

macOS asks when a feature first needs them.

- **Accessibility:** fit maximized windows clear of the dock; raise an agent's window; read and press items in the native Dock's tile menu; list and focus windows in the App Switcher; list, open and move menu bar items; take the volume and brightness keys for the Top Notch indicator. Restricted mode keeps the sensitive tools off.
- **Notifications:** available update alerts. If declined, the menu bar still marks an available update.
- **Full Disk Access:** optional, granted manually through General > Permissions for protected files such as Trash. It does not override corporate security policy.
- **System Audio Recording:** optional actual-playback measurement. Audio buffers are reduced to levels locally and discarded, never saved or sent. Full Disk Access does not grant this permission.
- **Screen Recording:** optional window previews in the App Switcher, captured with ScreenCaptureKit only while the switcher is open, kept in memory, never saved or sent.
- **Bluetooth:** optional Live AirPods levels (Top Notch, off by default). Portside listens for the battery levels AirPods broadcast nearby, only while a pair is connected. Off in restricted mode.
- **Calendar:** the Calendar widget's next event and the Top Notch meeting countdown (off in restricted mode).
- **Automation:** Finder (empty Trash, Trash count), System Events (Open at Login), Spotify or Music (Now Playing; other players need no permission), Terminal or iTerm (bring an agent's tab forward). The Shortcuts tool runs `/usr/bin/shortcuts` only when you pick a shortcut.
- **Keychain:** Clipboard History keeps its encryption key in your login keychain (`com.james.portside.clipboard-history`, this Mac only, available while unlocked).
- **Files and folders:** only the folders you add to Command Center file search, and files you drop on the Top Notch.

## Files Portside writes

- `~/Library/Application Support/com.james.portside/`: `dock.json` and its backups, `native-dock-backup.json` while the macOS Dock is hidden, plus `agent-hook.sh` and `agents/` if you install the agent hooks. Optional tools add their own files there, each only once used: Command Center history, snippets and searchable folders (`command-center-*.json`), encrypted clipboard text (`command-center-clipboard.bin`, kept for the time you choose and cleared by Clear History), the Top Notch file list (`notch-shelf-files.json`, paths only, not copies), a chosen menu bar icon, and menu bar backups and a crash journal.
- `~/Library/Logs/Portside/update.log`.
- Only if you click Install Hooks: entries in `~/.claude/settings.json`, `~/.codex/hooks.json` and `~/.codex/config.toml`, each backed up once to `<file>.portside.bak`. Remove Hooks undoes it.
- With "Hide the macOS Dock" on: `autohide` and `autohide-delay` in `com.apple.dock`, restored on quit.
- Menu bar hiding on macOS 27 (experimental), only after you grant each file in Settings and with a backup first: the saved item order in `com.apple.MenuBar.plist` (then `MenuBarAgent` restarts to read it), and the per-app menu bar list in Control Center's settings (Native method). The Live Activities switch writes only `RemoteLiveActivitiesEnabled` in `com.apple.controlcenter`, when you flip it, backed up first.

## What widgets read

AI Usage reads Claude Code's keychain token only after you agree, Codex's local session logs in `~/.codex/sessions`, and, only after you agree, your Copilot quota using `gh auth token`, or the Copilot CLI if separately enabled. Agents reads the hook files above and, with Accessibility, whether a ChatGPT app window's composer shows Stop (a reply in progress) and its title. Battery, System Stats, CPU and Memory read local system counters. Now Playing asks Spotify or Music what is playing, and reads the system's Now Playing for other players through a bundled helper run by the system's `perl`. The Top Notch reads AirPods battery levels with `system_profiler`. The music visualizer, when React to the sound is on, taps only the playing app's audio for its levels and keeps nothing. Clipboard History (off by default) skips passwords and other sensitive pasteboard types and apps you exclude.

## Local Servers

Optional, off by default. when you search a port or server in Command Center, or pick Refresh, Portside runs `/usr/sbin/lsof` once to list the TCP servers your account runs and reads each one's start time, owner and executable path from macOS. It also reads each one's working directory and names the project from the nearest Git repository above it (shown as inferred, or Unknown). It never reads their arguments or environment, never connects to them, and keeps the list only while the panel is open. While server results are showing, a listener that exits disappears right away (a macOS process-exit event, confirmed before removal) and a background re-list finds new ones every few seconds, backing off when nothing changes and stopping after a few quiet rounds; nothing runs when the panel is closed, the query shows no servers, or the module is off. Stop Server requires your confirmation of the process, PID and port, rechecks ownership and identity, and sends only SIGTERM; protected, unknown and changed targets are refused. Only its still-running receipt unlocks a separate Force Stop (SIGKILL) confirmation, defaulting to Cancel and warning about data loss. Force Stop revalidates the exact process and listener again, sends once, then refreshes all server results. No automatic escalation or retry exists. With Local Intelligence on, a port question you type is read by Apple's on-device model on this Mac (never a hosted service); the model only names the port, and nothing it writes is run or shown.
