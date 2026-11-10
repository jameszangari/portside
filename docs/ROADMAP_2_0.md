# Portside 2.0 roadmap

Status: proposed implementation sequence, 2026-11-06. No feature below is marked shipped by this document. Baseline: `0c7062fc2225b194eb60118e038fba76ee9f19b5` on `main`.

Portside becomes a native control center for launching, switching, development, workspaces, music production, and agent supervision. Replace the useful parts of Raycast/Floe, PortKiller, and Bartender progressively while preserving the fast Dock people already use.

## Read this plan

- [Implementation tickets and first PRs](IMPLEMENTATION_PLAN_2_0.md): dependencies, small reviewable chunks, acceptance criteria.
- [Architecture and permission boundaries](ARCHITECTURE_2_0.md): shared services, local inference, data lifecycle, feasibility decisions.
- [Validation and release gates](TEST_MATRIX_2_0.md): automated checks, physical Mac checks, performance budgets.
- [REA investigation playbook](REA_RESEARCH_2_0.md): study existing implementations and turn evidence into original Portside behavior.
- [Baseline record](BASELINE_2_0.md): P2-CORE-01 test seam, probe inventory, hand-check procedures and run results.

This extends [PLAN.md](PLAN.md), which retains the original A-F milestones, Dock parity, and historical decisions. [CHECKLIST.md](CHECKLIST.md) remains the source of truth for shipped work and outstanding hand checks. [FEATURES.md](FEATURES.md) describes only implemented features. New tickets use `P2-*` planning IDs, not GitHub issue numbers. Create tracker issues as implementation begins and link them beside those IDs.

## Principles and scope

1. Keep SwiftPM, the `portside` executable, SwiftUI/AppKit, Apple Silicon, and macOS 26+. Add focused types in the existing target before considering new targets. No Xcode-project rewrite or mandatory JavaScript runtime.
2. Preserve event-driven reveal/hide, non-activating Dock interactions, native Dock restoration, existing consent, and updater behavior. Heavy work never blocks the reveal path.
3. Build deterministic commands first. Local AI interprets or summarizes; native code validates and executes. No hosted inference, paid-provider token consumption, or automatic cloud fallback in Portside Intelligence.
4. Enable modules independently. A restricted work Mac can keep the Dock, native app launching, manual workspaces, and available commands with AI, scripts, capture, hooks, and integrations off.
5. Public APIs first. Existing guarded shims remain documented in [ARCHITECTURE.md](ARCHITECTURE.md). Competitor use of an undocumented mechanism is evidence to investigate, not permission to make it a new core dependency.
6. Ship usable slices behind off-by-default new feature flags. No mass file move, complete launcher parity, universal agent control, or extension marketplace is required for 2.0.

## Sequence and release gates

These are dependency gates, not calendar promises. Optional research and adapters may proceed once their prerequisites exist. A failed menu bar experiment must not block workspace or studio work.

| Phase | User-visible increment | Dependencies | Exit gate / release intent |
| --- | --- | --- | --- |
| 0: core and stability | Existing Dock remains dependable; shared commands, windows, modules, permissions | Current baseline and hand-check backlog | P2-CORE tickets; baseline regression matrix; no new permission prompts at launch |
| 0.5: local intelligence foundation | Apple on-device availability and typed intent adapter, initially exercised by fixtures | Commands and permission gate | P2-AI-01/02; unavailable model returns deterministic fallback, no network inference |
| 1A: Command Center | Configurable shortcut, apps, commands, settings, quicklinks | Module and command registries | P2-CMD-01/02; keyboard and VoiceOver complete; usable without AI |
| 1B: app/window switcher | Standalone switcher, MRU, shared Dock previews; optional Cmd+Tab later | Window registry, permission center | P2-SW-01/02 for alpha; 03/04 only after capture and interception gates |
| 1C: everyday tools | Scoped file search, clipboard/snippets, calculator, emoji, Shortcuts | Command Center and explicit data scopes | Optional P2-CMD-03 through 07; delay any tool that threatens core quality |
| 2: developer utilities | Find port owners, open local servers, safe stop, project grouping | Command Center and process service | P2-DEV-01 through 05; identity revalidation and refusal tests pass |
| 2 + 0.5 integration | “What's using port 5173?” returns verified native results | P2-AI-02, P2-DEV-02, P2-CMD-02 | P2-AI-03; first end-to-end AI slice, read-only by default |
| 3: menu bar | Searchable supported items; hiding/reordering only if proven recoverable (spike: hide/reveal and quit/SIGKILL recovery observed on one Mac, see the [report](research/P2-MENU-01-hide-recovery-spike.md)) | P2-REA-03 and menu bar feasibility spike | Conditional 2.1 scope; publish support matrix or ship discovery-only. After MENU-04, P2-MENU-05 to 14 extend the module toward the documented Thaw feature set (see below) |
| 4: workspaces/windows | Develop, Studio, Everyday layouts; explicit restore and undo | Shared windows/commands/settings | Suggested 2.2; partial failures visible, no automatic layout surprises |
| 5: studio companion | Audio switching, project/export shelves, optional Live bridge | Scoped files, workspaces, audio events | Suggested 2.3; bridge disconnect cannot disrupt Live; recording stays quiet |
| 6: advanced supervision | Reliable agent attention inbox, checkpoints, approved bounded plans | Existing agent discovery, local AI, verified commands | Suggested 2.4+; unsupported provider actions remain jump-to-session |
| 7: optional extensions | Capability-scoped command providers in isolated helpers | Stable native contracts and permission gate | Separate opt-in milestone after threat model and crash containment |

**2.0 alpha:** Phase 0, Apple availability/typed intents, native launcher, title/icon switcher. **2.0 beta:** previews, safe developer manager, read-only AI port lookup; selected productivity tools. **2.0 stable:** those completed slices pass the signed-app matrix, recovery, accessibility, and work-Mac gates. Cmd+Tab replacement is conditional; the alternate-shortcut switcher is a valid release fallback. Optional LM Studio/Ollama, MLX, semantic indexing, full menu bar parity, studio control, and extensions are not blockers for 2.0.

### Phase 3 extension: Thaw feature-set target

Decision (2026-11-08): the documented feature set of Thaw is the minimum functionality target for the Menu Bar module. Portside implements it independently from public documentation and Apple APIs; no reuse of names or assets, and no Thaw code copied (it is GPL-3.0). Revised 2026-11-09 at the maintainer's direction: Thaw 3.0.0-alpha.13 was reverse engineered and its source read to match its menu bar hiding behavior; see thaw-simple-mode-analysis.md. Existing MENU-01 to MENU-04 scope, status, gates and release priority are unchanged. The tickets below come after MENU-04, are conditional 2.1 scope, and do not block Phases 4 to 7 or 2.0 stable. Details, dependencies, acceptance and feasibility gates are in the [implementation plan](IMPLEMENTATION_PLAN_2_0.md#phase-3-extension-thaw-feature-set-target-menu-05-to-menu-14).

| Ticket | Capability (user-visible) | Main feasibility risk |
| --- | --- | --- |
| P2-MENU-05 | (prototype built, hand gate open) Visible, Hidden and Always Hidden sections; layout editor with a Move to menu and drag between sections, applied on demand | Per-item movement beyond MENU-04's validated set; items clipped under the notch |
| P2-MENU-06 | (built, hand gate open; click, hotkey, empty-bar click, scroll and rehide on, hover optional) Reveal by click, hotkey, optional hover/scroll on empty bar; automatic rehide | Secure input; hover trigger near menus and notch |
| P2-MENU-07 | Portside Bar: hidden items in a panel below the menu bar | Clicking items that are hidden or covered; live previews need Screen Recording |
| P2-MENU-08 | Global hotkeys, open-by-key and per-item open | Secure input; shortcut conflicts |
| P2-MENU-09 | Item groups and saved profiles | Applying a profile on a crowded bar |
| P2-MENU-10 | Hide/show app menus and Zen Mode | No known public API for app menus; needs its own spike |
| P2-MENU-11 | Menu bar appearance (tint, gradient, shadow, border, shape) | Overlay window level with notch, full screen and Spaces |
| P2-MENU-12 | Item spacing | Requires writing a global defaults domain; needs a decision record |
| P2-MENU-13 | `portside://` URLs, Shortcuts actions, Control Center control | Packaging of App Intents from a SwiftPM executable |
| P2-MENU-14 | Settings page, reset, support matrix per OS/display, manager coexistence | macOS 27 menu bar order access and its permission |

Every ticket keeps the shared recovery rules: fail-open at launch, an always-reachable kill switch, native bar restored on quit or `kill -9`, sleep/wake/display change reveal, no writes to other apps' preferences, off by default.

## Consistent UX across surfaces

Use one set of entities and actions across Dock, Command Center, switcher, and notch. “Glance, inspect, act” means compact status first, details on demand, and a clearly labeled primary action. Keep harbor navy, cream, and safety orange; use orange for attention and interaction, never as the only status cue. Use native typography, visible focus, VoiceOver names, Reduce Motion, and Reduce Transparency.

| Surface / gesture | Contract |
| --- | --- |
| Dock click / hover | Click keeps current launch/activation expectations. Delayed hover may reveal compact previews; never starts AI, stops a process, or changes transport |
| Command Center | Default candidate Option-Space, configurable and conflict-checked. Return executes primary action; Cmd+K shows secondary actions; Tab opens details; Escape backs out then dismisses |
| Switcher | App-first by default. Tab cycles, Shift-Tab reverses, arrows select windows, release the held modifier commits, Escape cancels. Fast switch should not flash a large panel |
| Window-first mode | Configurable alternate shortcut; shows window MRU across apps. A latched search mode accepts text without held-Command shortcut conflicts |
| Notch/menu bar | Passive attention and recording status, explicit click to inspect. No hover execution or focus stealing |
| Settings | Capabilities and integrations, permission reasons, unavailable states, local-model choice, retention and clear-data controls |

### Concrete journeys

**Find and stop a server.** Type `5173`, select `Portfolio UI · :5173`, Return opens its validated local HTTP address. Cmd+K offers “Copy URL”, “Reveal project”, and “Stop server”. Stop shows executable, owner, PID, port, and project if verified. A force stop appears separately only after graceful termination fails. Natural language “what's using port 5173?” produces the same card through local inference. “Stop it” requires an unambiguous current target and approval; a model never manufactures a PID.

**Switch to the right editor.** Hold the configured shortcut, cycle to VS Code, then choose `Portside` from its available windows. Previews appear only after capture consent, with display and minimized badges. Without capture permission, icons/titles remain. Without Accessibility, show apps only. Closed windows disappear safely. If optional Cmd+Tab interception fails, native switching remains available; use the alternate shortcut or menu entry.

**Organize the menu bar.** Search an observed status item and activate it only through a verified supported path. An unsupported item says why and stays in the native bar. “Hidden” and “Reorder” controls are absent until the feasibility spike proves recovery after quit/crash and OS changes. The notch and shelf share collision-aware layout. Do not promise to move system-owned items or recover icons already clipped by the notch without evidence.

**Start Studio.** Select Studio manually; review requested apps, Dock layout, optional window moves and audio-device changes. Missing display/interface gets a recoverable partial-result card. A recording indicator defers automatic changes and nonessential inference. With no reliable bridge recording state, use a manual “Recording / Quiet Studio” toggle rather than inferring recording from audio playback.

**Find a bounce.** Choose an export folder once, then the shelf shows a stable newly written WAV/MP3 with reveal, audition, and drag actions. It does not move files on discovery. Project BPM/key comes from verified metadata or manual tags; dedicated DSP estimates are labeled with confidence, never asserted by an LLM.

**Check an agent.** The existing notch shows “Last observed activity 4 min ago”, “Needs approval”, “Completed”, or “Unknown”. A local summary cites permitted session events. “Open session” always works when a focus route exists; “Approve” or “Cancel” appears only with a supported authenticated provider API. CPU activity alone is not task progress.

## Replacement boundaries

| Reference app | First useful replacement | Deliberately later / conditional |
| --- | --- | --- |
| Raycast / Floe | Native launcher, command actions, quicklinks, files, selected productivity tools | Unmodified Raycast extensions, hosted AI, universal compatibility |
| PortKiller | Inspect listeners, project grouping, safe terminate | Privileged processes, arbitrary process-tree kills, automatic cleanup |
| Bartender and Thaw | Feasibility report, supported-item search/activation; Thaw's documented feature set is the minimum target for the Menu Bar module (own implementation, no REA, no Thaw source) | Each feature only where proven and recoverable; private-API parity is not assumed; a failed gate removes that ticket, not the module |
| Window utilities | Specific-window activation, basic snap/move/restore | Arbitrary Spaces assignment, invisible/minimized-window capture guarantees |
| Studio utilities | System audio selection, local shelves, read-only Live state | Hardware-specific preamp/routing controls, editing unsaved Live sets |

Use [REA](REA_RESEARCH_2_0.md) to study specific behavior where source/docs do not answer the question. Rebuild the behavior as small Portside-native slices; do not add a dependency simply because a reference app uses it.

## Maintaining the roadmap

Each implementation PR names ticket IDs, records evidence and test limitations, and updates the existing checklist. Mark tickets done only when their acceptance criteria and relevant test rows pass. Update the current architecture/data docs as code lands; these proposal documents must not imply new types or keys already exist. Keep failed spikes and support limitations linked so later contributors do not repeat them.

### Menu bar parity audit, 2026-11-09

[Interaction audit](research/P2-MENU-06-interaction-audit.md) lists the defects found and their follow-up. MENU-06 remains experimental. Thaw hide, reveal and rehide rules plus groups, saved order and profiles are built and most were run natively on one notched macOS 27 display; hover, scroll, real Command-drag drops, automatic profile switching, external displays and macOS 26 remain open.
