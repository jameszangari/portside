# Thaw Simple Mode: how it manages the menu bar, and how Portside can replace it

**Audit correction (2026-11-09):** Implementation status below is historical and overstates parity. See [interaction audit](docs/research/P2-MENU-06-interaction-audit.md) for reproduced failures, fixes, missing behaviors and automated native evidence. Portside is not a 1:1 replacement.

Investigation of Thaw 3.0.0-alpha.13 on macOS 27.0.1, compared with Portside at 6bccda35. Thaw's behavior and Portside's proposed design are kept in separate parts.

Evidence labels:

- **[O]** observed at runtime or in preferences on this Mac
- **[C]** confirmed in matching source or the shipped binary
- **[I]** inference
- **[GAP]** could not be verified, with the reason

Citations: `T:` is a path in the Thaw tag. `P:` is a path in Portside under `Sources/portside/`. `PRK` is the closed `PlatformRuntimeKit.framework`.

## Read this first

1. **Thaw does not hide items by moving or widening anything on macOS 27.** It takes a private Apple assertion, `MBAssessmentModeAssertion`, with an allow-list of bundle IDs. Everything off the list disappears.
2. **Portside's hide mechanism is the one Thaw's own source says no longer works on macOS 27.** Widening a separator is what P2-MENU-03 does. My commit 1e3df2b4, which sizes the separator to the screen edge, doubles down on that approach and should be treated as a likely dead end.
3. **Two earlier conclusions of mine need correcting.** I said the dimmed apps in your Layout screenshots were "behind the notch". Thaw was running the whole time and its hidden list contains those same apps, so Thaw's assertion is a likely cause [I]. Your hide and reveal tests also ran with two menu bar managers active at once, so those results are contaminated.
4. **Section membership does not need drags.** With an assertion, moving an item to Hidden is a saved identity change plus a re-applied allow-list. No pointer interruption, and items that are not drawn can still be assigned.
5. **Decisions are needed from you before building** (next section).

## Decisions needed

| # | Decision | Why it matters | Recommendation |
|---|---|---|---|
| 1 | Accept this investigation against the roadmap | `docs/ROADMAP_2_0.md:49` says "no REA run against Thaw, no Thaw source read or copied (it is GPL-3.0)". You asked for this run, so it happened, but the rule still says otherwise. Portside is MIT. Thaw is GPL-3.0. | Update the roadmap to record the exception. Implement from Apple's API surface and this report's behavior description. Copy no Thaw code or text. Get legal advice if the clean-room position matters to you; this report is not legal advice. |
| 2 | Use a private Apple API for hiding | `AGENTS.md` rule 5 allows it only in its own file behind `dlopen`/`dlsym` with a graceful fallback, plus an ARCHITECTURE note. It can break in any macOS update. | Accept, conditional on the spike in step 1 of the plan. |
| 3 | Writing MenuBarAgent's position table | `AGENTS.md` rule 7: "Never touch other apps' preferences". The table belongs to MenuBarAgent. | Keep rule 7. Do not adopt table writes. Accept the Command-drag cost for explicit reorders only. |
| 4 | Start hidden at launch | P2-MENU-03 requires starting revealed every launch. Replacing Thaw for daily use needs a collapsed bar at login. | Allow it only if the spike proves the assertion dies with the process. |

## Baseline

| Item | Value |
|---|---|
| Thaw | `/Applications/Thaw.app`, `com.stonerl.Thaw`, 3.0.0-alpha.13, build 124, minimum macOS 27.0 |
| Signature | Developer ID Toni Foerster (456BPWQ6U5), signed 2026-11-05 |
| Thaw main binary | sha256 `92b0f5ace805c77f055c43698975e0a2bb4580800f3f3970bafda9016834cf5e`, arm64 |
| PRK binary | sha256 `3545d0c3494e2f102fdc29c7cbb749333d99160d1a9e906a51fe3968771b7918`, UUID D14DC180-E973-3C0F-BA73-E1D38B2A90DE |
| Matching source | Tag `3.0.0-alpha.13`, commit 92c959b, 2026-11-05, project file version 3.0.0-alpha.13 build 124, GPL-3.0 |
| macOS | 27.0.1 (26A434) |
| Portside | 6bccda35, branch `feat/p2-menu-06-triggers` |
| Running during analysis [O] | Thaw (pid 1242), ThawAXHelper, MenuBarCaptureService, MenuBarAgent. `SimpleMode = 1` |

### Coverage limits

- **Screenshot [GAP].** No Simple Mode screenshot was attached to the request. Expected behavior comes from `T:Thaw/Settings/SettingsPanes/SimpleModeSettingsPane.swift` instead.
- **REA decompilation [GAP].** REA `inspect_macho` worked (Evidence `ev_7cf2865a4a0bd39d728a76a1501578e8ac9e655d942cdb37d416129ec97fb06f`). REA's search and decompile tools returned `provider_unavailable`: Ghidra, Hopper, IDA and Kuna are not configured, and installing one needs your approval. PRK internals rest on exports, strings and targeted `otool -tV`.
- **Read-only.** Nothing was written to either app. No Thaw action was triggered and no private method was invoked. Runtime introspection listed Objective-C classes and selectors only.
- **Not exercised [GAP].** Toggling Thaw, notch overflow, external displays and third-party restarts were not run live. They are source-level only and marked below.

---

# Part 1: Thaw's behavior

## Pass 1: Simple Mode and shared settings

Simple Mode is a presentation mode. It is not a runtime mode or a preset.

- [C] `simpleMode` is a Bool in `GeneralSettings`, default false (`T:Thaw/System/Defaults.swift:226`), set true by onboarding (`T:Thaw/App/AppState.swift:327`). It selects `simpleModeScreen` and the window size (`T:Thaw/Settings/SettingsView.swift:35-38`).
- [C] The engine protocol exposes it (`T:Thaw/MenuBar/MenuBarEngineConfiguration.swift:43`), but a search of `MenuBar`, `ControlItem`, `Items/Manager` and `HIDEventManager` finds only the forwarder. The one other runtime effect is capture demand, meaning which previews refresh (`T:Thaw/Items/Capture/CaptureDemandRules.swift:68-75`).
- [C] Toggling it writes no other preference.

| Simple Mode control | Preference | Drives | Related to hiding |
|---|---|---|---|
| Item arrangement | `advanced.menuBarArrangementMode`, default Automatic | Position store choice, item manager | Layout only |
| Always Hidden section | `advanced.enableAlwaysHiddenSection`, default off | Section set, double-click gesture | Yes |
| Sections preview | `simpleModeShowsPreview` | `FoldedMenuBar`, capture demand | No, read-only view |
| Shortcut to show and hide | Hotkey `.toggleHiddenSection` | Same toggle as the icon | Yes |
| Check for updates | Sparkle | Updates | Incidental |

[C] Simple Mode inherits shared defaults it does not show: `showOnClick = true`, `autoRehide = true`, `rehideStrategy = .smart`, `rehideInterval = 15` (`T:Thaw/System/Defaults.swift:242-247`). [O] This Mac has no overrides for those keys.

## Pass 2: Discovery, identity, sections

- [C] "On macOS 27 the menu bar is drawn by Apple's MenuBarAgent, and items have no windows of their own to move" (`T:docs/ARCHITECTURE.md:151-153`).
- [O] Consistent with that: no window at status level (25) is listed on this Mac. Only Thaw and Window Server windows at layer 24, plus one Thaw window at layer 3.
- [C] **Discovery** runs in `ThawAXHelper`, a separate process, over a pipe. It reads MenuBarAgent's AX window. Each child is one drawn item, and the first descendant the agent does not own gives the owner's pid. "Hidden items are not in it" (`T:packages/ThawAX/Sources/ThawAXCore/MenuBarAgentWindow.swift:9-14,44-58`).
- [C] **Order** comes from the frames. A read containing a zero-size child is treated as mid-change and discarded (`settled`, same file :33-38).
- [C] **Identity** is `namespace:title[:instanceIndex]`, because "windowID changes across app restarts" (`T:packages/MenuBarModel/Sources/MenuBarModel/MenuBarItem.swift:238`, `MenuBarItemTag.swift:596-603`). [O] Stored examples: `com.bitwarden.desktop:Item-0`, `com.openai.codex:ChatGPT`.
- [C] **Sections are an identity map, not positions**: `sectionAssignment: [String: MenuBarSectionName]` (`T:packages/MenuBarModel/Sources/MenuBarModel/HidingStateProviding.swift:13`), owned by the closed `RuntimeSectionController` (PRK exports `setSection(_:identifier:)`, `setSectionOrder`, `applyProfileLayout`).
- [O] `MenuBarItemManager.savedSectionOrder` holds ordered ids. `hidden` has 13 apps and `visible` has 9, including Apple's items and Thaw's control.
- [C] **Dividers decide membership only after a ⌘-drag or in Manual mode.** `adoptObservedMembership` compares stored weights with divider weights and adopts the result "without moving items" (`T:Thaw/Items/Manager/MenuBarItemManager+ManualMembership.swift`).
- [C] **New Items.** The marker is `NewItemsPlacement{sectionKey, anchorIdentifier, relation}` (`T:packages/ThawLayout/Sources/ThawLayout/NewItemsPlacement.swift`). `NewIconArrivals.placements` puts an unseen icon in the one hidden section its app's other icons share. A new app's first icon follows the marker unless that is Visible. Capped at 3 placements per app per session (`T:Thaw/MenuBar/NewIconSectionFollower.swift:14-60`). The stated reason: macOS hides per app, so a new Visible icon would unhide the whole app.
- [C] **Preview data**: `FoldedMenuBar` reads the item cache plus the image cache. Without Screen Recording it shows app icons (`T:Thaw/Settings/SettingsPanes/SimpleModeSettingsPane.swift:59-71`).

## Pass 3: Hide and reveal

**The primitive** [C]. PRK's `_RuntimeBridgeActivate` loads `MBAssessmentModeConfiguration` and `MBAssessmentModeAssertion`, builds the configuration with `initWithAllowedSystemItems:allowedBundleIdentifiers:`, and calls `activateWithConfiguration:completionHandler:` (string references at PRK 0x14c294 to 0x14c2d0, called from 0x85f94). `_RuntimeBridgeInvalidate` sends `invalidate` (0x14c598). The framework is `/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore`.

- [O] Both classes and those selectors exist on 27.0.1.
- [C] Thaw has no private entitlement, only app-group and bookmark entitlements. [O] It hides on this Mac. [I] The assertion needs no private entitlement. [GAP] Whether a non-notarized `swift run` build can activate it. Not tested, because activating would disturb the running Thaw.
- [C] Granularity is per app: "macOS hides by app, so all of one app's items hide together" (`T:docs/ARCHITECTURE.md:157-158`).
- [C] Standard method side effect: macOS hides Focus, AirDrop, Now Playing, Fast User Switching, Live Activities and the camera indicator whenever any other item is hidden, and never hides Time Machine or Input (`T:FREQUENT_ISSUES.md:65`).

**Status item length is not the mechanism** [C]. "The system no longer reflows over-wide status items; an over-long divider just overflows the right edge and confuses section classification. So every shown item is content-sized, and concealing is collapseStatusItem(toWidth:)" (`T:Thaw/MenuBar/ControlItem/ControlItem.swift:1005-1008`). Dividers collapse to width 0 and stay registered so their positions remain readable (:1021-1026).

| Action | Path | Concrete operation |
|---|---|---|
| Launch | `desiredState = .hideSection`. PRK logs "cold-start conceal restore", "cold-start snapshot restore" | [C] Assertion from saved state. [GAP] exact order is closed |
| Click icon | `performPrimaryAction` -> `respondToClick` -> `.toggleSection` -> `MenuBarSection.toggle` (`ControlItem.swift:1324-1360`) | Assertion swap or release |
| Double-click | Intent `.showAlwaysHidden`/`.toggleAlwaysHidden`, only when Always Hidden is on. "MenuBarAgent can report clickCount=1 for both clicks", so Thaw times clicks itself (`ControlItem.swift:1395-1401`) | Same |
| Shortcut | `.toggleHiddenSection` -> same `toggle(triggeredByHotkey:)` | Same |
| Show | If items would not fit, open the Thaw Bar panel, else `sectionController.show` (`T:Thaw/MenuBar/MenuBarSection.swift:266-300`) | Then `startRehideChecks` |
| Hide | `sectionController.hideRevealedSections()` (`MenuBarSection.swift:336-351`) | Assertion applied |

Per toggle versus per layout change:

- Every toggle: restriction recomputed and swapped. [I] from PRK strings ("applying restriction: systemItems=", "allowedBundles=", "apply: suppressed re-composite", "superseding pending assertion; hasConfirmedFallback=", "retaining confirmed assertion"), which suggest a confirmed fallback is kept until the new one lands.
- Before a reveal, in Automatic mode: "Applies the saved order before the restriction is released, so the bar reveals straight into it without moving Thaw's click target" (`T:Thaw/Items/Manager/MenuBarItemManager+Moving.swift:694-696`).
- [I] Hide and reveal themselves need no synthetic input. Order restoration around a reveal is a separate pass that can write the table or, without the grant, drag.

## Pass 4: Manual and Automatic arrangement

**Manual, user holds ⌘ and drags.** [C] macOS performs the drag, not Thaw. Thaw only watches:

1. A press with ⌘ on a managed item records it (`notePressForItemDrag`, `T:Thaw/Input/Events/HIDEventManager+MenuBarItemDrag.swift:42-46`).
2. Optionally all sections show during the drag (`showAllSectionsOnUserDrag`).
3. At the end, `noteUserMenuBarDragEnded` waits 1.5 s because "macOS writes positions after the drop", then adopts membership (`T:Thaw/Items/Manager/MenuBarItemManager+ManualMembership.swift`).
4. A 4 s quiet period stops repairs from undoing the drop.

No synthetic input is involved.

**Automatic.** [C] Layout drops, profiles and saved order move real items. Reconciliation runs before a reveal (`applySavedOrderBeforeReveal`), on reveal (`synchronizeRevealedOrder`), for structure (`scheduleStructuralNormalization`) and at boundaries (`reconcileSectionBoundaries`). Two routes:

| Route | Requires | Effect |
|---|---|---|
| Position table write | Menu Bar Layout Access: the user picks `TrailingItemPreferredPositions`' file in an open panel, or Full Disk Access | "instantly and cursor-free" (`T:Thaw/System/Permissions/FullDiskAccessPermission.swift:12`). Then `requestMenuBarAgentPositionRefresh` and `waitForMenuBarAgentResort` (`...Moving.swift:2385-2440`) |
| Synthetic ⌘-drag | Accessibility | "synthetic drags, which hold physical mouse input" (`T:Thaw/Settings/Models/MenuBarArrangementMode.swift:10`). "Drags warp the cursor, so wait briefly for the hand to go idle" (`...Moving.swift:2010`). This is the temporary mouse interruption |

Failures and concurrency [C]:

- Serialized by `moveSerialSemaphore` with a `StoreWritePermit` (`...Moving.swift:197`), scheduled through `RepairLane`.
- Each move validated afterwards (`validateItemPositionAfterMove`).
- A `MoveCircuitBreaker` stops "icon dancing", with lengthening cooldowns that never block an explicit user move.
- Writes refused during user drags (`isUserArrangingMenuBar`) and while the screen is locked.
- External changes detected by `MenuBarAgentPreferencesWatcher`, with self-write echo suppression (PRK strings).

## Pass 5: Re-hide, persistence, edge cases

| Policy | Behavior [C] |
|---|---|
| Smart (default) | Each click outside the bar arms a task for `rehideInterval` (15 s). The newest click wins. Hides if the Space changed, or if the window under the cursor belongs to the active regular app or the Dock, and no menu is open (`T:Thaw/Input/Events/HIDEventManager+ShowOnClick.swift:399-470`). Also rehides on focus change |
| Timed | Global `mouseMoved` monitor at about 20 fps. The countdown runs only while the pointer is outside the bar (`T:Thaw/MenuBar/MenuBarSection.swift:398-440`) |
| Focused app | `NSWorkspace.frontmostApplication` change, skipped while the pointer is over the bar (`T:Thaw/MenuBar/MenuBarManager.swift:380-400`) |

- [C] Open menu detection: `MenuOpenMonitor` enumerates on-screen windows at menu-related levels that touch the bar strip. New windows are compared with a baseline so existing panels do not read as menus (`T:packages/MenuBarModel/Sources/MenuBarModel/MenuOpenMonitor.swift`, `WindowInfo.swift:71-78`). Results are cached for 250 ms.
- [C] Rehide waits poll at 4 Hz (`MenuBarSection.swift:474-506`). Open-menu time does not count toward the interval.
- [C] Persisted in `com.stonerl.Thaw`: `MenuBarItemManager.savedSectionOrder`, `knownItemIdentifiers`, `MenuBarConcealSnapshots`, `MenuBarConcealBundleIDMap`, pinned bundle ids, the New Items placement, `MenuBarLayoutTableBookmark`. [O] 13 snapshots exist, each with bounds, tag and `isOnScreen`.
- [C] Permissions: Accessibility is required for hiding, revealing and rearranging. Menu Bar Layout Access is optional. Screen Recording is optional and only affects previews (`T:docs/PERMISSIONS.md`).
- [C] Private dependencies: MenuBarClientCore assertion and item manager, SkyLight (`CGSSetConnectionProperty`, `cgsWindowHider`, `SLPSPostEventRecordTo`), MenuBarAgent's AX tree shape, the table file.
- [C] Crowded bars: if items do not fit inline, Thaw opens a panel instead of revealing inline (`MenuBarSection.swift:266-282`). [GAP] Not exercised live.
- [C] Multi-item apps: one Visible item can keep a Hidden sibling on the bar (`T:FREQUENT_ISSUES.md:61`).
- [C] Restarting apps: an item that relaunches under a live restriction is tracked (PRK "relaunched under a live restriction"). New icons are placed by `NewIconArrivals`.
- [C] Full screen, Live Activities, pinned Control Center items have documented limitations (`T:FREQUENT_ISSUES.md:71-93`).
- [GAP] External displays: a watcher exists (`ActiveMenuBarDisplayWatcher`) but was not exercised. An allow-list is global, so [I] hiding cannot differ per display.
- [GAP] Whether the assertion ends when its process is killed. This decides Portside's fail-open story.

## End-to-end flow in Thaw

```text
Launch
  ThawAXHelper reads MenuBarAgent AX window -> drawn items, pid, x
  Item cache <- identity namespace:title[:index]
  Load savedSectionOrder, conceal snapshots
  RuntimeSectionController.start
      allowed = visible items' bundles
      MBAssessmentModeConfiguration(systemItems, allowedBundleIdentifiers)
      MBAssessmentModeAssertion.activate -> hidden apps vanish

Click icon / shortcut
  MenuBarAgent forwards primary action -> respondToClick -> section.toggle
    show: fits inline?
       no  -> Thaw Bar panel
       yes -> Automatic: write saved order first (table, or drag without grant)
              release or widen restriction -> items appear
              startRehideChecks
    hide: hideRevealedSections -> assertion back on

Re-hide (Smart)
  outside click -> wait 15 s -> newest click wins
  still outside, app active, no open menu -> hide

Layout edit
  drop -> setSection(id) -> Automatic: table write or ⌘-drag -> validate
  ⌘-drag on the bar -> macOS moves it -> wait 1.5 s -> adopt membership
```

---

# Part 2: Portside

## Current state and findings

| Area | Portside today | Note |
|---|---|---|
| Hide | Widen a separator `NSStatusItem` (`P:Core/MenuBar/MenuBarShelf.swift:273`, `widthToClear` :203) | Mechanism Thaw's source says no longer reflows on 27 |
| Membership | Position relative to separators (`MenuBarLayoutPlanner.section`), saved choice in defaults | Forces a physical move for every section change |
| Discovery | `AXExtrasMenuBar` per app (`P:Core/MenuBar/MenuBarItemSource.swift:185`) | Reachable test is `hitTestedCenter` (`P:Core/MenuBar/MenuBarReorder.swift:102`), so a concealed item reads as unmovable |
| Move | One verified HID ⌘-drag, pointer restored (`P:Core/MenuBar/MenuBarReorder.swift:109`) | Comparable to Thaw's fallback route. Solid |
| Rehide | One cancelable timer, deferred by menu, button, layout (`P:Core/MenuBar/MenuBarTriggers.swift:265-305`) | Reusable. No outside-click policy |
| Open menu | Any window at popup level (`P:Core/MenuBar/MenuBarTriggerLive.swift:19`) | Coarser than Thaw: no bar-strip or baseline test |
| Recovery | `failOpen` on sleep, wake, display change, control off screen (`P:Core/MenuBar/MenuBarShelf.swift:153`) | Reusable. `controlIsOnScreen` reads the status item window, whose meaning on 27 is unverified |

Defects this investigation exposes:

1. **Hide width (commit 1e3df2b4).** Likely ineffective on 27 per Thaw's comment. It was never verified on your bar.
2. **Empty-bar probe.** `LiveMenuBarEmptyAreaProbe.statusItemRects` looks for windows at status level. [O] None exist at that level on 27.0.1, so it would report occupied space as empty. Those triggers are disabled today. Do not validate them with this code.
3. **Coexistence.** Portside and Thaw were both active during your tests. The second `«` in your screenshots is consistent with that [I].

## Comparison

| Capability | Thaw mechanism | Portside mechanism | Gap | Smallest change |
|---|---|---|---|---|
| Hide and reveal | Allow-list assertion | Widened separator | Unreliable on 27 | New `MenuBarShelfSurface` backed by the assertion |
| Membership | Identity map | Position against separators | Needs drags | Membership is the saved map; `apply(hidden:)` derives the allow-list |
| Granularity | Per app | Per item (in theory) | UI promises what macOS cannot do | Move all of an app's items together |
| Discovery | MenuBarAgent AX window, helper process | `AXExtrasMenuBar`, detached task | Hidden items need memory | Keep the reader, add a known-items cache |
| Identity | namespace:title:index | owner:id or ordinal | Ordinal is fragile | Prefer title, then instance index |
| New items | Marker plus per-app rule | None | New icon can unhide its app | Inherit the app's section, else a chosen default |
| Reorder | Table write, or ⌘-drag | ⌘-drag | Pointer interruption | Accept. Explicit edits only |
| User ⌘-drag | Observed and adopted | Not observed | Only the editor changes sections | Later, using the MenuBarAgent AX window |
| Rehide | Smart, Timed, Focused | Timed, app change | No outside-click | Add a Smart policy to the existing service |
| Menu detection | Strip plus baseline | Level only | False deferrals | Add strip and baseline tests |
| Persistence | Restores collapsed | Starts revealed | Bar not collapsed at login | Membership saved, re-applied at launch, after the spike |
| Crowded bar | Falls back to a panel | None | Items can stay unreachable | MENU-07 Portside Bar |
| Conflict | Documented | Summary text only | Silent fights | Detect a running manager and refuse to hide |

## Recommended design

**Reuse everything above the surface.** `MenuBarShelf` already has the right state machine and fail-open behavior behind `MenuBarShelfSurface`. Replace only what draws and hides.

```text
MenuBarShelf (unchanged state machine, failOpen)
   |
   +-- AssertionShelfSurface          new, macOS 27+
   |     control status item only: eye icon, no separators
   |     apply(hidden:) -> allow = everything not assigned to a hidden section
   |     MenuBarAssertionBridge       new file, dlopen/dlsym only (AGENTS rule 5)
   |
   +-- StatusItemShelfSurface         kept for macOS 26

MenuBarMembership                    new, pure: id -> section, grouped by bundle
MenuBarLayoutService.drop            membership change + re-apply; no drag
MenuBarTriggerService                unchanged, plus a Smart policy
MenuBarReorderService                unchanged, explicit reorder only
```

- **Section membership.** A saved map by item identity, enforced per bundle. Layout strips group an app's items and move them together, which matches what macOS can do. Items not drawn can still be assigned, which removes the "Off screen" limitation.
- **Visibility.** Toggle equals applying or releasing one assertion. Portside's own bundle is always on the allow-list, or the control disappears. If the bridge is unavailable, the surface reports hiding unavailable, and the shelf stays revealed.
- **Re-hide.** Keep the single cancelable timer. Add Smart: an outside click re-arms it. Add bar-strip and new-window checks to menu detection. Do not adopt Thaw's 4 Hz poll or `mouseMoved` monitor, which conflict with the plan's "one cancelable delay timer and no polling".
- **Layout restoration.** Membership re-applies at launch, needing no drags. Physical order is restored only when you ask, by Put Back.
- **Automatic arrangement.** Keep it out of hide, reveal and launch. Run the verified ⌘-drag only from an explicit reorder in the editor or Put Back. Reliability is better because drags cannot fight a toggle. Responsiveness is better because a toggle costs one assertion call. Pointer interruption occurs only when you asked to reorder. No Screen Recording, no table grant, no Full Disk Access. Accessibility stays required for discovery.

## Implementation sequence

Each step ships separately. Stop if step 1 fails.

**1. Spike the assertion (quit Thaw first).** Throwaway probe, no product code.
- Activates from a `swift run` build and from a signed app.
- Allow-list hides exactly the expected apps. Own item stays.
- After SIGKILL of the holder, every item returns within 2 s.
- After `killall MenuBarAgent`, state is known. Record whether re-activation is needed.
- Sleep, wake and display change results recorded. Apple items hidden as a side effect listed.
- Toggle latency measured.

**2. Bridge and surface.** `MenuBarAssertionBridge.swift` with `dlopen`, ARCHITECTURE note, `AssertionShelfSurface`, OS gate. Revert the `widthToClear` path for 27.
- Hide clears every Hidden app. Reveal restores all.
- Missing class means hiding reports unavailable and nothing is hidden.
- Turn Off, quit and SIGKILL all return the bar.
- Dock reveal path unchanged, by the latency check.

**3. Membership.** Pure `MenuBarMembership`, tests first. Layout drop re-applies the assertion with no drag.
- A drop never moves the pointer.
- Multi-item apps move together, and the UI says so.
- Hidden and not-drawn apps stay listed and assignable.

**4. Coexistence.** Detect Thaw, Bartender or Ice running.
- With one running, Portside refuses to hide and says why.
- Quitting it enables hiding without a restart.

**5. Rehide.** Smart policy, improved menu detection.
- A revealed item's open menu holds the rehide, and it resumes after closing.
- Outside click hides after the delay. A click in the bar does not.
- No new polling, verified in review.

**6. Launch state (needs decision 4).** Re-apply at login.
- Collapsed after login with no flash of hidden items beyond one frame budget you set.
- A crash during hide returns everything.

**7. New items.**
- A new icon from a hidden app stays hidden.
- A new app goes to the chosen default.
- A title-churning app cannot loop.

**8. Explicit reorder.** Existing ⌘-drag from the editor and Put Back.
- Never runs during toggle or launch.
- Failure is reported and not retried.

**9. Edge pass, by hand.** Notch with a crowded bar (with MENU-07 if needed), external display attach and detach, third-party app quit and relaunch, Accessibility revoked, full screen, MenuBarAgent restart, macOS update re-check.

**10. Observed ⌘-drag adoption (optional).** Read the MenuBarAgent AX window after a ⌘-drag ends. Requires a narrow divider while open.

## Everyday workflow acceptance

1. Log in: hidden apps are not on the bar.
2. Click the eye: they appear. Click again: gone.
3. Press the shortcut: same result.
4. Double-click: Always Hidden appears, when enabled.
5. Open a revealed item's menu and wait past the delay: it stays. Close it, then click away: it hides.
6. In Settings, drag an icon to Hidden: it hides immediately and the pointer does not move.
7. Quit Portside: everything returns.

## Open gaps

- Assertion lifetime on process death and on MenuBarAgent restart.
- Activation from unsigned or ad hoc builds.
- Closed PRK internals beyond exports and strings. A configured decompiler would reduce this.
- Live behavior on a crowded notch and on external displays.
- Stability across macOS updates: this is an undocumented API.
- The Simple Mode screenshot was not available.

---

# Step 1 spike results: assessment-mode assertion (2026-11-09)

Scope: step 1 of the implementation sequence only. Standalone harness in the session scratchpad, outside the repo: `.../scratchpad/spike/` (`harness.swift`, `bar.swift`, logs `h.*.log`, `w.*.txt`, `c1*.watch`, `probe2.txt`). No Portside code ran. No synthetic input, no MenuBarAgent position-table access, no startup hiding. Thaw was quit before testing and relaunched afterwards (its hidden set re-applied; the bar is back to the Thaw state it had before).

## Setup and method

- macOS 27.0.1 (26A434), same Mac. Thaw quit by Apple event; it was gone within 1 s and its 13 hidden apps returned. Portside was not running. No other menu bar manager was running.
- Observer `bar`: read-only Accessibility walk of MenuBarAgent's window, 25 to 40 ms sampling, the same read-only technique described in Pass 2. It lists drawn items only, so a hidden item is simply absent. It cannot show flicker visible to the eye or anything drawn for under about 60 ms.
- Harness `harness`: `dlopen` of MenuBarClientCore, classes resolved with `objc_getClass`, `MBAssessmentModeConfiguration` built with `initWithAllowedSystemItems:allowedBundleIdentifiers:` (both `NSArray`, from the local type encodings `@32@0:8@16@24`), activated with `activateWithConfiguration:completionHandler:` (`v32@0:8@16@?24`). Controlled over a named pipe from an external shell. Each case started a separate harness process.

### Baseline (Thaw quit), 22 drawn entries, left to right

| Source | Entries |
|---|---|
| Third party (14) | Stats (193 pt wide), UA Mixer Engine, Tailscale, Ollama, Shottr, Raycast, Bitwarden, Rectangle, Scroll Reverser, BetterCapture, ChatGPT, Malwarebytes Agent, PortKiller, plus Apple's "Show Hidden Menu Bar Items" overflow control (MenuBarAgent) between Ollama and Shottr |
| SystemUIServer (2) | VPN and Time Machine entries |
| MenuBarAgent Apple extras (6) | Bluetooth, Sound, Wi-Fi, Battery, Control Center, Clock |

Focus, Now Playing, AirDrop, Live Activities and the camera or microphone indicators were **not present** at baseline, so side effects on them could not be observed.

Hide target: **Scroll Reverser** (`com.pilotmoon.scroll-reverser`, one item). Keep-visible control: **Rectangle** (`com.knollsoft.Rectangle`, one item).

## Facts learned about the API

- [O] Acquisition works from an unsigned ad hoc binary run from a shell. `activateWithConfiguration:completionHandler:` completes in 0 to 7 ms with `error=nil`. No entitlement, no prompt. Over 25 activations, no error ever returned.
- [O] The allow-list has two parts. Bundle IDs gate third-party items and SystemUIServer. **System items are gated by integer codes, not bundle IDs.** Passing `com.apple.MenuBarAgent` in the bundle list did not keep Apple extras. With an empty system-item list every Apple extra, and the overflow control, disappeared.
- [O] Codes found by activating one code at a time with all app bundles allowed (`probe2.txt`): `0` battery, `1` bluetooth, `2` clock, `5` sound, `6` wifi, `8` controlcenter. Codes `3`, `4`, `7` and `9` to `12` exposed nothing at baseline. They presumably cover items that were absent (Focus, Now Playing and similar) but this was not shown.
- [O] A not-listed third-party bundle is hidden (Scroll Reverser). [GAP] A bundle that first launches while an assertion is active was not tested.
- [O] **Several live assertions union their allow-lists.** My first harness never invalidated old assertions, because `readLine()` blocked the main queue, and 24 stacked assertions showed everything. This means a replacement scheme that leaves the old assertion alive hides nothing until the old one is released.

## Check 1: selective hiding and Apple items

Allow-list: all baseline bundles except Scroll Reverser, system items `[0,1,2,5,6,8]`.

| Result | Observation |
|---|---|
| Target | Scroll Reverser disappeared (22 to 21 entries) |
| Control | Rectangle stayed, and every other third-party entry stayed |
| Apple items | All six extras, both SystemUIServer entries and the overflow control stayed. Focus and Now Playing: not present, not tested |
| Order | Relative order of the remaining items unchanged. Items reflowed right to fill the gap |
| Pointer | 0 pointer movements observed across all watch runs (5 files) |

Variant: **empty** system-item list with the same bundles hid all six Apple extras and the overflow control. Practical rule: a Portside allow-list must always include the baseline system-item codes.

## Check 2: hide, reveal, hide twice

Sequence per variant: hide, reveal, hide, reveal, hide, 3.2 s apart.

| Path | Result |
|---|---|
| Update in place: re-activate the same assertion object with a new configuration (`same`) | Completes in 0 to 1 ms with no error, but **no visible change at all over 18 s**. In-place update does not work. The assertion must be replaced |
| Replace, activate new then invalidate old after 1 s (`new`) | Reveal 0.11 to 0.20 s. Hide 1.7 to 1.9 s (includes the deliberate 1 s overlap, because the old reveal assertion is still unioned) |
| Replace, invalidate old then activate new (`newbefore`) | Reveal 0.12 to 0.20 s. Hide 0.69 to 0.88 s |

- Item order: all settled states kept the baseline relative order. Scroll Reverser returned in its original slot each time.
- Transients seen: on every transition the drawn list passes through one or two frames with empty placeholder children (known from Thaw's own comments). Once, in the invalidate-first path, three third-party items swapped places for about 60 ms (one sample). No sample showed all items hidden.
- Flicker: **not assessable by this observer.** Whether the 60 ms swap or the placeholder frames are visible to the eye needs someone watching. [GAP]
- Pointer: unchanged in every run.
- Conclusion: replacement is required. Invalidate-then-activate is faster for hide; activate-then-invalidate has no all-visible gap in the other direction but must not leave the old assertion alive when hiding.

## Check 3: restoration

Each case: fresh harness, hide Scroll Reverser, confirm 21 entries, then act. Times are from the action to the first sample showing the full baseline set.

| Case | Action | Baseline set back | Time |
|---|---|---|---|
| Explicit release | `invalidate`, process keeps running | Yes, 22 entries, Scroll Reverser present | about 0.22 s |
| Normal exit while hiding | `exit(0)` with the assertion held, no invalidate | Yes | about 0.17 s |
| SIGKILL (last) | `kill -9` of the harness | Yes | about 0.17 s |

No case needed manual recovery. No `killall MenuBarAgent`, no restart, no setting change. After SIGKILL, the final bar matched the baseline entry list exactly. [O] The assertion is tied to the holder's connection, not to a persisted setting.

## Results

| Question | Result | Basis |
|---|---|---|
| Selective hiding | **PASS** | One app hidden, control app kept, all other apps kept, order preserved, completion 1 ms |
| Apple-item side effects | **PASS with a condition, partial** | All six baseline Apple extras and the overflow control survive only if their system-item codes are passed. Focus and Now Playing could not be tested, because they were not present at baseline |
| Forced-exit recovery | **PASS** | Explicit release, normal exit and SIGKILL each restored the full baseline in 0.17 to 0.22 s |

Not part of the three results but important: in-place update **fails** (replace instead), and hide latency is 0.7 to 0.9 s with invalidate-first.

## Go or no-go

**GO for a guarded prototype**, with these guards:

1. Gate to macOS 27. Resolve both classes dynamically in one file and treat any missing class, selector or error as hiding unavailable, leaving the bar untouched. ARCHITECTURE note required (rule 5).
2. Always pass system-item codes `[0,1,2,5,6,8]` plus any items found at runtime. Unknown codes are an open item: record what `3`, `4`, `7` and others cover before shipping, ideally with Focus and Now Playing active.
3. Replace, never update in place. Invalidate the old assertion before activating the new one when hiding, and never leave two assertions alive.
4. The assertion holder must be Portside's own process so that quit and kill restore the bar (verified for exit and SIGKILL of a plain process). Portside's own bundle must be on the allow-list.
5. Re-test with a crash of MenuBarAgent, sleep and wake, a display change, a second manager running, and an app that launches while hiding is active. None was tested here.
6. Keep startup hiding off until those pass.

## Remaining gaps

- Visual flicker and the 60 ms transient swap need human observation.
- Focus, Now Playing, AirDrop, camera indicator and the meaning of codes `3`, `4`, `7`: untested.
- App launching or quitting while hiding is active.
- Notched or crowded bars: this Mac's bar had room (leftmost entry at x=812).
- External displays, sleep and wake, MenuBarAgent restart.
- Behavior from a sandboxed or signed app: the harness was an unsigned command line tool.
- Hide latency of 0.7 to 0.9 s may feel slow compared with the current separator approach. A human should judge.

---

# Step 2 results: guarded assertion-backed shelf surface (2026-11-09)

Scope: step 2 only. Developer opt-in prototype behind the existing `MenuBarShelfSurface`. No membership storage, settings redesign, re-hide policy or automatic arrangement changes. No synthetic input, no position-table writes.

## What was built

- `LiveMenuBarAssertionBridge` (one private-API file): `dlopen` of `MenuBarClientCore`, classes resolved at runtime, the three selectors checked against the step 1 type encodings (`@32@0:8@16@24`, `v32@0:8@16@?24`, `v16@0:8`). Missing or changed means "hiding unavailable", bar untouched.
- `AssertionShelfSurface`: wraps the existing control item (no separators). Hides by bundle ID from the saved layout assignments. The allow-list is every running bundle except the hidden ones, plus Portside, `com.apple.MenuBarAgent` and `com.apple.systemuiserver`, with system-item codes `[0,1,2,5,6,8]` (battery, bluetooth, clock, sound, wi-fi, control center; a verified subset, other codes untested).
- `MenuBarAssertionController`: one assertion at a time. Release before acquire, never overlapping, no reuse. A request during a pending activation is held and the latest wins. Reveal, Turn Off, stop and fail-open release at once and cancel a pending hide. Activation error, no answer in 3 s, a missing bridge or no hidden apps release and reveal.
- Own-icon guard: 1.5 s after a hide lands (one retry 0.75 s later), a read-only Accessibility read of MenuBarAgent's window must show Portside still drawn, else the hide is undone. The old check (status item window frame) cannot see a hidden icon.
- Opt-in: `PortsideDeveloperAssertionHiding` default or `PORTSIDE_ASSERTION_HIDING=1`, macOS 27 only. Older macOS and the default path keep `StatusItemShelfSurface` unchanged.
- Developer hook, only while opted in: Darwin notifications `com.james.portside.dev.shelf.toggle` and `.turnOff` call the control's own actions, so timing runs need no synthetic input.

## Changed files

| File | Change |
|---|---|
| `Sources/portside/Core/MenuBar/MenuBarAssertionBridge.swift` | new: bridge, config, opt-in |
| `Sources/portside/Core/MenuBar/MenuBarAssertionSurface.swift` | new: plan, controller, surface, drawn-owner read |
| `Sources/portside/Core/MenuBar/MenuBarShelf.swift` | `failureHandler` on `MenuBarShelfSurface` (shelf reveals on it); `StatusItemShelfSurface(controlOnly:)` |
| `Sources/portside/PortsideApp.swift` | chooses the surface (opt-in or default) |
| `Tests/portsideTests/MenuBarAssertionTests.swift` | new: 22 cases, fake bridge |
| `Tests/portsideTests/MenuBarShelfTests.swift` | fake surface gains `failureHandler` |
| `docs/ARCHITECTURE.md`, `docs/CHECKLIST.md` | private-API note, file tree, status |

`swift build` clean, `swift test`: 734 tests, 0 failures.

## Method

- Thaw fully quit (Apple event, gone in 1 s), no other manager, Portside not running. Baseline 22 entries as in step 1.
- App: `scripts/build-app.sh --install` (normal Local Development signature), run with `open -n --env CFFIXED_USER_HOME=/tmp/portside-assert --env PORTSIDE_ASSERTION_HIDING=1`. The installed copy was removed afterwards. Thaw was relaunched afterwards.
- **`CFFIXED_USER_HOME` isolated `dock.json` but not the app's defaults.** The app read my real layout assignments: Codex (ChatGPT) Hidden, Scroll Reverser Hidden, Stats Always Hidden. So the intended hide set was those three.
- Observer: the step 1 `bar` tool (read-only Accessibility, 40 ms sampling), times are visible changes measured from the toggle notification, not API completion. Notification spawn adds about 0.1 to 0.25 s of jitter between sends.
- One run was invalidated: the Mac locked mid-test (`loginwindow` frontmost, MenuBarAgent windows not on screen, 0 entries). It was redone after unlock.

## Results

| Case | Observation |
|---|---|
| Startup | Revealed. 24 entries (22 baseline + Portside's 2 icons), Scroll Reverser visible, nothing hidden |
| Hide | First visible change +0.12 s (transient frame), settled at +0.95 s with 19 entries |
| Preserved while hidden | Rectangle (control app), 6 Apple extras plus the overflow control (7 MenuBarAgent rows), both SystemUIServer items, every other third-party app |
| Removed while hidden | Scroll Reverser, ChatGPT, Stats (the assigned apps) **and both of Portside's own icons** |
| Own-icon guard | Hide undone at +2.54 to +2.60 s (entries back to 24), as designed |
| Rapid hide, reveal, hide | Sends at 0, +0.26, +0.52 s. Latest intent won: settled hidden at +1.48 s. Transient frames of 23, 28, 27, 27, 23 entries between +0.40 and +0.95 s. Guard undid it at +3.08 s |
| Turn Off during a pending hide (sent +0.25 s after the toggle) | Ended revealed: 23 entries (22 + Portside's menu icon), Scroll Reverser, Stats, ChatGPT visible. It never reached the 19-entry hidden state. Stayed revealed 4 s later. Module saved off |
| Normal quit while hidden (SIGTERM at +1.5 s) | Items back at +1.69 s, 0.19 s after the signal. 22 entries, baseline |
| SIGKILL while hidden (at +1.49 s) | Items back at +1.68 s, 0.19 s after the kill. 22 entries, baseline |
| Dock reveal smoke | App ran 18 s with no crash, 0.0 % CPU, 87 MB, no new crash report. The only on-screen Portside window was a 520 by 296 panel at layer 8, not the dock. Hover reveal was **not exercised** (needs a person). No Dock file is in the diff |

Never observed externally: that two assertions never overlap. That is unit tested (`maxLive == 1` over replacement, latest-wins, rapid and pending cases).

## Why Portside's own icon disappears

Under an assertion held by **another process** that allow-lists every running bundle, including Portside's, Portside's icons still vanish. Experiments, all with the step 1 harness as holder:

| Subject | Icon survives |
|---|---|
| `build/Portside.app`, Local Development signature, run from a shell | No |
| Same, launched through LaunchServices | No |
| Copy re-signed with Developer ID (team WNZ8H4UHQE) | No |
| Same plus hardened runtime | No |
| Allow-list with bundle-name variants (`Portside`, `com.james.Portside`, others) | No |
| Ad hoc signed trivial status item app in scratch | No |
| Local Development build installed in `~/Applications` | No |
| Copy of the notarized release 1.9.0 in a scratch folder | No |
| Notarized release 1.9.0 in `/Applications` | **Yes** |

[O] The same notarized app survives from `/Applications` and not from a scratch folder. [I] The assertion honors allow-listed bundles only for apps installed in `/Applications` (LaunchServices trusted location). Not separable with what was tested: whether a Local Development build in `/Applications` would also survive. I did not install anything there (AGENTS rule 7).

The earlier suspicion that the running-app list was incomplete was wrong: Stats and Codex were in `NSWorkspace.runningApplications`, and were correctly dropped as assigned Hidden.

## Results by requirement

| Requirement | Result |
|---|---|
| Hide removes the target app | PASS |
| Control app stays visible | PASS |
| Baseline Apple extras preserved | PASS (6 extras, overflow control, SystemUIServer) |
| Portside's own icon preserved | **FAIL on dev builds** (platform behavior above); guard undoes the hide |
| Rapid hide, reveal, hide: latest intent wins | PASS |
| Turn Off during a pending hide releases | PASS |
| Normal quit, SIGKILL restore | PASS (0.19 s each) |
| Startup revealed | PASS |
| Dock reveal path | Not exercised (launch smoke only) |
| Visual flicker | **Not assessed**: needs someone watching. The observer saw churn frames of 23 to 28 entries on transitions |

## Not tested

- Visual flicker, Dock hover reveal, notch and crowded bars, external displays, sleep and wake, MenuBarAgent restart.
- An app launching while hidden (the launch observer is unit tested only).
- Focus, Now Playing and other Apple extras beyond the six verified.
- A build of this code installed in `/Applications`.
- Which guard message fired: the log stream returned nothing in this shell, and whether the local app is Accessibility trusted was not confirmed. Both messages undo the hide.
- The guard has a cost: with Accessibility denied, a hide is always undone.

## Recommendation

The surface is safe by default (opt-in, fail-open, verified restore), but a hide cannot be held while Portside runs from a dev build, because macOS hides Portside's own icon. Do not start step 3 until the prototype is exercised from an installed `/Applications` copy. That needs your decision, because it is outside AGENTS rule 7 and needs the release or notarization pipeline.

---

# Step 2 follow-up: does `/Applications` keep Portside's control visible? (2026-11-09)

Question: does the same Step 2 build keep its own menu bar control visible and usable while hiding is active when it runs from `/Applications/Portside.app` instead of the dev location? Pass means: target hidden at least 10 s, Portside's real control visible and clickable, clicking it reveals the target, Turn Off and quit restore the bar. Guard stays enabled.

## Build under test

| Item | Value |
|---|---|
| Source | current uncommitted Step 2 tree (adds dev-only diagnostics file `/tmp/portside-assertion-diag.json`: running bundle path, Accessibility trust, last guard reason; written only with the developer hooks on) |
| Local Development build | `build/Portside.app`, identity `Portside Local Development`, no Team ID, executable sha256 `7c08807dcadd3d2a3e8c77a75e7c94e1c1e6577d5b818654548114957d678b4b` |
| Test bundle (used for the location comparison) | the same bundle re-signed, `build/step2-devid/Portside.app`, `Developer ID Application: James Zangari (WNZ8H4UHQE)`, hardened runtime, not notarized, executable sha256 `0449ef9bebeca5a41800a54ecaa87b658862aeac488e059075383ac32934acd5` |
| Staged copy for the swap | `/tmp/portside-step2-stage/Portside.app`, same sha256 as the test bundle, signature valid |
| Installed release (to preserve) | `/Applications/Portside.app` 1.9.0, Developer ID, notarized and stapled, executable sha256 `6f1d78e829542de45ebc944741eca04c254c3c9e36de7ad26e92025cc0ef4988` |

Why re-signed: macOS keeps one Accessibility grant per bundle ID. The Local Development copy is **not** trusted (`accessibilityTrusted: false`), and trusting it would replace the grant your release uses. The Developer ID copy shares the release's grant requirement and **is** trusted, with no privacy change. Same code, different signature.

## Controls held constant

Thaw and every other menu bar manager quit (22 baseline entries). Same hide assignments in every run: the app's real defaults (Scroll Reverser Hidden, Codex/ChatGPT Hidden, Stats Always Hidden). Launched through LaunchServices (`open`). Hide driven by the developer hook, not the pointer. One Portside process at a time, running path read from `ps` and from the app itself. The observer lists bar items from MenuBarAgent's window; `ctlcheck` lists Portside's items with their frame, Accessibility actions and an Accessibility hit test at the item centre (read-only, performs no action).

## Run 1: dev location, Local Development signature

| Check | Result |
|---|---|
| Running path | `.../build/Portside.app/Contents/MacOS/portside` |
| Accessibility trusted | **No** |
| Startup | Revealed, 24 entries, Portside's 2 items present, `AXPress`, hit test returns Portside |
| Hide | Landed at +0.94 s, 19 entries: Scroll Reverser, ChatGPT, Stats **and both Portside items** gone |
| Guard | Undid the hide at +2.55 s. Reason: "could not confirm its own menu bar icon" |

The guard reason here is Accessibility, not the icon. The external observer (a separate trusted process) shows the Portside items were gone from the bar anyway. Held for about 1.6 s. Not a pass.

## Run 2: dev location, Developer ID signature (same bundle as the staged copy)

| Check | Result |
|---|---|
| Running path | `.../build/step2-devid/Portside.app/Contents/MacOS/portside` |
| Accessibility trusted | **Yes** |
| Startup | Revealed, 24 entries, 2 Portside items, `AXPress`, hit test returns Portside |
| Hide | Landed at +0.94 s, 19 entries, same set removed, Rectangle and 6 Apple extras kept, Portside's 2 items gone |
| Guard | Undid the hide at +2.61 to +2.67 s. Reason: **"macOS hid Portside's own menu bar icon along with the others"** (Accessibility could verify; the control had disappeared) |
| Held 10 s | No. Held about 1.7 s |

Not a pass: the control disappeared. No click was possible because nothing was left to click.


## Run 3: `/Applications/Portside.app`, Developer ID signature (same bundle as Run 2)

| Check | Result |
|---|---|
| Running path | `/Applications/Portside.app/Contents/MacOS/portside`, sha256 matches staged copy |
| Accessibility trusted | Yes |
| Hide | Landed at +0.90 s, 21 entries: only Scroll Reverser, ChatGPT and Stats gone |
| Control | Both Portside items stayed, `AXPress` offered, hit test returned Portside at +3, +6, +10.5 and +13 s |
| Guard | Did not trip. `lastFailure` nil after more than 25 s |
| Physical click, Turn Off, quit | Not run. Stopped at the maintainer's direction to build the full feature |

Outcome: `/Applications` keeps the control visible while hiding. **Hold passes. Full pass definition not completed.**

# Full implementation (2026-11-09, uncommitted)

Built at the maintainer's direction, replacing the step-by-step plan. Behavior was matched from this report. No Thaw code was copied. Row by row against the comparison table:

| Capability | Now in Portside |
|---|---|
| Hide and reveal | Assertion, default on macOS 27, starts collapsed, survives sleep and display changes |
| Membership | Saved map; a section change needs no drag |
| Granularity | Per app; an app's items move together |
| Discovery | AX reader plus MenuBarAgent's window for drawn items, overflow chevron, empty-bar test |
| Identity | Unchanged (`bundle:id or #ordinal`): hiding uses only the bundle part |
| New items | Chosen section for an app seen for the first time, once its icon appears |
| Reorder | Command-drag on a drop onto an icon, Automatic only; Manual never moves |
| User Command-drag | Reveals on press, adopts the landing side after 1.5 s |
| Rehide | Smart (default), Timed, Focused App; pointer on bar and open menus hold it |
| Menu detection | New windows hanging from the bar since the reveal |
| Persistence | Membership and Always Hidden saved, re-applied at launch |
| Crowded bar | Icon row under the control when macOS shows its chevron; opens with AXPress, 15 s reveal |
| Conflict | Refuses to hide and says why while Thaw, Ice, Bartender or Hidden Bar runs |

Also built: double-click and Option-click for Always Hidden, Always Hidden shortcut, right-click and Control-click via global monitor, hover/scroll/empty click (scroll and empty click on by default, as in Thaw).

Later the same day the items listed here as not built were built: position-table writes with restore before reveal, Native hiding through Control Center's list, Apple items including Clock and Control Center, and profiles.

Verification at the end of that work: debug, release and test builds with no warnings, 776 tests pass, and the native runs recorded in `docs/research/P2-MENU-06-interaction-audit.md`.
