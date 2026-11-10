# Menu bar interaction audit

2026-11-09. macOS 27.0.1, current `feat/p2-menu-06-triggers` worktree, including its pre-existing uncommitted assertion implementation.

**Result: not equivalent to Thaw or Bartender. Do not mark menu bar management complete.** The three visibility sections are not arbitrary user groups. A saved section is not a saved order. Always Hidden is conditional while Portside runs, with intentional recovery on failure; it is not an unconditional permanent system setting.

## Unexpected reveal

The actual application logs record `menubar-assertion` rejecting the hide because Portside's own menu bar owner was absent, followed immediately by `menubar-shelf` revealing everything. This matches the reported brief hide. It is the recovery check, not an automatic-rehide policy.

Controlled native experiment:

1. Start the existing `/Applications/Portside.app` with a temporary home, left Dock edge, native Dock hiding disabled, one explicit test assignment and automatic rehide disabled.
2. Invoke the real shelf control's `AXPress` action. Read MenuBarAgent's windows to check both the target owner and Portside's owner.
3. Repeat with a byte-identical copy of that app under `/tmp`. No replacement or write to `/Applications`.

The installed copy retained its control and hid the target. The copied executable lost its own drawn owner and released hiding after verification. Launching a dev copy through LaunchServices also failed. Thus location-dependent behavior is reproduced without changing the executable. The framework's internal reason is **not established**. Keeping the assertion while its recovery control is missing would suppress the symptom by removing recovery; this audit does not do that.

There is also an independent race in `MenuBarAssertionController.scheduleVerify`: after awaiting the second AX read, it could release a newer assertion using a stale failure. The new regression suspends that read, reveals, hides again, then returns the obsolete error. It failed before the fix and passes after checking generation and cancellation after both awaits.

## Fixes made during audit

| Defect | Fix and automated evidence |
| --- | --- |
| Stale AX verification releases newer hide | Recheck generation after each await. `testLateVerificationFailureCannotReleaseANewerHide`. |
| Smart hides with no outside click; Focused App hides without an app switch | Only Timed arms the initial countdown. Smart uses outside-click work; Focused App uses activation. Separate regression tests failed before the fix. Earlier timer tests now explicitly select Timed instead of accidentally testing Smart. |
| Changing rehide policy leaves Smart work pending | Cancel Smart work on strategy/delay changes and check policy again at delivery. |
| Hover fires after its target becomes occupied | Repeat the empty-area check when dwell completes. Regression failed before the fix. |
| A saved sibling that is no longer listed keeps an entire app visible | A membership drop updates both listed and saved siblings of the same bundle. Regression failed before the fix. |
| Failed physical sorting reports success | Return the mover's failure; finish a closed editing session after the move. Regression failed before the fix. |
| Late refresh can reacquire an assertion after surface removal | Gate refresh on the installed lifecycle. `testRemovedSurfaceCannotReacquireFromLateMembershipRefresh`. |
| Visibility scan considers only the first MenuBarAgent window | Collect every window, preserving unknown results on incomplete reads. Live inventory exposed multiple windows; regression places the control on a later one. |
| Recovery explanation stays in logs; old rehide can remain armed | Forward recovery reason to Settings and cancel pending trigger work. `testRecoveryCancelsRehideAndExplainsWhy`. |

## Remaining defects and gaps

| Priority | Finding | Code / consequence |
| --- | --- | --- |
| P0 | Location-dependent loss of Portside's own icon remains | `AssertionShelfSurface` verification correctly fails open. Current development-bundle hiding must not be described as working. |
| P1 | No desired-order persistence or automatic restore on reveal | `MenuBarLayoutService.dropByMembership`, `apply`; the reorder store is an original-order rollback baseline. Automatic only permits an explicit physical drop. Manual does not save a separate requested within-section order. |
| P1 | Overflow is not a per-item interactive bar | `showPanel` makes one entry per running app, includes Always Hidden during an ordinary reveal, and `openFromPanel` presses the first item. It does not reuse the existing verified item opener. It can rehide after 15 seconds while a menu remains open. |
| P1 | Overflow/new-app async work has incomplete lifecycle cancellation | The refresh gate prevents reacquiring after removal, but delayed panel actions and new-item assignments need lifecycle tokens and cancellation across stop/restart. |
| P1 | Command-drag parity is incomplete | `commandPress` reveals Hidden but does not open Always Hidden. It trusts the hit element's PID, which may belong to MenuBarAgent; it does not resolve its actual owner. Adoption uses the first matching owner's frame, ambiguous across displays and multi-item apps. |
| P1 | Pointer feasibility was asserted without matching native tests | All three triggers are marked validated. The empty-area probe projects cached frames onto the target bar and can retain stale geometry for 300 ms; zero-size items and multiple displays need explicit rejection. Native eye tests do not validate these triggers. |
| P1 | Timed and Smart deferral are still not exact Thaw semantics | Timed checks pointer location at expiry rather than measuring continuous time outside. Smart can drop a pending decision when a menu is open; it does not resume on menu close. Open-menu detection is a window-level heuristic. |
| P1 | Application launch and item arrival are different events | `placeIfNew` checks once after 2.5 seconds, marks a bundle seen before success, and never tracks additional icons created by an already-running app. Late icons can miss the configured section. |
| P2 | Always Hidden shortcut lacks equivalent conflict feedback | The second registration silently fails; the visible conflict check covers the ordinary shortcut only. |
| P2 | Screen/wake handling skips assertion lifecycle work | Shelf module returns immediately for membership surfaces; it neither cancels stale trigger work nor verifies control geometry after a display change. |
| P2 | Settings contain misleading promises | A generic 0-second "Never" does not disable Smart/Focused App activation rehide. Automatic arrangement wording implies more than an explicit drag. Several old docs described Always Hidden as session-only on all OS versions. |

## Behavior comparison

Reference basis: [existing Thaw 3.0.0-alpha.13 investigation](../../thaw-simple-mode-analysis.md), [Bartender 7.1.0 artifact report](P2-REA-03-bartender.md), and [Bartender's documented feature set](https://www.macbartender.com/Bartender5/). These references have different versions and evidence strengths. Neither reference app received a complete native interaction replay during this audit. A parity pass cannot be inferred from names or shared private API use.

| Contract | Portside result |
| --- | --- |
| Hide until explicit reveal or configured policy | Installed baseline native eye action passes bounded hold; dev-location failure remains. |
| Normal reveal preserves Always Hidden | State-machine tests pass. Overflow has the separate leak described above. |
| Click, shortcut, double-click, Option-click, secondary menu | Core toggle and hotkey callbacks covered in tests; native AX eye action exercised. Physical double-click, modifier forwarding and secondary-menu routing lack end-to-end proof. |
| Smart / Timed / Focused App | Basic policy separation fixed; remaining deferral differences above. |
| Saved visibility assignment | Per-app assertion membership supported; stale saved-sibling bug fixed. Individual siblings cannot be hidden independently by this primitive. |
| Grouping | Only Visible / Hidden / Always Hidden. No arbitrary named groups or group status controls. Bartender's groups are a separate capability. |
| Sorting and automatic layout reconciliation | Explicit verified drag exists. Persistent desired order, pre-reveal restore and repair are missing. |
| Drag membership adoption | Partial and unverified on actual multi-display/native drag paths. |
| New-item placement | One bounded launch-time attempt, not continuous item discovery. |
| Overflow and notch access | App-launcher-style panel, not a faithful Thaw Bar or Bartender Bar. |
| Profiles, spacers, folders, per-item hotkeys and automatic presets | Not implemented by this menu bar subsystem. |
| System items and alternate hiding methods | Apple bundles excluded from assignment hiding; no Native method or verified complete system-item control. |
| Recovery and competing managers | Controller tests cover error, timeout, stop, rapid toggles and known manager conflicts. Native process-exit restoration exercised. |

## Reproduce without a hand-test request

```sh
source scripts/swift-env.sh
swift build
CFFIXED_USER_HOME=/tmp/portside-tests swift test
python3 scripts/audit-menu-bar.py /path/to/Portside.app --target com.example.running-app --seconds 20
```

The native runner requires an already-drawn target and existing Accessibility permission. It refuses a second Portside process, uses a temporary home plus a process-only assignment override, presses the actual accessible shelf control, samples all MenuBarAgent windows, checks a bounded hide interval, explicitly reveals, then verifies restoration after process exit. It records the executable hash, samples, failures and logs under `/tmp/portside-menu-audit-*`. It neither installs nor edits another app's preferences. AXPress validates the control action, not physical mouse event routing.

Validation for this audit: 757 automated tests pass, including 10 added regressions. Debug build passes with an existing unrelated Sendable warning in `FileIndexService`. Release build and signed-bundle verification also pass. `swift run portside` remained running through an isolated eight-second launch smoke; no hover or click inference is made from launch alone. No full-product equivalence or macOS 26 support claim follows from these checks.

### Final native run

- Existing installed baseline: actual shelf AXPress, eight-second hold, explicit reveal, process-exit restoration: pass. This is an older binary, not proof of current source.
- Final signed `build/Portside.app`: 20-second hold, 61 snapshots across three MenuBarAgent windows: **fail**. Both target and Portside disappear; target returns without another reveal action. Explicit reveal and process-exit restoration return the target.
- Final tested executable SHA-256: `73acfa21c4f28531b718040b9dc38f51ee6df9eae169d2a46fbf32f5573ddc49`. Local report: `/tmp/portside-menu-audit-l4qkbi_a/report.json`. This is the release binary after the audit fixes, not the installed baseline.
- The final native failure prevents a working-hiding or parity claim despite 757 passing automated Swift tests. No hand tests delegated; physical modifier/drag routing, reference-app runtime equivalence and macOS 26 remain unverified.

## Follow-up, same day

The findings above describe the build at the time of the audit. Each listed defect was then addressed, and the native runs below used `/Applications/Portside.app` on one notched macOS 27.0.1 display with synthetic events.

- 20-second hold with `scripts/audit-menu-bar.py`: no failures.
- Eye click, Option-click, secondary menu, empty-bar click (Finder and Portside frontmost), Smart hide after an outside click, Command-press reveal on a short drag: pass.
- Portside Bar: Rectangle's menu opened, its app stayed revealed while the menu was open and hid after it closed.
- Native hide, SIGKILL, relaunch: journal cleared, hiding returned.
- Found by these runs: `scrollingDeltaY` on a mouse event raises and AppKit swallows it, which silently disabled empty-bar click and Smart's outside click. Fixed, with a regression test.

Still unproven on hardware: real Command-drag drop adoption, hover, scroll, automatic profile switching, external displays, macOS 26, and how it feels by hand.

## Later the same day

Added after the follow-up above and run on the same display: the Portside Bar opens items through Accessibility with no reveal and no pointer movement; Standard hiding was confirmed to remove Live Activities (Portside off showed the activity; 23 allow-list candidates did not bring it back), while Native hiding kept it; the iPhone Live Activities key removed and restored a running activity. A bug that made the Keep Live Activities switch apply the previous value was found by hand and fixed. Current state: 810 tests pass with no build warnings.
