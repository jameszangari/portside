# Portside 2.0 test matrix and release gates

Proposed validation requirements, not completed test results. [Roadmap](ROADMAP_2_0.md) · [Tickets](IMPLEMENTATION_PLAN_2_0.md) · [Architecture](ARCHITECTURE_2_0.md)

## Environments

Test the deployment floor (macOS 26) and the current target macOS 27 release with exact OS/build, SDK/compiler, app commit, signing identity type, hardware, display setup and permission state recorded. The existing docs contain macOS 27 observations; they do not substitute for macOS 26 checks. Use Apple Silicon throughout. User-relevant machines are M4 Max / 64 GB personal and M3 Pro / 36 GB managed work Mac; these are test targets from the discussion, not devices this plan has tested. Include a lower-memory supported Mac before promising MLX model sizes.

| Axis | Required cases |
| --- | --- |
| Distribution | SwiftPM debug; fresh ad hoc bundle; stable Developer ID signed/notarized install; upgrade from prior release; downgrade with newer settings |
| Displays | Built-in notch; external without notch; mixed scale; multiple displays; disconnected display; lid closed/open; sleep/wake; empty-screen transition |
| Window environment | Spaces, fullscreen, Stage Manager, minimized/hidden windows, non-resizable/slow AX apps, external window managers, Settings on another Space |
| Accessibility | AX/capture/interception independently not requested, allowed, denied and revoked; VoiceOver; keyboard-only; Reduce Motion/Transparency; light/dark; non-US layout and IME |
| Work Mac | Apple Intelligence disabled/not-ready, no external runtime, no admin, scripts/hooks blocked, restricted folders, denied AX/capture/Automation, corporate proxy; no bypass/reset by Portside |
| Load | Idle, many apps/windows, 27+ Dock apps and widgets, server churn, model inference, high memory pressure, battery saver/thermal pressure, active audio recording |
| Network | Offline; loopback available with external egress blocked; backend absent/restarted; malicious redirects and remote-model selection; existing weather/update/usage requests separately opted in |

Run the full cross-product only where a failure suggests an interaction. For each module, cover all relevant permission states and at least one pairwise interaction with display/load/OS differences. Native Dock crash restoration, Cmd+Tab interception, menu bar recovery and recording safety require physical signed-app tests on both supported OS versions before enabling their new behavior broadly.

## Automated and manual rows

| ID | Scenario / method | Expected result / evidence |
| --- | --- | --- |
| T-01 core | Existing build and launch; reveal/first-click/drag/hide at all edges; widgets, stacks, notch, settings | Zero new reveal-path polling; no focus-stealing pre-click; existing gestures retained; timing trace and physical notes |
| T-02 recovery | Sleep/wake, lid, unplug, fullscreen/Space transition, crash watchdog in disposable test account | No crash with no displays; panel returns; native Dock exact values restored only when hide feature enabled; no global preference experiments on daily-use account |
| T-03 settings | Legacy/missing/invalid/future JSON, nested unknown fields, backup and downgrade | Existing layout survives; defaults preserve old behavior; new modules off; backups once and readable; tests verify values, not serialized whitespace |
| T-04 registries | Duplicate commands, module start/stop cycles, unavailable dependency, cancellation, permission revoke | Handler not invoked without capability; no orphan observers/tasks; one result; UI gets reason; module failure isolated |
| T-05 launcher | Fast query edits, 1,000 fixture commands, hotkey collision, IME, Escape/Tab/Return/Cmd+K | Latest query wins; deterministic order; no conflict silently overridden; keyboard/VoiceOver complete; focus restored |
| T-06 windows | App relaunch/PID reuse, close while selected, slow AX, minimized/off-Space/protected window | Never acts on a different target; app-only/icon fallback; no blocked main thread; recorded unsupported cases |
| T-07 previews | Capture denied/revoked, screen lock, module off, many cards, rapid hover | No capture without explicit scope; no persistent images; bounded memory; shutdown and purge observable; unavailable frame uses placeholder |
| T-08 switcher | Quick Cmd+Tab, held/reverse cycling, selected window, release, Escape, modifier loss, secure input, tap timeout, app quit/crash | Selected app/window only; no stuck modifier or swallowed unrelated keys; fail-open native next chord; alternate shortcut remains discoverable; require OS-specific physical results |
| T-09 ports | Disposable HTTP/TCP child servers; IPv4/IPv6/wildcard, multiple listeners, permission denial, malformed/truncated lsof | Correct parsed owner or unknown; protocol not guessed; bounded output/time; no privileged probe or network-wide scan |
| T-10 stop | Owned fixture child; PID start identity changes before approval or execution; child exits; wrong UID; SIGTERM timeout | Reject stale/privileged/unknown target; SIGKILL separate confirmation and revalidation; no process-group kills; exact receipt; no unrelated processes touched |
| T-11 local model | Fake + actual Apple provider; disabled/not-ready/refusal/context error, unsupported locale, cancel, timeout | Deterministic commands work; no tool from malformed output; no late action after cancel; local provider label accurate |
| T-12 no-cloud | External egress blocked after model provision; endpoint redirects, proxy, remote model IDs, server cloud mode, wrong runtime version | Apple local and eligible local backends work offline; refused configurations cannot infer; no provider-token reads; loopback alone never treated as proof; retain packet/process observations without content secrets |
| T-13 prompt injection | Titles, files, clipboard, logs contain fake system instructions and command payloads | Cannot add tool/scope, bypass approval or interpolate shell; invalid intent rejected; approved target still comes from native service |
| T-14 privacy | Consent off, excluded app/root, scope removal, purge, crash logs, backups, locked screen | No collection while off/excluded; derived data removed; preview buffers gone; raw secrets/prompts/clipboard absent from logs; at-rest clipboard controls verified |
| T-15 menu bar | Third-party and system items, same-app multiple items, notch clipping, owner restart, denied AX, disable/quit/crash | Per-behavior support matrix; unsupported items remain native; no trapped hidden items; recovery evidence required before hiding/reordering ships |
| T-16 workspace | Drag/menu active, missing display/app, minimum-size windows, competing tiler, restore twice, partial failure, undo | Defers unsafe transition; preview truthful; bounded adjustment, no oscillation; no false all-or-nothing success; undo only valid targets |
| T-17 studio | Interface unplug/change, unsupported property, Live absent/edition mismatch, bridge stale/reconnect/duplicate request | No crash or forced device change; explicit unsupported state; no stale/duplicate transport action; source session unchanged after disconnect |
| T-18 recording | Known bridge record state and manual quiet mode, heavy model load, hover/actions | No focus steal or hover transport; background inference/auto switching paused; no new audible glitch under agreed setup; audio buffers never retained |
| T-19 shelf | Growing export, rename/delete, symlink outside root, denied folder, network volume gone | Only stable file advertised; no source move/overwrite; watcher cancels; blocked volume does not freeze UI; confidence labels on DSP estimates |
| T-20 agents | Hook/DB fixtures, malformed payload, clock skew, duplicate event, unsupported provider action, session expires | Working/waiting/stale/unknown correctly distinct; no CPU-as-progress inference; approval never sent to wrong session; unsupported actions jump to session |
| T-21 plans | Changed plan/target/permission after approval, canceled third step, partial failure, crash/resume | Approval invalidated; no later execution after cancel; receipt lists exact outcomes; no blind retry or silent resume; undo accurately limited |
| T-22 extensions | Helper crash/hang, invalid message, expanded permission on update, denied file/network, disable/uninstall | Core responsive; enforced resource/capability limits; re-consent on expansion; no arbitrary host execution; scope and derived data removed |
| T-23 existing services | Signed updater, Calendar/Downloads consent, usage consent and proxy behavior, native menu/recents | Existing hand checks retained and linked; no newly claimed implementation; no token logging; no release install during unattended docs validation |

## Performance gates

These are proposed budgets to measure in CORE-01, not claims about current performance. Record baseline and change on the same hardware/OS with other workloads stated. Use signposts, Instruments or bounded debug traces; never log user content. Investigate regressions before relaxing a threshold and record the reason in the PR.

- Dock reveal begins within about one frame (roughly 16 ms at 60 Hz), preserving the original goal; measure event-to-animation start over at least 100 interactions. New service work must not add synchronous blocking to that path.
- Warm Command Center and standalone switcher show initial cached UI within 100 ms at p95 over 100 invocations; 1,000-command literal search returns within 50 ms at p95. File/AI results arrive asynchronously with cancel and progress.
- No new main-thread task exceeds 50 ms in normal interaction traces. AX, process enumeration, indexing and inference are off the critical path with deadlines and cancellation.
- Proposed new preview-cache cap: 32 MiB, visible cards plus a small bounded reuse set, maximum age 10 seconds. Verify actual allocation and purge; adjust with measured evidence rather than silently growing it.
- With new modules disabled, a 10-minute idle run has no module timers/capture/inference and memory/CPU within baseline noise. With launcher alone enabled, target no more than 20 MiB incremental steady memory and 0.5 percentage-point average CPU on the baseline machine.
- Model latency/peak memory are provider-specific: report time to first output, total time, peak memory and cancel latency for a fixed small intent set. The release gate is responsive native UI, bounded inference, no OOM and pressure/quiet-mode suspension, not a guessed universal model speed.
- Repeat 100 enable/disable/open/close cycles: no monotonic observer, task, handle or memory growth after settling. Studio load runs must record buffer size/sample rate/interface and dropouts rather than asserting “zero impact” from an idle test.

## Execution procedure

Follow [BUILD.md](BUILD.md) and [AGENTS.md](../AGENTS.md). Run `source scripts/swift-env.sh`, then `swift build`. Never run SwiftPM commands concurrently against one `.build`. CORE-01 adds the test target; after that, `swift test` is required for changed contracts. Before then use existing debug probes where relevant; do not claim a nonexistent test suite passed.

For launch smoke, use a fresh `CFFIXED_USER_HOME=/tmp/<unique-test-directory>` with a deliberately seeded `dock.json`: left/right edge, native Dock hiding off, window reservation off, widgets/usage/notch/automatic updates off. Verify the file's exact keys against current DockModel. Use `swift run --skip-build portside`, confirm survival, then terminate only that test process with SIGTERM. A temporary home is not a substitute for disabling network/permission-triggering modules and does not sandbox all OS state. Never change `/Applications`, other app preferences or daily-use Dock settings while testing.

Existing focused debug probes include `--check-notch` and `--check-audio-levels` (without `--capture` unless an actual tap test is explicitly intended). UI probes and physical hover/click remain separate. Stable signing identity is necessary for realistic TCC tests; ad hoc permission resets are not proof of release behavior. Crash/kill and signed-update installation tests belong in a disposable account or separately agreed test setup.

## Release decision and result record

Alpha requires T-01 through T-06 and T-11/T-13 for enabled slices. Beta adds T-07/T-09/T-10/T-12/T-14. Cmd+Tab interception additionally requires T-08; menu bar hiding requires T-15 regardless of milestone. Studio requires T-17 through T-19; advanced actions require T-20/T-21; extensions require T-22. Stable requires applicable rows on both supported OS versions, T-02/T-23, accessibility and restricted-work-Mac coverage, and no unresolved data-loss, consent-bypass or input-trapping defect.

Record each run as: commit, planning IDs, exact environment, feature flags, test row, steps/fixture, expected, actual, pass/fail/not-run, evidence path, remaining limitation and owner. Synthetic pass does not close a physical test. Missing machines, permissions or reference artifacts are “not run”, never assumed pass. Rollback means disable the affected module and restore compatible saved settings; do not erase user data or remove their prior utility until replacement coverage is proven.
