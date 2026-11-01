# Where data lives

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

## Settings controlled from the UI

- Position, auto-hide, icon size, icon gap (`iconGap`, points, 0 to 8, default 6), "Animate opening applications"
- Open Settings hotkey (`settingsHotkey`: `{ keyCode, modifiers }` Carbon values, default Command-Shift-D; `null` means cleared; missing key keeps the default)
- Show Trash in dock (`showTrash`, default `true`); dismissed Full Disk Access hint (`trashAccessHintDismissed`, default `false`)
- Show notification badges (`showBadges`, default `true`); badge color (`badgeColor`: `macOS`, `accent`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `graphite` or `custom`, default `macOS`); custom badge color (`badgeCustomColor`, sRGB `{ red, green, blue, alpha }`, used when `badgeColor` is `custom`)
- Widget sizes (`widgetSizes`: `{ kind: 1 | 2 }`, bottom dock only; 1 is Small, 2 is Wide; written only for widgets not at their own size)
- Layout (`layout`, written only once you move something: ordered ids such as an app's id, `group:<id>`, `spacer:<id>`, `widget:<kind>`, `stack:<id>`, `trash`, `running`, `separator:<id>`; missing items are slotted in beside their own kind)
- Folder stacks (`stacks`: `{ id, path, itemOrder?, view?, sort?, foldersFirst?, showHidden?, showAsFolder? }[]`, right section before Trash; `itemOrder` is child filenames for Custom Order placement; `view` is `grid` (default), `fan`, or `list`; `sort` is `manual` (default), `name`, `dateAdded`, `dateModified`, or `kind`; the rest are written only when on)
- Magnification (`magnificationEnabled`) and Magnified size (`magnifiedSize`, points, 16 to 128, default 64)
- Reveal delay, hide delay, animation duration (with reset to defaults)
- Widgets: on/off and order (`widgetKinds`; optional `cpu` and `memory` alongside `systemStats`, no new keys)
- Groups: rename, ungroup, delete, open on hover, open delay, close grace
- Appearance: icon style (`iconStyle`: `matchSystem` or `original`), background (`backgroundStyle`: `glass`, `frosted`, or `solid`), `backgroundFrost` (0 to 1), `backgroundTint` (sRGB `red`, `green`, `blue`, `alpha`; absent when off), `cornerRadius` (points)
- Hide the macOS Dock (`hideNativeDock`, plus `nativeDockExplained` once the first-time dialog was confirmed)
- Import from macOS Dock and Undo last import (nothing new stored in `dock.json`; imported apps, spacers, position, and icon size land in `entries`, `edge`, and `iconSize`). Entries may include `{ type: "spacer", spacer: { id, size } }` (`regular` or `small`).
- Open Portside at login: not stored by Portside. macOS keeps it (System Settings > General > Login Items).

## Build outputs and signing

The built app lives at `build/Portside.app` (ignored by git), the versioned release disk image at `build/dist/Portside-X.Y.Z.dmg`, and the installed copy at `~/Applications/Portside.app` after `scripts/build-app.sh --install`.

The local signing certificate and private key live in your default user keychain. Its fingerprint is stored at `~/Library/Application Support/com.james.portside/signing/identity.sha1`. Keep the same identity across rebuilds. Downloads and other macOS privacy decisions are managed by macOS, outside `dock.json`.
