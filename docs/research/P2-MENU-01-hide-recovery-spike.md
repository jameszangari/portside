# P2-MENU-01 follow-up: hide, move and recovery spike

2026-11-08. [REA-03 report](P2-REA-03-bartender.md) · [Tickets](../IMPLEMENTATION_PLAN_2_0.md) · [Test matrix T-15](../TEST_MATRIX_2_0.md)

Research only. No Swift source in the app changed. Probe scripts lived in `/tmp/p2spike` and are not committed. Bartender was quit for the run (with the owner's approval) and relaunched at the end; none of its settings were read or changed.

## Header

```text
Question:        Can Portside hide and restore menu bar items safely, and by which public routes?
OS / hardware:   macOS 27.0.1 (26A434), arm64, one notched 1728x1117 display. macOS 26 not run.
Boundary:        Owned NSStatusItem fixtures for hide, reveal and crash recovery. One third-party
                 item (Scroll Reverser, owner-approved) moved one slot and back with a synthetic
                 Cmd-drag. No other third-party item was moved, hidden or pressed.
Measurement:     Every other app's AXExtrasMenuBar frames, plus an AXUIElementCopyElementAtPosition
                 hit test per item ("reachable" means the element at its center is that item).
```

## Observed

| ID | Observation |
| --- | --- |
| O1 | With Bartender quit, 16 menu extras exist. 10 are reachable (x 1053 and right). 6 are clipped at or left of the notch edge and pile up at x 959 to 974 (Stats, UA Connect, Ollama, SystemUIServer twice, Tailscale). The bar is already over full. |
| O2 | Any new `NSStatusItem` (3 at 47 pt, then single items at 42, 30 and 22 pt) lands leftmost and is clipped, because there is no room. With Bartender running they were off screen (x -1, y 1105). |
| O3 | Placing an own item with the app's own default `NSStatusItem Preferred Position <autosaveName>` works. Values 100 and 400 put the item at x 1527 and 1175, reachable; 700 landed in the clipped zone. The key is written to the app's own defaults only. The key name is undocumented (found in Bartender's strings). |
| O4 | **Hide works.** A separator item of mine at length 24 pushed everything to its left about 40 pt left. At length 120 it pushed Raycast, Shottr, Malwarebytes Agent, UA Mixer Engine and others to x 983 to 986, unreachable (unreachable count 6 to 10). Items to its right did not move. |
| O5 | **Reveal works.** Setting the separator length from 120 to 24 made Raycast reachable again (x 1097) and back to 120 hid it again. `NSStatusItem.length` is public API. |
| O6 | Lengths 220 and 320 put the separator itself in the clipped zone (unreachable) while still pushing items left; length 1200 hid nothing because the item did not fit and clipped itself. The classic "make it huge" trick does not work here. The usable width is bounded by the room the bar has. |
| O7 | **Recovery on quit and on SIGKILL.** After the separator exited normally, and after `kill -9` with the hide active, the bar returned to the baseline (16 items, same 6 unreachable, same x values) within 0.3 s. Nothing persisted outside the process. |
| O8 | **Reorder works for a visible third-party item with public `CGEvent`.** A Cmd-drag (`mouseMoved`, `leftMouseDown` with `.maskCommand`, 24 `leftMouseDragged` steps, `leftMouseUp`, HID tap) moved Scroll Reverser from x 1277 to x 1239 (swapped with Rectangle). The reverse drag returned it to exactly x 1277 and the neighbors to x 1239 and 1307. Pointer was warped back afterward. |
| O9 | Items clipped under the notch cannot be grabbed (their frames overlap and the hit test fails), so they cannot be reordered directly. |

## API classification

| Behavior | Route | Class |
| --- | --- | --- |
| Hide a group | Own separator `NSStatusItem` with `length`, placed by the app's own `Preferred Position` default | Public API plus one undocumented default key, own defaults only |
| Reveal a group | `length` change on the same item | Public |
| Move a visible third-party item | Synthetic Cmd-drag through `CGEvent` | Public API, requires Accessibility (and posts input), per-item reliability unknown |
| Move a clipped item | None found (O9) | Not possible directly |
| Recover | Process exit removes the separator; no state outside Portside | Observed for quit and SIGKILL |

No private API (CGS, SkyLight) was needed for hide, reveal, move or recovery on this Mac.

## Decision

**P2-MENU-03 (reveal shelf): LIMITED GO for a prototype.** The two findings that blocked it are answered on this Mac: hide and reveal use public API, and recovery after quit and SIGKILL is clean (O4, O5, O7). Keep it off by default behind the affirmative gate and the kill switch.

**P2-MENU-04 (reorder): LIMITED GO to prototype, no promise.** A real drag moved one item and restored exactly (O8), but only one item of 10 was tried and clipped items cannot be moved (O9).

Not yet answered, so shipping stays gated:

- Bartender and Portside both running (they would fight over the same items). Not tested.
- Sleep, display unplug or change, logout, Space changes and full screen with a hide active. Not tested.
- A Portside crash while the user's own items have been moved by Cmd-drag (O7 covers the separator, not moved positions; macOS keeps the moved order, so "restore" would be a second drag or a saved order).
- Moved-item reliability across apps: SwiftUI `MenuBarExtra` items, system items, same-app multiples, items under a modal, fast repeated moves.
- Showing items that macOS already clipped under the notch (O1). A separator can only push items left, so freeing room means moving visible items to its left first, which needs reliable drags.
- macOS 26 and other displays.

## Acceptance fixtures for MENU-03

1. Hide then quit: baseline restored (O7 pattern), asserted by item count and reachable set.
2. Hide then SIGKILL: same.
3. Kill switch reachable while hidden: the own control stays visible (place it right of the separator).
4. Reveal then hide again repeatedly: no drift in baseline.
5. Notch and second display: no item ends unreachable after unplug.

## Limitations

- One Mac, one display, macOS 27.0.1; the layout is crowded and notched, which both helped (clipping is easy to see) and distorted results (O2).
- Reachability is an Accessibility hit test, not a screenshot comparison. One screenshot (Bartender quit) agreed with it.
- One real drag, one direction pair. Not a reliability rate.
- The separator timeline in O5 was sampled about every 1.7 s, so reveal latency under 1 s is not measured.
