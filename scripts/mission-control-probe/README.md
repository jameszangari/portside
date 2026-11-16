# Mission Control and App Exposé probe

Standalone SwiftPM executable. It never starts Portside, changes Dock preferences,
restarts the Dock, or changes another app's windows. No polling or screen capture.

From the repository root:

```sh
bash scripts/mission-control-probe/run.sh
```

Three opaque, click-through panels sit across the bottom center of each display:
blue at status-bar level, orange at popup-menu level, purple at screen-saver level.
They do not take keyboard focus. This tests a bottom Dock; it does not automatically
cover a left/right Dock or the full width/height of a large Dock. These are visual
markers, not a finished native-Dock hiding feature.

1. Confirm the three panels appear on the ordinary desktop.
2. Enter Mission Control, then exit and enter App Exposé for an app with windows.
   For each mode, note which colors remain above the native Dock, whether icons
   draw over them, and whether panels get moved into the window overview.
3. Check the terminal for `RECEIVED AXExpose...` on entry and exit. A subscription
   returning `0` only means accepted. It does not prove events were delivered.
4. For window-order metadata while the mode is open, use **MC Probe > Log window
   order in 3 seconds**, then enter the mode. One sample also runs 10 seconds after
   launch. Logs include only probe, Dock and WindowManager geometry, never window
   titles. Window ordering alone does not prove pixels cover the Dock.
5. Stop with **MC Probe > Quit probe** or Ctrl+C. It also exits after 180 seconds.
   Use `--duration 600` for more time.

The default keeps panels visible even if no AX events arrive, so the two tests
are independent. With `--events-only`, panels start hidden, show on either Exposé
entry notification and hide on exit or Show Desktop. Launch that mode before the
gesture: there is no initial query of the current Exposé state. A missed exit can
leave panels visible until you toggle them, quit, or reach the deadline.

The probe prints Accessibility trust and subscription errors. Portside's existing
grant does not imply this executable is trusted. If needed, grant the launching
terminal or probe in System Settings > Privacy & Security > Accessibility, then
use **Retry Accessibility subscriptions** or relaunch. Without access, the visible
panel test still works. The probe does not prompt or alter permission settings.

The four notification names are undocumented strings passed to public AX APIs in
`DockNotifications.swift`. Unsupported subscriptions are logged and leave the
window test available. The startup public-AX capability check briefly subscribes
and unsubscribes WindowManager notifications; it is not a second event listener.
[AltTab's MissionControl.swift](https://github.com/lwouis/alt-tab-macos/blob/master/src/macos/api-wrappers/MissionControl.swift)
reports accepted but silent subscriptions on macOS 27 (consulted 2026-11-16).
On 2026-11-16 the maintainer confirmed all three colors remained visible over the
native Dock in both Mission Control and App Exposé on macOS 27.0.1 (26A434). Their
23-second run accepted all four subscriptions and delivered zero AX events.
WindowManager's public `AXWindowCreated` subscription returned -25207 (unsupported)
in a follow-up capability check; its AX windows list was empty on the desktop.
Even successful coverage here would still need production design for Dock bounds,
display placement, event delivery, focus, clicks and missed-exit recovery.

## Event-driven detection experiment

```sh
bash scripts/mission-control-probe/run.sh --detect
```

Panels start hidden. Enter and exit Mission Control, then App Exposé. Expect
`OVERLAY ACTIVE source=window event` and the colors on entry, followed by
`OVERLAY INACTIVE source=window event` and no colors on exit. Repeat each gesture;
also try canceling a partial trackpad gesture and switching Spaces. Do not use
**Toggle test panels** during this check, because it overrides their visibility.
The delayed window-order samples only log metadata and cannot drive detection.

This mode dynamically loads three private SkyLight symbols in
`WindowServerNotifications.swift`: `SLSMainConnectionID`,
`SLSRegisterConnectionNotifyProc` and `SLSRequestNotificationsForWindows`.
Missing symbols or failed subscriptions log an unavailable result; the default
visual probe remains usable. Notification IDs are experimental: 811/804 for
creation/destruction, 815/816 for ordering and 1325/1326 for Space membership.
The AppKit connection is left on its existing delivery queue. Callbacks only
coalesce a window-event burst into one main-thread read after 50 ms; no repeating
timer or idle polling is installed. Probe windows seed delivery, and Dock and
WindowManager windows are subscribed as they are discovered. The process-lifetime
callback storage stays valid through exit; process termination releases the
connection and subscriptions.

Each read checks public window metadata for an on-screen WindowManager surface
at level 19 covering a display, including its position. This distinguishes the
observed Exposé shield from small Stage Manager surfaces, desktop windows and
off-screen retained windows, without reading titles or recording the screen.
The same shield is expected in both modes. Its level and geometry are heuristics,
not an OS contract. The probe shows panels on every display when any shield is
detected, and does not yet implement per-display Dock coverage. Missing exit
events could leave panels visible until another window event, toggling or quitting.
Successful subscriptions still do not prove entry/exit delivery.

## Dock cover and click experiment

```sh
bash scripts/mission-control-probe/run.sh --cover
# options: --margin 0...64 (12), --level 20...2000 (25), --exit-delay 0...2 (0.35 s),
#          --label-clearance 0...120 (40 pt; 0 disables), --grow hover|always (hover)
```

Uses the `--detect` entry/exit events, but instead of three test colors shows one
teal, clickable, non-activating panel per display, sized to the native Dock.
On entry it reads the Dock's `AXList` frame through public Accessibility, once,
then once more 0.4 s later after the Dock's slide-in; no repeating timer. A Dock
still past the screen edge on the first read is placed at its settled position,
so the panel starts at full Dock height; the second read adds the gap above the
edge. The cover grows by the margin on the open sides and stays flush to the edge.
Without Accessibility it falls back to the strip the Dock reserves, or a 100 pt
bottom strip when the Dock reserves none (autohide).

1. In Mission Control and App Exposé, check that no part of the native Dock,
   including its rounded ends and shadow, shows around the teal panel.
2. Click and right-click the panel. Expect `CLICK left|right ... probeActive=false
   frontmost=<previous app>` and no app launch or Dock menu: clicks go to the
   panel, not the native Dock, and the probe does not take focus.
3. Note whether Mission Control stays open after a click, and whether window
   thumbnails under the panel can still be clicked above it.

On 2026-11-16 an automated Mission Control entry on macOS 27.0.1 read the Dock
at y=-39 on entry and y=10 after 0.4 s, laid the cover at 1126 × 60 then 1126 × 70,
and hid it on exit; a screenshot showed no native Dock edge around the panel.
Clicks were not tested. A maintainer run the same day caught two entry/exit
cycles; all 15 clicks (one right) reached the panel with `probeActive=false`,
the frontmost app unchanged and the overlay still active, so none reached the
native Dock or closed Mission Control. It worked in both Mission Control and
App Exposé, and no Dock icon showed on entry. Two leaks remained: the Dock's
hover labels drew above the level 25 panel, and icons flashed on exit because the
panel hid on the exit event while the Dock was still sliding out. The panel now
hides one bounded delay after exit (`--exit-delay`, canceled by a new entry);
`--level` tests higher window levels against the labels. To log the label's
window level, pick **Log window order in 3 seconds**, enter the mode and hover
a Dock icon until the sample prints.

A hover sample at level 25 found no separate label window: the Dock owns only
its full-screen layer-20 window, so labels draw there, just past the panel's
open edge, and no window level can cover them. Clicks never reach the Dock, but
it still tracks the pointer. While the pointer is over the panel, one tracking
area grows it toward the screen center by `--label-clearance` and shrinks it on
exit (`HOVER enter/exit` in the log). The grown strip also hides that part of
the window overview. The maintainer saw labels hidden but flash for a split
second on first hover: the Dock draws the label on the same frame the pointer
reaches an icon, so a hover-driven resize lags it. `--grow always` keeps the
cover grown for the whole mode, with no flash, at the cost of always hiding that
strip of the overview.

Trackpad entry is detected later than keyboard entry: the maintainer's swipes
were caught with the Dock at y=-30 to -32 (16 to 18 pt visible), keyboard entry
at -39 to -44. Detection reads at once on the first window event of a burst and
again 50 ms later (`source=window event` / `source=settle`). Set `PROBE_TRACE=1`
to log the level-19 WindowManager surfaces each read sees; on entry the first
read finds none, so the settle read is the earliest that can match. Slowing the Dock with
`autohide-time-modifier` 4.0 did not change the entry position (-39 / -36):
Mission Control and App Exposé ignore it.

Window events carry the window number in their first four bytes (observed, not
documented). The public `CGWindowListCreateDescriptionFromArray` knows nothing
about a window at creation or order-in, but SkyLight does: on `815` (order-in)
the probe reads the window's owner, level and bounds through
`SLSGetWindowOwner`, `SLSConnectionGetPID`, `SLSGetWindowLevel` and
`SLSGetWindowBounds`, and a WindowManager level-19 display-sized window publishes
`OVERLAY ACTIVE source=order-in` at once. A list read that disagrees within
0.15 s is ignored, since the list lags. On creation (`811`) the shield is still
level 0 and size 0, so it cannot be classified that early. Automated runs caught
Mission Control with the Dock at y=-48 (fully hidden) and App Exposé at -44 / -46,
versus -36 to -39 before. With `PROBE_TRACE=1` each event logs these direct reads.

The pure signature tests replay the supplied window geometry and reject ordinary
desktop, small, hidden and wrong-display surfaces. Cover tests check bottom and
side Docks, a Dock sliding in, other displays and the fallback strip:

```sh
source scripts/swift-env.sh
CFFIXED_USER_HOME=/tmp/portside-probe-tests swift test --package-path scripts/mission-control-probe
```
