# Where data lives

Settings and the dock layout are saved as JSON at:

```
~/Library/Application Support/com.james.portside/dock.json
```

Before each "Import from macOS Dock", the previous layout is copied to `dock.json.before-import` in the same folder (overwritten by the next import, deleted by "Undo last import").

Keeping preferences across versions:

- `savedByVersion`: the Portside version that last wrote the file.
- Top-level keys this build does not know (written by a newer build) are kept on every save, so running an older copy does not drop newer settings. Builds up to 0.5.0 do not do this.
- If the file was written by a newer version, it is copied once to `dock.json.from-<version>` before this build saves anything (nested values an older build does not know can still be lost).
- A file that cannot be read is moved to `dock.json.unreadable-<timestamp>` instead of being overwritten, then a fresh layout is seeded.
- Check for Updates copies the file to `dock.json.before-update` right before replacing the app. The app swap itself never touches this folder.

Update steps are logged to `~/Library/Logs/Portside/update.log`.

While "Hide the macOS Dock" is on, the native Dock's prior settings are backed up at:

```
~/Library/Application Support/com.james.portside/native-dock-backup.json
```

It is deleted after a verified restore. If it exists when Portside starts, Portside restores from it first.

## Settings controlled from the UI

- Position, auto-hide, keep windows clear of the dock while hiding is off (`reserveSpace`, default `true`; needs Accessibility), icon size, icon gap (`iconGap`, points, 0 to 8, default 6), "Animate opening applications"
- Open Settings hotkey (`settingsHotkey`: `{ keyCode, modifiers }` Carbon values, default Command-Shift-D; `null` means cleared; missing key keeps the default)
- Show Trash in dock (`showTrash`, default `true`); dismissed Full Disk Access hint (`trashAccessHintDismissed`, default `false`)
- Show notification badges (`showBadges`, default `true`); badge color (`badgeColor`: `macOS`, `accent`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `graphite` or `custom`, default `macOS`); custom badge color (`badgeCustomColor`, a palette color as below, opacity ignored, used when `badgeColor` is `custom`)
- Activity icons (`activityIcons`: `{ camera, microphone, audio, working, workingApps }`; the four kinds default `true`; `workingApps` is the bundle ids watched for Working, default `com.t3tools.t3code`, `com.anthropic.claudefordesktop`, `com.openai.codex`)
- Widget sizes (`widgetSizes`: `{ kind: 1 | 2 }`, bottom dock only; 1 is Small, 2 is Wide; written only for widgets not at their own size)
- Layout (`layout`, written only once you move something: ordered ids such as an app's id, `group:<id>`, `spacer:<id>`, `widget:<kind>`, `stack:<id>`, `trash`, `running`, `separator:<id>`; missing items are slotted in beside their own kind)
- Folder stacks (`stacks`: `{ id, path, itemOrder?, view?, sort?, foldersFirst?, showHidden?, showAsFolder? }[]`, right section before Trash; `itemOrder` is child filenames for Custom Order placement; `view` is `grid` (default), `fan`, or `list`; `sort` is `manual` (default), `name`, `dateAdded`, `dateModified`, or `kind`; the rest are written only when on)
- Magnification (`magnificationEnabled`) and Magnified size (`magnifiedSize`, points, 16 to 128, default 64)
- Reveal delay, hide delay, animation duration (with reset to defaults)
- Widgets: on/off (`widgetKinds`; dragging a widget in the dock updates both this order and `layout`; optional `cpu`, `memory`, `nowPlaying`, `agents` and `usage`, off by default)
- AI Usage providers (`usageProviders`: ordered provider ids, `claude` and/or `codex`; default both, written only when changed)
- Agent status files (not in dock.json): `agents/<pid>.json` next to dock.json, one per agent process, written by the hook script (`agent-hook.sh`, installed from Settings > Widgets > Agent Hooks): `{ provider ("claude" or "codex"), pid, time (Unix seconds), payload (the hook's stdin JSON) }`. Portside reads `payload.cwd` for the project name and maps `payload.hook_event_name` to idle, working, or done, and deletes the file on `SessionEnd` or when the process is gone. Installing also sets `codex_hooks = true` under `[features]` in `~/.codex/config.toml`, and backs up each changed agent file once to `<file>.portside.bak`
- Groups: rename, ungroup, delete, open on hover, open delay, close grace. A group entry may carry `icon: { symbol, color, theme? }` (an SF Symbol name, a palette color as below with opacity ignored, and `theme` `light` or `dark` to pin that icon's style; absent means `system`, following the macOS icon style; no `icon` means the app grid). Older files with `color` as a name (`blue`, `indigo`, ...) or a separate `custom` color still load and are rewritten as a palette color on the next save
- Appearance: icon style (`iconStyle`: `matchSystem` or `original`), `background` object (below), `cornerRadius` (points). Older `backgroundStyle` / `backgroundFrost` / `backgroundTint` keys are read once for migration and no longer written
- `background`: `style` (`glass`, `frosted`, or `solid`) plus one object per style, all kept when switching. Fractions are 0 to 1.
  - Palette colors (tints, solid colors, custom badge, group icons): `base` (sRGB `red`, `green`, `blue`, `alpha` 1), `hue` (0 to 1, a turn around the color wheel, default 0), `saturation`, `tint` (toward white), `shade` (toward black), `opacity`. A plain sRGB `{ red, green, blue, alpha }` from older builds still loads, with its alpha as the opacity.
  - `glass`: `variant` (`regular` or `clear`), `strength`, `tint` (absent when off), `savedTint` (the tint kept while off, restored when turned back on)
  - `frosted`: `material` (`ultraThin`, `thin`, `regular`, `thick`, `ultraThick`), `strength`, `tint` (absent when off), `savedTint` (as for glass), `border`
  - `solid`: `fill` (`color`, `linear`, `radial`), `color`, `endColor`, `angle` (degrees, 0 to 359), `opacity`, `border`
- Native Dock options: `showIndicators` (default true), `showRecents` (default true, like macOS), `recentApps` (up to 3 `PinnedApp`, most recent first; absent when empty), `dimHiddenApps` (default false)
- Open Settings on launch (`openSettingsOnLaunch`, default `false`)
- Hide the macOS Dock (`hideNativeDock`, plus `nativeDockExplained` once the first-time dialog was confirmed)
- Import from macOS Dock and Undo last import (nothing new stored in `dock.json`; imported apps, spacers, position, and icon size land in `entries`, `edge`, and `iconSize`). Entries may include `{ type: "spacer", spacer: { id, size } }` (`regular` or `small`).
- Open Portside at login: not stored by Portside. macOS keeps it (System Settings > General > Login Items).

## Build outputs and signing

The built app lives at `build/Portside.app` (ignored by git), with a copy of the latest build at `Portside.app` in the repo root (also ignored; the stapled release app after `--notarize`). The versioned release disk image is at `build/dist/Portside-X.Y.Z.dmg`, and the installed copy at `~/Applications/Portside.app` after `scripts/build-app.sh --install`.

The local signing certificate and private key live in your default user keychain. Its fingerprint is stored at `~/Library/Application Support/com.james.portside/signing/identity.sha1`. Keep the same identity across rebuilds. Downloads and other macOS privacy decisions are managed by macOS, outside `dock.json`.

An optional GitHub personal access token for Check for Updates (private repo) is stored in the keychain as service `com.james.portside.github-token`, never in `dock.json`. If that is empty, Portside also tries the GitHub CLI's `gh:github.com` keychain entry. Expected repo visibility is the one-word file `docs/github-visibility` (`private` today); see `docs/BUILD.md` if that ever becomes `public`.
