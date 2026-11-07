# Portside 2.0 architecture proposal

Proposed, not implemented. [Roadmap](ROADMAP_2_0.md) · [Tickets](IMPLEMENTATION_PLAN_2_0.md) · [Tests](TEST_MATRIX_2_0.md) · [Current architecture](ARCHITECTURE.md)

## Reuse before extraction

The baseline package uses Swift tools version 5.10, `.macOS("26.0")`, the `portside` executable, and the `AppLoginItemList` helper target. Preserve that structure. A modern SDK/compiler may be needed for Foundation Models macros without changing the deployment floor or introducing an Xcode project. Compile and availability-check against the supported SDKs; do not use newer framework-wide cloud capabilities accidentally.

| Existing component | Proposed evolution |
| --- | --- |
| `DockEngine`, `EdgeTracker`, `DockPanel` | Keep reveal ownership and non-activating behavior; consume snapshots, never wait on new services |
| `OverlayPanel`, `DockHover` | Share preview content/layout rules; add a separate key-capable search panel instead of making all Dock panels activating |
| `RunningApps` | Source app lifecycle and activation events for registries/MRU |
| `WindowFitter`, `DockReservation`, `AgentFocus` | Extract common AX identity/observation incrementally; retain existing timeouts, retry limits, and reserved-space behavior |
| `WidgetHost`, `WidgetProtocol`, `WidgetLayout` | Adapt commands/status from enabled modules; do not replace widget lifecycle wholesale |
| `AccessibilityTrust`, `UsageConsent` | Feed the permission facade; keep existing specific consent separate |
| `DockModel` | Add versioned module configuration; preserve unknown top-level keys and documented backups |
| `AgentSessionDiscovery`, `AgentHooks`, notch | Extend event normalization and per-provider capabilities; keep read-only discovery paths |
| `AppActivity`, `AudioPlayback`, `FolderStack` | Reuse audio property listeners, privacy-preserving levels and FSEvents concepts |

New files may live under `Core/Commands`, `Core/Windows`, `Core/Modules`, `Core/Permissions`, `Core/Intelligence`, and `Features/<module>` within `Sources/portside/`. These are proposed locations, not instructions for moving all existing files. Add a pure SwiftPM test target for new contracts after a minimal importability spike; introduce a small library only if executable-target testing requires it.

## Shared contracts

| Service | Owns | Must not own |
| --- | --- | --- |
| `CommandRegistry` | Stable namespaced command IDs; typed input/output schema; availability; search metadata; risk/scope; cancellation; native handlers | UI, raw model prompts, unrestricted shell execution |
| `WindowRegistry` (built, P2-CORE-06) | App/window snapshots, ephemeral identity, MRU and display association; bounded AX observation | Reveal timing, persistent claims that a CG window number identifies the same window forever, moving or fitting windows |
| `ModuleRegistry` | Capability declarations, enabled state, dependency readiness, start/stop, subscription lifetime | Another Dock coordinator or duplicate widget refresh loops |
| `PermissionGate` | OS permission observations, module/data scopes, execution approval, denial reason | Granting TCC, overriding MDM, treating saved consent as current OS permission |
| `IntelligenceEngine` | Deterministic-vs-model routing, context minimization, typed intent proposals | Executing model output directly |
| `ModelRouter` / `LocalModelProvider` (foundation built, P2-AI-01; no real provider yet) | Availability, inference, cancellation, provider-specific limits and lifecycle | Silent cloud fallback or automatic runtime installation |
| `LocalContextStore` | Explicitly opted-in metadata with provenance, scope, retention, deletion | Ambient clipboard/document/screenshot collection |
| `AgentOrchestrator` | Bounded plan state and receipts through registry/gate | Separate powerful tools that bypass command approval |

`ActionRegistry` from the discussion means a filtered tool view of `CommandRegistry`, not a second mutable action catalog. All surfaces call the same executor. Suggested descriptor fields: `id`, `moduleID`, localized title/keywords, input schema, required capabilities, availability reason, side-effect category, approval policy, handler, timeout, and undo support. Validate input bounds and fresh target identity before executing, regardless of whether the caller is a person, shortcut, or model.

Use immutable snapshots and cancellation-aware event streams. App lifecycle comes from NSWorkspace, windows from AXObserver, display changes from AppKit notifications, folders from FSEvents, audio from property listeners, and process exit from dispatch sources where available. Bounded/coalesced work runs away from the main thread; AppKit presentation stays on the main actor. Slow AX targets time out independently. Disabled modules cancel tasks and release observers, captures, handles, and caches.

There is no universal public push feed for all new TCP listeners or clipboard changes. Use explicit refresh first; if needed, a bounded visible-panel listener refresh and opt-in pasteboard change-count sampler are documented exceptions outside reveal/hide. No inference polling. Polling must stop when its consumer is disabled or its documented collection scope is inactive.

## Permission and work-Mac model

Track at least `notRequested`, `granted`, `denied`, `unavailable`, and `restrictedOrUnknown`. macOS may not reveal whether MDM caused a denial, so do not fabricate a managed-policy diagnosis. Present “Unavailable on this Mac; contact your administrator if managed” when the source cannot be established. Recheck on foreground return, capability use, and available permission events; revoke running work promptly.

| Capability | Request moment | Degraded mode |
| --- | --- | --- |
| Accessibility | Enable window discovery/focus/move or supported menu inspection | App-only launcher/switcher, manual window placement |
| Screen Recording / capture | First explicit preview enablement, independently of AX | Titles/icons; purge captured images on revoke/lock |
| Keyboard interception / Input Monitoring where required | Explicit switcher replacement setup; verify actual TCC requirements for the selected tap | Native Cmd+Tab, alternate registered hotkey or menu entry |
| Automation | Explicit supported target-app action | Open target app and show why deeper action is unavailable |
| Folder scope | User selects search/project/export roots | Apps/commands still work; no whole-disk crawl |
| Clipboard history | Separate explicit enablement with exclusions and expiry | Snippets/manual paste only |
| Local intelligence | Explicit enablement and data scopes | Native exact search and commands |
| Local external runtime | Select runtime, endpoint and verified local model | Apple on-device if separately enabled and available, otherwise no AI |
| Microphone / System Audio Recording | Only features actually needing those streams | Existing non-capture audio activity and supported device metadata |
| Agent logs/hooks | Per-source read consent; explicit hook install/remove | Open app/session; no reading unrelated work logs |

Full Disk Access is not a general prerequisite and cannot substitute for capture, Accessibility, Automation, or corporate policy. Restricted mode disables scripts, external runtimes, broad indexing, hooks, interception, and capture individually; it must not attempt security-setting resets automatically. Existing AI Usage network requests retain their own consent and are separate from local inference. “Local-only Intelligence” does not claim that weather, updater, artwork, or opted-in usage services never contact the network.

## Local-only intelligence

Apple's [`SystemLanguageModel`](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel) is the explicit on-device backend. Check availability at use time, including eligibility, Apple Intelligence disabled, model readiness, language/region and OS-dependent errors. Use [guided typed generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation) for a small intent enum; schema validity does not establish factual accuracy or authority. The framework name alone is not a local-only guarantee.

Pipeline: explicit request -> deterministic lookup if possible -> minimal approved context -> local typed proposal -> command/input validation -> current permission/target check -> concrete approval when needed -> native action -> factual receipt. Begin with `findPortOwner(port: UInt16)` through P2-AI-03. The model extracts a port; the process service supplies ownership. Range-check 1...65535 and reject ambiguous requests. No free-form shell tool.

| Provider | Scope / gate |
| --- | --- |
| Apple Foundation Models | Default when enabled and available; bind the on-device model, exclude PCC/hosted routes; refuse or use native fallback when unavailable |
| [LM Studio](https://lmstudio.ai/docs/developer/core/server) | Optional external local server; capability-probe the chosen API version and loaded local model; remote/LAN/linked backends and server tools disabled |
| [Ollama](https://docs.ollama.com/faq) | Optional external local server; reject cloud models and require cloud features disabled plus offline validation for supported runtime versions |
| [MLX Swift](https://github.com/ml-explore/mlx-swift) | Later opt-in embedded-provider spike; verify compiler, Metal packaging, model license/size/checksum, memory pressure and unload behavior before adding dependencies |

**Loopback is necessary, not sufficient.** A localhost server can proxy to cloud services. Permit literal loopback addresses with user-selected ports, reject userinfo, non-loopback destinations and redirects, and disable proxy use for inference connections. Verify backend configuration and installed model identity where the runtime exposes evidence. If local execution cannot be established for a runtime/version, mark it unverified and unavailable for guaranteed-local mode. Never claim a malicious external server is attested by a health response. External provider setup and release tests must demonstrate inference with external network access blocked; provider updates invalidate compatibility evidence. Do not silently edit the runtime's preferences or start downloads. Downloading weights is a separate explicit network action, never an inference fallback.

Do not reuse Claude/Copilot sign-in tokens for inference. Exclude keychain values, environment secrets, full process arguments, private file contents, clipboard and work logs by default. Treat titles, logs, filenames and retrieved text as untrusted data; instructions in them cannot expand tools or permissions. Summaries include source/time and mark uncertainty. Semantic search requires a separately justified local embedding/index provider; Foundation Models is not assumed to expose embeddings or knowledge of hidden browser tabs.

One foreground inference at a time initially; bounded context/output, explicit cancel, timeout and busy state. Load on demand, reuse only bounded sessions, and release idle resources where supported. Suspend background suggestions on memory pressure, battery/thermal pressure and recording/Quiet Studio. Apple owns system-model residency; do not promise to unload it. Runtime model unloading is only for sessions/models Portside owns, with consent; never unload another app's active model.

## Plans, risk and consent

Read, prepare and execute are separate capabilities. A prepared plan contains ordered command IDs, normalized arguments, exact target identities, risk labels and expected preconditions. Approval binds that concrete plan and expires on edits, permission changes, changed target identity or timeout. Revalidate each step immediately before action. A process is identified by PID plus start identity and ownership, not PID alone; a window is validated against its live app/process/AX identity.

Plan states: draft -> validated -> awaiting approval -> running -> completed / partially completed / failed / canceled. Default initial orchestration limits: five steps, one in-flight action, 30-second action deadline unless a command declares a tighter bound. Cancellation stops future steps and cancels supported work; it cannot undo a terminated process. Never retry non-idempotent actions blindly. Keep explicit receipts, skip reasons and compensating actions only where valid. No automatic resume after crash without refreshed targets and approval.

Dangerous actions such as terminate, delete, settings changes and scripts need concrete confirmation. A normal explicit app launch does not need a second dialog. Autonomous background file mutation is out of scope. Scripts arrive later as user-owned, reviewed commands, with argument arrays, fixed executable, working directory, timeout, sanitized environment, and scoped access; model text is never interpolated into a shell.

## Persistence and privacy

Keep user-facing flags/configuration in `dock.json`; an explicit `settingsSchema` distinct from `savedByVersion` and a raw-preserving `modules` object exist since P2-CORE-05 (see [DATA.md](DATA.md)). Existing backups and unknown top-level key preservation remain. Test nested forward compatibility before adding nested module settings; current [DATA.md](DATA.md) explicitly warns unknown nested values can be lost. Permission status is queried from macOS, not restored as granted from JSON.

Use separate versioned stores under Portside Application Support for optional search metadata, workspace definitions and minimal execution receipts. Set private directory/file permissions; cap size and retention. Clipboard history needs at-rest protection, pause/exclusion controls, expiry and deletion before shipping. No plaintext clipboard or raw prompts in logs/backups. Window previews stay memory-only with byte/age caps; discard on lock, revoke and module disable. Scoped-file bookmarks are refreshed when stale and access ends when no longer needed. Deleting a scope also purges derived metadata/embeddings and pending model context.

## Feasibility boundaries

| Area | Public starting point | Required investigation / fallback |
| --- | --- | --- |
| Window enumeration/focus | NSWorkspace + AXObserver/AXUIElement | Apps may omit titles, refuse actions or hide windows; app activation fallback; no guaranteed Spaces assignment |
| Previews | [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) | Capture only selected/visible cards on demand; minimized/protected windows may lack frames; title/icon fallback |
| Cmd+Tab | [CGEvent taps](https://developer.apple.com/documentation/coregraphics/cgevent) | No dedicated replacement API; validate secure input, denied access, timeout/user-disabled taps, modifier loss, keyboard layouts and crash recovery; native fallback |
| Menu bar | [NSStatusBar](https://developer.apple.com/documentation/appkit/nsstatusbar) for own items; bounded AX for exposed items | These APIs do not establish arbitrary third-party hide/reorder support. Spike each behavior and OS version; supported-item search-only is acceptable |
| Ports | Bounded `/usr/sbin/lsof` machine-readable listener inspection, process metadata and exit events | No elevated helper; missing/denied process data stays unknown. Capture subprocess output with limits, not shell interpolation |
| Ableton | [Live API / Live Object Model](https://docs.cycling74.com/userguide/m4l/live_api_overview/) through optional Max for Live bridge | Validate target Live edition/version and Max for Live availability; read-only first, authenticated loopback protocol, no UI scripting fallback for transport |
| Audio | Public Core Audio properties/listeners | Verify settable properties and hardware support; OS default device need not equal Live's selected device; do not promise Apollo internal routing |

These references were consulted on 2026-11-06. API documentation supports the starting points, not proof of feature parity. [REA evidence](REA_RESEARCH_2_0.md), minimal prototypes and physical-machine tests decide support claims. Record any proposed private shim separately with rationale, OS scope, documented fallback and review before adoption; menu bar and switcher research may conclude “do not ship”.
