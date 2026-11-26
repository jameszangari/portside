# Mission Control and App Exposé: covering the native Dock

2026-11-16. [Probe README](https://github.com/jameszangari/portside/blob/archive/mission-control-probe/scripts/mission-control-probe/README.md) · Shipped part: [PR #79](https://github.com/jameszangari/portside/pull/79)

Research only. The probe is a separate SwiftPM package in `scripts/mission-control-probe`, never linked into Portside, kept under the tag `archive/mission-control-probe` (`git checkout archive/mission-control-probe` to run it). One maintainer-approved Dock preference test changed `autohide-time-modifier` and restored it; nothing else in `com.apple.dock` was written.

## Header

```text
Question:        "Hide the macOS Dock" (autohide-delay) does not stop Mission Control and App
                 Exposé from showing the native Dock. Can Portside detect those modes and cover
                 the native Dock while they are open?
OS / hardware:   macOS 27.0.1 (26A434), arm64, one 1728x1117 display. No second display,
                 no left or right Dock, macOS 26 not run.
Boundary:        Probe windows only. Dock and WindowManager windows read as metadata (owner,
                 level, bounds), never titles or pixels except maintainer-approved screenshots.
Entry methods:   Maintainer: trackpad gestures. Automated: open -a "Mission Control", Ctrl+Down
                 and Esc through System Events.
```

## Outcome

- Detection works, event driven, through private SkyLight window events. Shipped in PR #79 as `MissionControlMonitor.swift`, which hides Portside's own dock during both modes.
- Covering the native Dock works for clicks, labels and exit, but trackpad entry can still show a few points of the Dock for one or two frames before the cover appears. Deferred.

## Detection

| Signal | Result |
|---|---|
| Dock `AXExpose*` notifications (`AXExposeShowAllWindows`, `ShowFrontWindows`, `ShowDesktop`, `Exit`) | Subscriptions accepted (0), zero events delivered across every run |
| WindowManager public AX (`AXWindows`, `AXWindowCreated`) | Windows list empty; `AXWindowCreated` returns -25207 (unsupported) |
| SkyLight window events 811/804/815/816/1325/1326 + public window list | Works. Both modes add a WindowManager window at level 19 covering the display ("shield"); it goes off screen, then is destroyed, on exit |
| Same, list read immediately on the first event | No gain: the shield is not in the list yet (`wm19=[]`); it appears on the 50 ms settle read |
| Window number from event data + `SLSGetWindowOwner` / `SLSConnectionGetPID` / `SLSGetWindowLevel` / `SLSGetWindowBounds` on order-in (815) | Best. Classifies the shield about 24 to 50 ms before the public list. At creation (811) it is still level 0, size 0, so creation cannot be used |

Event data starts with the window number for window events (4 bytes); Space events carry 12 bytes. Registration needs at least one of the process's own window numbers passed to `SLSRequestNotificationsForWindows` before anything arrives. No timer runs while nothing changes; a burst gets one immediate and one 50 ms settle read.

Native Dock position when detection fired (y of its AX list frame, Cocoa coordinates, height 48, fully hidden at -48, settled at 10):

| Entry | List read | Order-in |
|---|---|---|
| Mission Control, `open -a` | -36 to -39 | -48 |
| App Exposé, Ctrl+Down | -39 to -44 | -44 / -46 |
| Trackpad (maintainer) | -30 to -32 | not yet hand tested |

## Covering the Dock

`--cover` shows one opaque, clickable, non-activating panel per display, sized from the Dock's public `AXList` frame read on entry and once more 0.4 s later, grown by a 12 pt margin and flush to the edge.

| Finding | Detail |
|---|---|
| Window level | Level 25 already draws above the Dock (layer 20) and the shield (19). 101 and 1000 change nothing |
| Clicks | All 15 maintainer clicks (one right) reached the panel; the probe never activated, the frontmost app kept focus, Mission Control stayed open. Nothing reaches the native Dock |
| Sliding in | The first read on entry sees the Dock still off screen (y -26 to -44). The cover uses its settled size so it is full height from the first frame; the second read adds the 10 pt gap |
| Hover labels | Still visible above the cover at every level. The Dock owns no label window: labels draw in its full-screen layer-20 window just past the cover's top edge. Growing the cover 40 pt on hover hides them but a label flashes for a frame on first hover; `--grow always` (grown for the whole mode) removes the flash, at the cost of covering a 40 pt strip of the overview |
| Exit | Icons flashed because the exit event arrives while the Dock slides out. Hiding 0.35 s after exit fixed it |
| Slower slide | `autohide-time-modifier` 4.0 had no effect on the entry position (-39 / -36). Mission Control and App Exposé ignore it. Key was unset before, deleted after; exported domain matched the backup |
| Trackpad entry | With list-based detection, 16 to 18 pt of the Dock showed before the cover. Order-in detection should reduce that; not yet hand tested |

## Open questions

- Trackpad entry with order-in detection: does any Dock still show?
- Left and right Docks, a second display, Stage Manager, partial or canceled gestures, Space switches.
- Whether a Portside-styled cover (the dock bar itself) makes the 40 pt label strip acceptable.
- Whether the level-19 shield holds on macOS 26 and later releases.

## Next steps if revisited

1. Hand test trackpad entry with `--cover --grow always` and record `COVER pass=1` y.
2. If acceptable, draw Portside's own dock (or its background) as the cover during the overview instead of hiding it, sized from the Dock's AX frame plus label clearance.
3. Keep the exit delay, and the order-in detector from PR #79.
