<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="design/brand/wordmarks/portside-horizontal-dark.png">
    <img src="design/brand/wordmarks/portside-horizontal-light.png" alt="Portside" width="440">
  </picture>
</p>

<p align="center"><b>A dock that's already there when you reach for it.</b></p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-10283F?logo=apple&logoColor=white" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Swift-5.10%2B-F06A42?logo=swift&logoColor=white" alt="Swift 5.10 or later">
</p>

# Portside

A fast, event-driven dock replacement for macOS, written in Swift (SwiftUI and AppKit) and built with SwiftPM. Touch the edge and it starts sliding in within a frame. Move away and it gets out of the way. No polling, no focus stealing, no lag.

Personal project for Apple Silicon. Builds a locally signed `.app`; not meant for general distribution. Brand assets and the two-page [brand guide](design/brand/presentation/portside-approved-identity-v2.pdf) live in [`design/brand/`](design/brand/README.md).

## Features

- **Reveal:** event-driven edge tracking, non-activating panel, slide animation, multi-display, file-drag reveal, notification badges, windows fit clear of the pinned dock (Accessibility)
- **Apps:** pin, reorder, drag-out remove, Finder drops, running apps, recent apps, indicator and hidden-app options, Open at Login, native modifier clicks, launch bounce
- **Activity icons:** camera (green), microphone (orange), playing audio (animated wave), working (CPU-based, per app)
- **Layout:** Bottom / Left / Right, live icon size and gap, magnification with shelf
- **Widgets:** Clock, Battery, Calendar, Weather, System Stats, CPU, Memory, Now Playing, Agents, AI Usage (Small / Wide / Extra Wide on the bottom dock)
- **Groups and stacks:** app groups with grids and optional custom icons (SF Symbol + palette color); folder stacks (grid / native-style fan / list) with FSEvents, drag items out to any app; Trash tile
- **Appearance:** match macOS icon style or Original; Liquid Glass / Frosted / Solid (color or gradient) background, each with its own strength; one color picker everywhere (Brand, Neutrals, macOS and RGB presets, hex, hue, saturation, tint, shade, opacity)
- **Native Dock:** hide via autohide-delay (save/restore), import apps and folders, open at login via `SMAppService`, optional Settings on launch
- **Settings:** sidebar panes, live apply, global hotkey (default ⌘⇧D), Check for Updates (Install Update with a quit-and-install confirmation, in-place from the GitHub release DMG)

Full detail: [docs/FEATURES.md](docs/FEATURES.md).

## Planned

From [docs/CHECKLIST.md](docs/CHECKLIST.md) remaining backlog:

- Hand-check Calendar consent and Downloads permission retention in the signed app
- Import plain file tiles from `persistent-others` (folders already import)
- Window list in the app menu; VoiceOver / keyboard navigation
- Side-dock widget layout; window previews; profiles; Trash Option-click Empty

## Quick start

```
source scripts/swift-env.sh
swift build
scripts/setup-signing.sh           # once
scripts/build-app.sh --install
open ~/Applications/Portside.app
```

Logs: `log stream --level info --predicate 'subsystem == "com.james.portside"'`

Restore the native Dock without UI: `swift run portside --restore-dock`

Full build, signing, DMG, and release steps: [docs/BUILD.md](docs/BUILD.md).

## Docs

| Doc | What |
| --- | --- |
| [FEATURES.md](docs/FEATURES.md) | Full feature list |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | How it works, private-API notes, project layout |
| [BUILD.md](docs/BUILD.md) | Requirements, SPM, `.app`, signing, versioning |
| [DATA.md](docs/DATA.md) | `dock.json`, backups, signing identity paths |
| [PLAN.md](docs/PLAN.md) | Original milestones A–F |
| [CHECKLIST.md](docs/CHECKLIST.md) | Status, findings, backlog |
| [Brand](design/brand/README.md) | Sail identity, wordmarks, tokens |
