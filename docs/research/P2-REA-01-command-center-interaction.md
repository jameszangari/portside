# P2-REA-01: Command Center interaction research

2026-11-07. [REA workflow](../REA_RESEARCH_2_0.md) · [Tickets](../IMPLEMENTATION_PLAN_2_0.md) · [Architecture](../ARCHITECTURE_2_0.md) · [Test matrix T-05](../TEST_MATRIX_2_0.md)

Research only. No Swift source changed. No code, assets or binaries from the reference are reproduced here. Extension-host compatibility is out of scope and not claimed.

## Report header

```text
Question and planning ID:   P2-REA-01. How do open/close, selection, primary and secondary actions,
                            nested screens, Escape and focus restoration interact in a launcher,
                            and what should Portside's native Command Center do?
Reference app / version:    Raycast, bundle com.raycast.macos, CFBundleShortVersionString 2.11.1.0,
                            CFBundleVersion 0, GitCommitHash (Info.plist) ad1ad6010eb73a9be332814d2215d6001a3defe4
OS / architecture:          macOS 27.0.1, arm64
Artifact SHA-256:           executable 7e2494e40195f5ce24f709c4ad7d778f244ba79cf601a984ebe53958b69d6714
                            Info.plist 2135b523faae8bac11ac8f62f68125d1013dc01b844f224630fc37598f865a20
REA provider version:       native-macos (version not reported). Disassembly providers unavailable (see Unknowns).
Floe:                       Not located. Not under /Applications or ~/Applications (bounded search, same as
                            REA_RESEARCH_2_0). No source tag. No Floe claim is made.
Scenario / boundary:        Shipped metadata of the installed app (plist, Mach-O hash/arch) plus public
                            documentation. No runtime journey was driven. No decompilation. No UI observation.
Evidence:                   REA inspect_plist ev_86869de0fe9195638ee9f9c9a33a1c595cf0618a974a90a5c2ab3d89463176d1
                            (session-local ID; no portable bundle exported). Docs in the Sources section.
```

## Observed behavior (public documentation, fetched 2026-11-07)

"Observed" here means stated by the vendor's published documentation. It is not first-hand runtime observation. The fetches summarized pages through a small model, so exact key glyphs should be rechecked in the live app during the Phase 0 hand test. Two of the sources disagree (marked below).

| ID | Behavior | Source |
| --- | --- | --- |
| O1 | Global hotkey opens the window. Spotlight or another launcher on the same chord is a listed cause of failure. A June 2026 beta changelog mentions hotkey conflict indicators. | Troubleshooting page, changelog (via search summary) |
| O2 | Return runs the primary action of the selected item (first action in its list). The panel need not be open. | Action Panel, Keyboard Shortcuts |
| O3 | Cmd+K opens the Action Panel for the selected item. Cmd+K again closes it. | Keyboard Shortcuts |
| O4 | Cmd+Return runs the secondary action. Option+Return runs the tertiary action. Cmd+Return also submits forms. | Keyboard Shortcuts, Search Bar |
| O5 | Up/Down move selection. Option+Up/Down page. Cmd+Up/Down jump sections. Ctrl+N/Ctrl+P also move (default on). Ctrl+J/Ctrl+K optional. | Keyboard Shortcuts, Search Bar |
| O6 | Action Panel has its own "Search for actions" field. Fuzzy filter, one flat list. Actions are grouped in sections with shortcuts shown. | Action Panel |
| O7 | Some actions open submenus or inline views (shortcut recorder). Esc returns from a submenu to the panel. | Action Panel |
| O8 | A pushed view is a stack entry. Esc pops to the previous view automatically. A pop callback runs when a view is popped. | Navigation API |
| O9 | Esc: close Action Panel, else go back, else (in Root Search) clear text if non-empty, else close the window. The two manual pages word this differently (one says "closes window from Root Search", the other says clear-then-close). Treat clear-then-close as probable. | Keyboard Shortcuts, Search Bar |
| O10 | Cmd+Esc or Shift+Esc pops to root. Backspace on empty query navigates back. | Keyboard Shortcuts, Search Bar |
| O11 | A timeout setting returns to root after inactivity ("Pop to Root Search"). An extension may override it. | Search Bar, Window API (via search summary) |
| O12 | Compact mode collapses the window to the search bar when the query is empty and when focus is lost. | Search Bar |
| O13 | Plist: LSUIElement true (no Dock icon). Principal class `RaycastDesktopApp.Application`. Usage strings exist for Calendar, Contacts, Reminders, Screen Recording, Apple Events, Microphone, Camera, Location, file folders. This shows which TCC prompts the product can trigger, not that any is required for launcher open/search. | Plist, ev_86869de0... |
| O14 | Plist: URL schemes `raycast`, `raycast-x`, `com.raycast`, `com.raycast-x`. | Plist |

## Inferred (not observed)

| ID | Inference | Basis | Confidence |
| --- | --- | --- | --- |
| I1 | The hotkey uses a system-wide registration that needs no Input Monitoring. | Plist lists no input monitoring string. Not proof. Import check was attempted and failed (provider unavailable). | Low |
| I2 | The window is a key-capable, non-main floating panel on an accessory app, and the previous frontmost app is restored on dismiss. | Typical for the category, `LSUIElement`. Focus restoration is not documented in the sources fetched. | Low |
| I3 | Esc priority is a stack: panel, submenu, view, query, window. | O7, O8, O9 are consistent with it. | Medium |
| I4 | Selection resets to the first result on every query change. | Not in sources. Common launcher behavior. | Low |
| I5 | Ranking uses frecency. | Not in sources fetched. | Low |

## Portside interaction contract (original design)

Portside is native-first. This is a new contract informed by O1 to O12. It is not a copy of any product's internals.

### Keyboard table

| Key | Search (list) | Action Panel | Nested screen | Notes |
| --- | --- | --- | --- | --- |
| Return | Run primary action of selection | Run highlighted action | Run that screen's primary | Disabled row: show reason, do nothing |
| Cmd+Return | Run secondary action if defined | Run highlighted, keep panel closed | Same | Optional per command |
| Cmd+K | Open Action Panel for selection | Close panel, back to list | Open panel for current item | No selection: ignore |
| Up / Down | Move selection, clamp at ends (no wrap in v1) | Move highlight | Move within the screen | VoiceOver announces row |
| Ctrl+N / Ctrl+P | Same as Down / Up | Same | Same | Emacs keys. On by default |
| Tab / Shift+Tab | Move to next control (field, list, action hint) | Same | Same | Not used to cycle results |
| Esc | If query not empty: clear. Else close panel | Close panel (or pop submenu first) | Pop one level | See priority below |
| Cmd+Esc | Close panel and clear state | Same | Pop to root | One-key escape hatch |
| Backspace on empty query | Pop if stack non-empty, else nothing | n/a | Pop | |
| Typing | Update query. Cancel previous query | Filter actions | Per screen | Latest query wins |
| Global hotkey | Toggle: hide if visible and key, else show | Hide everything | Hide, keep or reset stack per setting | Never fires twice per press |

Escape priority (one event consumes exactly one step): Action Panel submenu, Action Panel, nested screen, non-empty query, window.

### States

| State | Meaning |
| --- | --- |
| `hidden` | No panel. Previous-focus token held only while a session is open. |
| `presenting` | Panel ordered in, becoming key. Input buffered, none lost. |
| `searching(query, selection)` | Root list. |
| `actions(item, panelQuery, highlight)` | Action Panel over list or screen. |
| `submenu(item, actionID)` | Action Panel nested level. |
| `screen(stack)` | Pushed native view, depth >= 1. |
| `running(commandID)` | Handler in flight. Cancelable. |
| `dismissing(restore)` | Panel ordering out. Focus restore decision made here. |

### Transitions

| From | Event | To | Side effects |
| --- | --- | --- | --- |
| `hidden` | hotkey / menu entry / URL | `presenting` then `searching("", first)` | Record frontmost app and focused window. Reload registry snapshot. |
| `searching` | type | `searching` | Cancel in-flight provider query. Start new one with generation token. Reset selection to first. |
| `searching` | Return | `running` or `dismissing` | Close first for fire-and-forget commands. Validate permission and availability again. |
| `searching` | Cmd+K | `actions` | Load actions for item ID. |
| `actions` | Esc / Cmd+K | `searching` | Selection preserved. |
| `actions` | Return on submenu action | `submenu` | |
| `submenu` | Esc | `actions` | |
| `actions` | Return on screen action | `screen(stack+1)` | |
| `screen` | Esc / Backspace | previous screen or `searching` | Cancel work owned by popped screen. |
| any | Cmd+Esc | `dismissing` | Clear stack and query. |
| `searching` (empty) | Esc / hotkey | `dismissing` | |
| any visible | focus lost to another app | `dismissing(restore: false)` | Do not steal focus back. |
| `running` | Esc | `running` then `canceled` | Cancel via `CommandResult.canceled`. |
| `running` | completion | `dismissing` or stay | Failure keeps panel open with reason. |
| `dismissing` | done | `hidden` | Restore previous app only when restore is true. |

### Focus restoration rules (design, to verify by hand test)

1. Capture `NSWorkspace.shared.frontmostApplication` before showing.
2. On cancel (Esc, hotkey toggle): reactivate that app only if it is still running and no other app became frontmost during the session.
3. On launch of an app or window: do not restore. The target takes focus.
4. On focus loss to another app: do not restore.
5. Panel is key-capable but never main. The Dock reveal panels stay non-key. Do not change `DockPanel` or `OverlayPanel` behavior.

## Relevant native macOS APIs

| Need | API | Class | Permission |
| --- | --- | --- | --- |
| Global hotkey | Carbon `RegisterEventHotKey` via existing `Sources/portside/HotKey.swift` and `HotkeyChord` | Public | None |
| Search panel | `NSPanel` subclass, `.nonactivatingPanel` optional, `canBecomeKey` true, level `.floating`, `collectionBehavior` join all Spaces, full-screen auxiliary | Public | None |
| Key handling | `NSEvent` local monitor or responder `keyDown` / `performKeyEquivalent`; SwiftUI `onKeyPress` / `onKeyPress(.escape)` | Public | None |
| IME safety | `NSTextInputClient` / `NSTextField` marked text: do not treat Return/Esc as commands while composing | Public | None |
| Focus capture/restore | `NSWorkspace.frontmostApplication`, `NSRunningApplication.activate(from:options:)` | Public | None |
| Hotkey conflict detect | `CopySymbolicHotKeys()` (Carbon HIToolbox) lists enabled system shortcuts, so Spotlight conflict can be shown without changing it | Public C API, rarely documented | None |
| App launch | `NSWorkspace.openApplication(at:configuration:)` | Public | None |
| Settings open | Existing Portside settings window, registry command | Internal | None |
| Quicklinks | `NSWorkspace.open(_:)` after scheme allowlist | Public | None |
| Accessibility | `NSAccessibility` roles, `accessibilityPerformPress`, announcement notifications | Public | None |
| Reduce Motion | `NSWorkspace.accessibilityDisplayShouldReduceMotion` | Public | None |

No private API is needed for CMD-01/02 as designed.

## Permissions and limitations

- Carbon hotkey needs no Accessibility or Input Monitoring. macOS handles an enabled system shortcut first. Spotlight's default chord (Cmd+Space) is therefore unusable unless the user disables it. Portside must not change that setting (AGENTS.md rule 6).
- Window-level actions (focus a window) depend on `WindowRegistry` and Accessibility. Without Accessibility the app-only fallback applies and rows must say why.
- Secure input (password fields) blocks event taps but not Carbon hotkeys in general. Behavior under secure input is unverified.
- Panel over full-screen Spaces needs `.fullScreenAuxiliary` and `canJoinAllSpaces`. Stage Manager and other Spaces are unverified.
- Restricted work Macs: Accessibility may be blocked by policy. Command Center must work with apps, commands and settings only.
- Nothing here needs Screen Recording, Calendar, Contacts or Apple Events. The reference app's usage strings (O13) are for features Portside does not plan in CMD-01/02.

## Mapping to acceptance criteria

### P2-CMD-01

| Criterion | Finding |
| --- | --- |
| Conflict shown without changing Spotlight | `CopySymbolicHotKeys` read-only check, plus registration failure from `HotKey.init?`. Show inline warning. Cites O1. |
| Repeat hotkey toggles reliably | Toggle row in transitions table. Hotkey handler already posts to main queue once per press. |
| Focus restored on cancel | Focus rules 1 to 4. Needs hand test (T-05). |
| No first-click loss | Reuse `acceptsFirstMouse` pattern from `OverlayHostingView`. Key-capable panel does not need activation to take a first click. |
| Escape/Return/arrows/Tab/Cmd+K work | Keyboard table. Esc priority from O9 and I3. |
| VoiceOver | Rows as buttons with title, subtitle and unavailable reason. Announce result count after query settle. Not researched against a live reader. |
| No AI needed | Nothing above uses AI. |

### P2-CMD-02

| Criterion | Finding |
| --- | --- |
| Stable result IDs | Use `CommandID` for commands. Apps: bundle ID. Settings panes: pane ID. Quicklinks: user UUID. Selection is keyed by ID, so it survives re-rank. |
| Previous query canceled | Generation token on each query. Drop results from older generations. |
| Deterministic tie-breaks | Order: match tier, frecency score, then stable ID ascending. No random or hash-order dependence. I5 (frecency) is an assumption, not observed. |
| Launch/Settings use registry | Primary action calls `CommandRegistry`. No second executor. |
| URL schemes allowlisted | Allow `https`, `http`, `mailto`, `x-apple.systempreferences`. Reject others by default. Raycast registers custom schemes (O14), so Portside should expect inbound URL handling later and keep it separate. |
| Permission-blocked actions explain why | Registry already returns `CommandResult.unavailable(String)`. Show it in the row and on Return. |
| Recent/frequent history clearable | Local store, Settings control, no cloud. Needs DATA.md entry when built. |

### Suggested test fixtures for T-05

1. 1,000 fixture commands, type 10 characters fast: only last query's results shown.
2. Same query twice: identical order.
3. Esc ladder: panel, submenu, screen, query, window, one step each press.
4. Hotkey double press within 100 ms: end state is consistent (not flicker open).
5. Return on unavailable row: reason shown, panel stays open.
6. IME composition: Return commits text, does not run an action.
7. Switch app during session: no focus theft on dismiss.

## Unknowns

1. **Runtime focus restoration** of the reference was not observed. Only design rules above exist.
2. **Import check failed.** `search_strings` returned `provider_unavailable` (Ghidra needs Java and `GHIDRA_INSTALL_DIR`, Hopper not installed, IDA and Kuna unconfigured). Hotkey API (I1) and panel class (I2) are unconfirmed. Not worth installing a provider for CMD-01 since the Portside design uses public APIs.
3. Esc wording conflict between two manual pages (O9).
4. Action Panel key table inconsistencies on the vendor page (some shortcuts listed twice with different keys). Not needed for Portside.
5. Floe was not found. Whether a selected Floe source exists is open. No claim made.
6. `CopySymbolicHotKeys` behavior on macOS 27 and with Spotlight disabled was not run. Verify in CMD-01.
7. Behavior in full-screen Spaces, Stage Manager and under secure input.
8. VoiceOver reading order for list + Action Panel.
9. Frecency formula and decay constants: Portside decision, not research.

## Decision

**Implement** CMD-01 and CMD-02 on public APIs per the contract above. No private API. No new dependency. No further REA probe required before CMD-01. Optional later probe: one bounded runtime observation of the reference (Esc ladder, focus restore) if the Phase 0 hand test shows disagreement.

## Sources

- https://manual.raycast.com/action-panel
- https://manual.raycast.com/keyboard-shortcuts.md
- https://manual.raycast.com/search-bar.md
- https://developers.raycast.com/api-reference/user-interface/navigation
- https://developers.raycast.com/api-reference/window-and-search-bar (search result only, not fetched)
- https://manual.raycast.com/troubleshooting.md (search result only, not fetched)
- Local: `/Applications/Raycast.app/Contents/Info.plist`, REA `inspect_plist`
- Portside: `Sources/portside/HotKey.swift`, `Sources/portside/OverlayPanel.swift`, `Sources/portside/Core/Commands/CommandRegistry.swift`
