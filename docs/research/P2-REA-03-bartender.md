# P2-REA-03 and P2-MENU-01: menu bar item discovery, activation, hide and reorder research

2026-11-08. [REA workflow](../REA_RESEARCH_2_0.md) · [Tickets](../IMPLEMENTATION_PLAN_2_0.md) · [Architecture](../ARCHITECTURE_2_0.md) · [Test matrix T-15](../TEST_MATRIX_2_0.md)

Research only. No Swift source changed, no dependency added. No code, assets or binaries from the reference are reproduced here. Probe scripts lived in `/tmp/p2rea03` and are not committed.

## Report header

```text
Question and planning ID:   P2-REA-03 + P2-MENU-01. How are menu bar items identified, activated,
                            hidden, revealed, reordered and restored, which steps need private APIs,
                            and what may Portside promise?
Reference app / version:    Bartender 7, bundle com.surteesstudios.Bartender, 7.1.0 (build 700013),
                            LSUIElement, hardened runtime, TeamIdentifier 24J875RH8J, LSMinimumSystemVersion 14.0
OS / architecture:          macOS 27.0.1 (26A434), arm64, notched 1728x1117 display, one display.
                            Binary is universal (x86_64, arm64).
Artifact SHA-256:           executable "Bartender 7" febad19b0bae13b55bd3e814fa5f416e4f5546a8a3929e8e48609ecf5328e3ea
                            (Info.plist hash is in REA_RESEARCH_2_0.md)
REA provider version:       Not used. See Limitations.
Scenario / boundary:        (1) Bartender: plist, signature, entitlements, `nm -u`, `strings` only. It was
                            already running; it was NOT driven, reconfigured or quit. (2) Read-only AX
                            enumeration of every running app's AXExtrasMenuBar. (3) A Portside-owned
                            disposable NSStatusItem fixture: AXPress, isVisible off/on, length change.
                            No third-party item was pressed, moved or hidden. No other app's preferences
                            were read or written.
Evidence:                   Commands and outputs under "Observed". No REA evidence ID exists.
```

## Observed (first-hand, this Mac)

| ID | Observation | Source |
| --- | --- | --- |
| O1 | The probe host already had Accessibility and Screen Recording (`AXIsProcessTrusted` and `CGPreflightScreenCaptureAccess` both true). Denied behavior was not run. | swift script |
| O2 | Reading `AXExtrasMenuBar` of each running app found 24 items in 18 apps. Each ordinary third-party item is one `AXMenuBarItem`, subrole `AXMenuExtra`, action `AXPress`. `AXIdentifier` was set on 2 of 24 (`GoldenGateBar`, `statusBar.icon.idle`); the rest had none. | `ax.swift` |
| O3 | `com.apple.systemuiserver` exposed 2 `AXMenuExtra` items with `AXPress` and `AXCancel`. `com.apple.MenuBarAgent` exposed 6 `AXGroup` / `AXHostingView` children with **no actions**. System items are therefore only partly discoverable, and six are not activatable through AX. | `ax.swift` |
| O4 | `AXPosition` was **not settable** on any item (`AXUIElementIsAttributeSettable` false). AX gives no way to move an item. | `ax.swift` |
| O5 | Reported frames were inconsistent. Four items reported `y=4` and sensible x. Nine reported `y=-319/-320` (off screen). Six `AXGroup` entries reported `y=0`. Five more, including my fresh fixture, reported `x=-1 y=1105` or `x=7 y=1105`, below a 1117 pt tall screen. With Bartender active and the bar crowded, AX frames do not tell whether an item is visible. Hypothesis: the off-screen and bottom values are items that Bartender or the system parked or clipped. Not proven. | `ax.swift`, `obs.swift` |
| O6 | `NSScreen` on this Mac: notch, `safeAreaInsets.top` 32, left area 0 to 771.5, right area 956.5 to 1728. Items overlapping 771.5 to 956.5 cannot be drawn. | `wl.swift` |
| O7 | `CGWindowListCopyWindowInfo` at layer 25 returned only 3 windows, all Bartender's. Third-party status items are **not** visible as per-item layer-25 windows. A window-list approach cannot enumerate or position them. | `wl.swift` |
| O8 | Fixture lifecycle (owned `NSStatusItem`, title `PSFIX`): present in the owner's `AXExtrasMenuBar` from launch; `AXPress` returned success (0) and the button action ran (`clicked 1`); `isVisible = false` removed it from the AX tree within 0.5 s; `isVisible = true` restored it within 0.5 s; `length = 80` changed the AX width from 58 to 82. All of this is the **owner** using public `NSStatusItem` API on its own item. | `fixture.swift`, `obs.swift` |
| O9 | The fixture exited cleanly and its item disappeared with its process. No residue was seen. | `fix.log`, `ax.swift` |

## Findings from the Bartender artifact (static only)

| ID | Finding | Evidence | Confidence |
| --- | --- | --- | --- |
| F1 | Imports include `AXUIElementCopyAttributeValue(s)`, `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `AXObserverCreate*` / `AddNotification`, `AXUIElementCopyElementAtPosition`. Strings say it "uses Accessibility to identify and move menu bar items on macOS Tahoe" and read `AXExtrasMenuBar` and `AXMenuBarItemMetadata`. Discovery by AX is consistent with O2. | `nm -u`, `strings` | High (that it uses AX) |
| F2 | It also imports `CGEventCreateMouseEvent`, `CGEventPost`, `CGEventPostToPid`, `CGEventSetLocation`, `CGEventSourceButtonState`, `CGDisplayHideCursor`. Strings include "Cannot move item while mouse button is down", "Could not find the menu bar separator needed to move this item", and error codes `BT01` to `BT08` "Unable to move this item". **Inferred:** moving an item is done by posting synthetic mouse events (a command-drag) across a separator status item, not by an AX or documented API. AX position is read-only (O4). | `nm -u`, `strings` | Medium (inferred, no call path read) |
| F3 | It imports private-looking CoreGraphics Server symbols: `CGSSetWindowTags`, `CGSClearWindowTags`, `CGSGetProcessMenuBarWindowList`, `CGSCopyActiveMenuBarDisplayIdentifier`, `CGSCopyManagedDisplaySpaces`, `CGSGetWindowList`, `CGSGetScreenRectForWindow`, `CGSSetConnectionProperty`, and names SkyLight and a `SkyLightMenuBarEventPoster`. These are undocumented. What exactly each call does was not traced. | `nm -u`, `strings` | High (that they are imported), Low (what they achieve) |
| F4 | It uses `CGWindowListCreateImage*` and `ScreenCaptureKit` (`SettledFrameCapture`). Strings: "Hidden items are briefly revealed beneath a cover, captured, and hidden again", and "Manage your menu bar without granting Screen Recording" as an alternative mode. Item pictures are screenshots; Screen Recording is optional for it. | `nm -u`, `strings` | Medium |
| F5 | Hiding is built from its own status items, named `GoldenGateBar` (O2 identifier) with a toggle target and "separator", "spacer", "Always Hidden" and "Hidden" groups. Strings mention `NSStatusItem Preferred Position Item-N` keys. **Inferred:** a classic separator-item technique (an item whose length grows to push others off screen), combined with synthetic drags to place items on either side. Not read from code. | `strings` | Medium |
| F6 | Notch handling is explicit: "A solid black background around the notch", a notch "shelf", options for screens without a notch. It also snapshots and restores its own configuration (keeps the newest 10) and states it "only moves your items when you tell it to". | `strings` | Medium |
| F7 | Entitlements: application-groups, apple-events, files bookmarks, calendars and others. No App Sandbox entitlement was listed in the portion read. It runs as a normal hardened-runtime Developer ID app. | `codesign -d --entitlements` | Medium |

## API classification (per behavior)

| Behavior | Route | Class | Evidence |
| --- | --- | --- | --- |
| Discover Portside's **own** items | `NSStatusItem` | Public | O8 |
| Discover **other apps'** items (title, role, count) | `AXUIElementCreateApplication` + `AXExtrasMenuBar` + `AXChildren` | Public API, **undocumented tree shape** | O2, O3, F1 |
| Identify an item stably | `AXIdentifier` only on some items; otherwise bundle ID + order | Undocumented / unreliable | O2 |
| Position / visibility of other apps' items | AX frame | Unreliable | O5, O7 |
| Activate another app's item | `AXPress` on `AXMenuExtra` | Public API, undocumented shape; per item | O2 (18 of 24 expose it), O3 (6 groups do not) |
| Hide **own** item | `NSStatusItem.isVisible` | Public | O8 |
| Hide **others'** items | Separator-item length trick plus moves | Public pieces, relies on reorder below | F5 |
| Reorder / move others' items | Synthetic mouse events and likely CGS/SkyLight window tags | **Private / unsupported** | O4, F2, F3 |
| Restore after crash or quit | macOS restores its own default positions; any hide state held by a third party dies with it. For items already moved, restoration is by the same synthetic move | Unproven | not run |
| Item thumbnails | Screen Recording + capture | Public API, permission-gated | F4 |

## Decision

**P2-MENU-01 result: LIMITED GO for discovery and activation; NO-GO (not proven) for hide and reorder.**

| Capability | Decision |
| --- | --- |
| Search observed items (title, owner, subrole) | Go, `limited`: only `AXMenuExtra` items; `MenuBarAgent` hosting groups and unidentified items listed as "native only" |
| Activate an item | Go for items that expose `AXPress` (O2), failure falls back to "use the menu bar" copy. No hover-to-open |
| Show position / hidden state | No-go. Frames are unreliable (O5) and layer-25 windows do not exist (O7). Do not draw "where it is" |
| Hide / reveal shelf (MENU-03) | No-go until a recovery path is proven. No public API moves another app's item (O4). Behind affirmative gate |
| Reorder (MENU-04) | No-go. Requires synthetic input or private calls (F2, F3) |
| Own Portside items | Stay public (`NSStatusItem`), already used by Command Center |
| Retain Bartender alongside | Yes. If it is running, Portside's activation should still work and must not move items |

This is not a parity claim. The hide and reorder rows are no-go for **lack of evidence**, not proof of impossibility; the Bartender mechanism was inferred from imports and strings, which the ticket rules call insufficient to assert behavior.

## Portside contract (for MENU-02)

- Source: a read-only `MenuBarItemSource` protocol with a live AX implementation and a fixture source for tests, mirroring `ListenerSource`.
- Enumeration is on demand (palette opens, explicit refresh), never a polling timer, and never in the reveal/hide path (AGENTS.md rule 4). Each AX call uses a short messaging timeout (probe used 0.5 s) and runs off the main actor; one unresponsive app must not stall the list.
- Item model: owner bundle ID and PID, title (may be empty), subrole, whether `AXPress` exists, identifier if any, and `activation: .press | .unsupported(reason)`. Unknown fields stay `nil`. Never store position as truth.
- States distinct in UI: `ready`, `accessibilityDenied`, `appUnresponsive`, `unsupportedItem`, `empty`. Denied is not "no items".
- Permission: Accessibility through the existing `PermissionGate` (CORE-03). No prompt at launch. No Screen Recording for MENU-02, so no thumbnails.
- No writes: do not set any AX attribute or touch another app's preferences or `com.apple.controlcenter` / MenuBarAgent defaults (AGENTS.md rule 7).
- Activation (revised during MENU-02, see Addendum): re-resolve the element immediately before pressing; if it no longer matches, report stale and press nothing. Click when a hit test returns exactly this element, otherwise `AXPress`.

## Acceptance fixture and next ticket

- **MENU-02 fixtures:** the 24-item enumeration shape (counts only, redacted), items with and without `AXIdentifier`, `AXGroup`-only owner (MenuBarAgent), an owner that times out, AX denied, and the owned `PSFIX`-style fixture for press, hide and reappear.
- **Dependent ticket:** P2-MENU-02. MENU-03 and MENU-04 remain behind the affirmative gates in the plan and are not started.

## Limitations

- **REA not used.** No decompilation or call-path trace was read. F2, F3 and F5 are inferred from imports and strings and may be wrong, or stale code. No claim is made about what Bartender does at runtime.
- **Bartender was not driven.** No hide, reveal, move or restore was observed. The restore-after-crash row is untested for lack of a safe disposable scenario.
- **Single Mac, single display, macOS 27.0.1.** macOS 26 (the deployment floor) was not run. No external display, no second Space layout, no menu bar auto-hide, no non-notched screen.
- **Permission denied path not run.** The probe host already held Accessibility and Screen Recording.
- **Frame anomaly unexplained (O5).** Whether the off-screen and y=1105 values mean "hidden by Bartender", "clipped by the notch" or "AX has no frame" was not isolated. This was observed while Bartender was running; the bare-system case was not tested.
- **System items:** only 2 `systemuiserver` and 6 `MenuBarAgent` entries were read. Clock, Control Center and Siri entries were not mapped to them.
- **Same-app multiple items** were not tested beyond the MenuBarAgent group list.

## Addendum (MENU-02 hand report, 2026-11-08)

`AXPress` success does not prove an item opened. O8 covered only a target/action `NSStatusItem`, and this report's "go for items that expose `AXPress`" was too broad. Measured by the owner's on-screen windows: PortKiller and an owned SwiftUI `.window` `MenuBarExtra` return success in about 100 ms and open nothing; a real `NSMenu` item opens and holds the reply until the timeout (-25204). A real HID click at the item opens PortKiller. `postToPid`, with or without window IDs, did not, and `AXSelected` is not settable. Hit testing with `AXUIElementCopyElementAtPosition` returned the exact element for 9 of 17 items; the other 8 reported a menu bar frame with something else at that point. This supports the F2 inference that synthetic input is needed for some items, but only for opening. Moving and hiding remain no-go.
