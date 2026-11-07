# REA research for Portside 2.0

Planned workflow, 2026-11-06. [Roadmap](ROADMAP_2_0.md) · [Research tickets](IMPLEMENTATION_PLAN_2_0.md#research-track-existing-implementations) · [Architecture boundaries](ARCHITECTURE_2_0.md)

Use [morluto/rea](https://github.com/morluto/rea) where a shipped artifact or runtime observation can answer how Raycast, Bartender, PortKiller, or a selected switcher implements a relevant behavior. Use normal source inspection for Portside and available open-source Floe code. REA is a research aid, not a Portside runtime dependency. This plan does not claim those products have already been comprehensively analyzed or rebuilt.

## Starting evidence and remaining work

Local discovery found `/Applications/Raycast.app`, `/Applications/Bartender 7.app`, and `/Applications/PortKiller.app`. No Floe or Thaw app was found in the two immediate application directories inspected (`/Applications` and `~/Applications`); that bounded search does not establish absence elsewhere. These paths select research candidates only. Hash and version them again when each investigation begins, since installed apps may update.

A first read-only REA manifest inspection established this target identity:

| Fact | Evidence |
| --- | --- |
| Target | Bartender 7, bundle `com.surteesstudios.Bartender`, version `7.1.0`, build `700013` |
| Artifact inspected | `/Applications/Bartender 7.app/Contents/Info.plist` only |
| SHA-256 of that plist | `c0520715c995b40857899a32eda5bffde2350640b21a2cb1680d4447dc1dcaf9` |
| REA operation / evidence ID | `inspect_plist`; `ev_445ac1c1c5d225d96644004b7941d310a91fa025d778ec95df9d637e7b873b24` |
| Authority / confidence | Shipped artifact / observed metadata; macOS native plist parser |
| Coverage limit | No executable decompilation, imported API analysis, hide/reorder behavior, permission behavior, or runtime action was established. The plist hash is not the application/executable hash. Evidence ID identifies this session observation; a portable bundle must be exported during the implementation investigation. |

The manifest is a reproducible starting point, not evidence that a particular menu bar technique works. Raycast and PortKiller versions/implementation remain unexamined. The native REA session was closed after the manifest check. Research tickets remain not started for their substantive questions.

## Questions and deliverables

| Ticket / reference | Bounded questions | Evidence needed | Portside result |
| --- | --- | --- | --- |
| P2-REA-01: Raycast; Floe when selected | How do search, nested actions, selection, cancellation and focus restoration interact? What is native vs extension-host behavior? | Versioned artifact/resources plus selected runtime journeys; source where available; imports/call paths only for unresolved mechanisms | Native Command Center state table, ranking assumptions and CMD-01/02 acceptance fixtures; extension compatibility kept separate |
| P2-REA-02: PortKiller | How are listeners discovered/grouped/refreshed? What exact stop action and process identity checks occur? | Discovery command/API evidence; static path; disposable owned server runtime observation | DEV-01 parser/service options and DEV-03/04 safe-stop scenarios; improve safety where reference evidence is insufficient |
| P2-REA-03: Bartender | How are status items identified, hidden, revealed, reordered and restored? Which steps depend on private APIs or undocumented AX shape? | Exact-version import/call/resource evidence, bounded AX observation and owned test-item lifecycle; permission-denied and recovery tests | MENU-01 capability matrix and go/limited/no-go decision; original public-first implementation or discovery-only fallback |
| P2-REA-04: selected switcher / native macOS | How do fast tap, held navigation, modifier release, window MRU and cancellation behave? | Explicit reference selection and controlled keyboard/focus journeys; scoped static analysis if a named app is available | SW-01/02/04 state machine and failure fixtures; no assumption all windows/Spaces are observable |

## Staged procedure

1. **Select the question and artifact.** Record app/version, bundle ID, executable and resource hashes, architecture, OS, source tag when available, REA version and provider. Reuse existing matching evidence. Inspect the actual connected tool schemas; do not assume repository-main capabilities exist in an installed tool release.
2. **Inspect the smallest useful boundary.** Native binary/app: `open_binary`, metadata/imports/symbol search, then focused function/call-path analysis. JavaScript/ASAR: `analyze_javascript_application` with summary delivery, then specific feature tracing. Package resources: format-aware inventory/parsers. Full source tree: normal repository tools. Do not run decompilation merely to confirm a fact already in source or documentation.
3. **Write a behavioral hypothesis.** Example: “revealing hidden items temporarily changes layout, then restores it on dismissal.” Label as inferred until supported. Imported symbols and strings are candidates, not evidence an action ran or that its whole implementation has been recovered.
4. **Observe one controlled scenario if needed.** Select the exact running app/PID/window and permitted scenario; use passive `observe_native_ui` where available. Explicitly scoped runtime probes may be used for unanswered mechanisms. Do not automatically inject into unrelated processes, change security settings, inspect account tokens, launch paid operations or mutate normal work data. Use a disposable server/window/menu-item fixture for destructive or recovery scenarios.
5. **Record results and unknowns.** Keep Evidence IDs, artifact hashes, provider/OS, relevant locations, coverage limits and observation vs inference. Use retained evidence summaries/pages instead of re-running large analyses because output was truncated. Export a portable evidence bundle locally and close native sessions. Commit a sanitized finding ledger, not proprietary binaries or raw user data.
6. **Translate into a Portside contract.** Describe inputs, states, events, outputs, failure and recovery. Identify a public API route. If none exists, explicitly choose reduced scope or a separately reviewed isolated guarded shim with a native fallback; never silently import a competitor's private mechanism.
7. **Implement and compare.** Write original Swift code against the contract and Portside's registries. Compare defined scenarios with the reference, preserving version/OS limits. A finite reconstruction verification or test pass covers only its declared scenarios, not full product equivalence.

Use observed behavior to inform an independent implementation. Do not commit decompiled proprietary code, licensed assets, credentials or reference application binaries. For open-source code reuse, record the upstream revision and license/attribution requirements separately. There is no need to rebuild a competitor's architecture or licensing/update machinery to reproduce a useful interaction.

## Report template

Create a small report under `docs/research/` when the associated investigation runs. Completed so far: [P2-REA-01](research/P2-REA-01-command-center-interaction.md) (docs and metadata only, no runtime journey). Other tickets remain not started.

```text
Question and planning ID:
Reference app / version / bundle / source revision:
OS / architecture / artifact SHA-256 / REA provider version:
Scenario and exact search/observation boundary:
Observed behavior (Evidence IDs + retained/exported evidence location):
Inferred mechanism (basis and confidence):
Unknowns / truncation / unsupported environment:
API classification (public / undocumented shape / private):
Portside contract and intentional differences:
Permission, privacy, recovery and resource constraints:
Decision (implement / limited fallback / no-go / further probe):
Acceptance fixture and dependent implementation ticket:
```

No-go is a valid result. For example, if reliable third-party hide/reorder cannot be demonstrated with acceptable recovery, ship supported-item search and retain Bartender alongside Portside. Revisit only when OS APIs or new evidence change the decision.
