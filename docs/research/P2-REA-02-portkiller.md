# P2-REA-02: PortKiller listener discovery and stop research

2026-11-07. [REA workflow](../REA_RESEARCH_2_0.md) · [Tickets](../IMPLEMENTATION_PLAN_2_0.md) · [Architecture](../ARCHITECTURE_2_0.md) · [Test matrix T-09, T-10](../TEST_MATRIX_2_0.md)

Research only. No Swift source changed, no dependency added, no developer utility built. No code, assets or binaries from the reference are reproduced here. Short behavioral descriptions of MIT-licensed upstream code are paraphrased, not copied.

## Report header

```text
Question and planning ID:   P2-REA-02. How does PortKiller discover listeners, identify owners and
                            stop them, and what should Portside's DEV-01 (snapshot), DEV-03 (graceful
                            stop) and DEV-04 (force stop) do, including where PortKiller is unsafe?
Reference app / version:    PortKiller, bundle com.portkiller.app, 3.4.0 (build 237), LSUIElement,
                            Sparkle updater, TeamIdentifier QPH96J479A, hardened runtime
Source revision:            github.com/productdevbook/port-killer tag v3.4.0 (ref sha
                            61da81794b03ac415943f662f42ebc3bca7d94c9), MIT license. Read under
                            platforms/macos/Sources. The installed binary is inferred to be built from this
                            tag (version match plus the string checks in F10), not byte-verified.
OS / architecture:          macOS 27.0.1 (26A434), arm64. Binary is universal (x86_64, arm64).
Artifact SHA-256:           PortKiller executable 498a3d1fbe4fd071b4d527ea709f91818fe0ac8aae7ff0c88050290d1696992a
                            Info.plist 0f0282140b8e3001741f0d692626314f64d3fa2bdb14cb72168e0665bd5274af
REA provider version:       Not used. See Limitations.
Scenario / boundary:        (1) Upstream source at the matching tag. (2) Installed app: plist, signature,
                            strings and undefined-symbol list only. (3) Portside-owned disposable
                            Python TCP servers, lsof and libproc experiments on this Mac. PortKiller was
                            NOT launched or driven. No unrelated process was signaled.
Evidence:                   Commands and outputs in "Observed" below, scripts in /tmp/p2rea02 (not
                            committed). No REA evidence ID exists for this report.
```

## Limitations of this investigation

- **REA not used.** The reference is open source at a matching tag, so reading source answers the questions at lower cost than decompiling (workflow step 2). The installed binary was checked only with `strings`, `nm -u`, `codesign` and `shasum`. This is weaker than REA imports/call-path evidence, and it does not prove the shipped binary equals the tag.
- **PortKiller runtime not observed.** Its refresh cadence, confirmation dialogs and notification behavior come from source only. The disposable lifecycle below was run against Portside's own fixtures, not through PortKiller's UI.
- **Single machine, single user.** No second user account, no root-owned listener, no MDM, no sandboxed host. Cross-user behavior is observed only as "lsof returns none of them".
- **macOS 27.0.1 only.** macOS 26 (the deployment floor) was not run.
- **Python fixtures.** The disposable servers are Python, so process name and cwd rules for compiled or wrapped servers (npm, shells, `env`) are untested.

## Observed (first-hand, this Mac)

| ID | Observation | Command / source |
| --- | --- | --- |
| O1 | One owned process bound IPv4 loopback, IPv4 wildcard, IPv6 loopback and IPv6 wildcard produced four rows. The NAME column read `127.0.0.1:P`, `*:P`, `[::1]:P` and `*:P`. The IPv4 wildcard and IPv6 wildcard rows are **identical in NAME**; only the TYPE column (`IPv4` vs `IPv6`) and FD differ. | `lsof -iTCP -sTCP:LISTEN -P -n +c 0 -a -p <pid>` |
| O2 | Field mode (`-F pcLuftPnT0`) emits one process set (`p`, `c`, `u`, `L`) followed by one file set per socket (`f`, `t`, `P`, `n`, `TST=LISTEN`, `TQR=`, `TQS=`). Fields are NUL-terminated with `0`. The command name is raw (`UA Mixer Engine`, `T3 Code (Beta)`), not escaped. | same with `-F` |
| O3 | Without `+c 0` the command name is truncated to 9 characters (`python3.1` for `python3.13`). With `+c 0` it is full. | run without and with the flag |
| O4 | A whole-system unprivileged run took about 0.05 s real, exit 0, stderr empty, 16 processes and 26 listening sockets, all owned by my UID (501). | `/usr/bin/time -p lsof ... -F` |
| O5 | The kernel socket table (`netstat -anv -p tcp`, LISTEN state) shows 31 listeners. lsof listed 26. The 5-socket gap is unexplained. Hypothesis: sockets lsof cannot attribute to a visible process. Not proven. | `netstat` vs `lsof -F` count |
| O6 | lsof exit code is **1** both for "no listener on that port" and for "no such PID", with empty output. Exit 0 means at least one match. Neither case writes to stderr. | `lsof -iTCP:1 ...`, `-a -p 99999999` |
| O7 | Listeners owned by other users are silently absent. There was no error and no stderr text. A caller cannot tell "none exist" from "not visible to you". | O4, O5 |
| O8 | `proc_pidinfo(PROC_PIDTBSDINFO)` returned a full `proc_bsdinfo` (136 bytes) for my own processes: `pbi_uid`, `pbi_ruid`, `pbi_ppid`, `pbi_start_tvsec`, `pbi_start_tvusec`. Start time matched `ps -o lstart`. For PID 1 (launchd) it returned 0 with errno 1 (EPERM). The microsecond part prints unpadded (`.70032`), so identity must compare the two integers, never a float or a formatted string. | `id.swift` (libproc) |
| O9 | `proc_pidpath` succeeded for launchd (`/sbin/launchd`) while `PROC_PIDVNODEPATHINFO` (cwd) was denied (EPERM) for it. Path and cwd have independent permission outcomes. | `id.swift` |
| O10 | `kill(1, 0)` returned -1, errno EPERM. `kill(99999999, 0)` returned -1, errno ESRCH. Signal 0 delivers nothing. EPERM means "exists, not yours". ESRCH means "gone". | `id.swift` |
| O11 | SIGTERM to the owned default-handler server removed its listener within 0.5 s and `ps` no longer listed it. SIGTERM to the owned server that ignores SIGTERM changed nothing: both listeners stayed, state `SN`. SIGKILL then removed it. A child of my shell stays a zombie until reaped, and `kill(pid, 0)` on that zombie still succeeds. | owned fixtures, `kill -TERM`, `kill -KILL`, `wait` |
| O12 | Two fixtures started in the same millisecond window had start times differing by about 1 ms (`.534536` vs `.535571`). Microsecond resolution distinguishes simultaneous siblings. | `id.swift` |

## Findings from source (upstream tag v3.4.0)

| ID | Finding | Evidence | Confidence |
| --- | --- | --- | --- |
| F1 | Discovery runs `/usr/sbin/lsof` with `-iTCP -sTCP:LISTEN -P -n +c 0` by absolute path, no shell, then parses the default column table (`COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME`). | `PortScanner.swift` `scanPorts` | High |
| F2 | Parsing splits each line on spaces and needs at least 9 fields. It finds the address as the last field containing `:` that is not `0x…` or `0t…`. A command name containing a space is escaped by lsof as `\xHH`, and the parser decodes those. Field mode (O2) avoids this class of fragility entirely. | `parseLsofOutput`, `decodeLsofEscapes` | High |
| F3 | IPv6 is detected only by a leading `[`. The address is stored as a string (`*`, `127.0.0.1`, `[::1]`). The **IP family is dropped**, and rows are de-duplicated on `port-pid`. Because of O1, an IPv4 wildcard and an IPv6 wildcard on the same port by the same process collapse to one row; a loopback and a wildcard bind on the same port by one process also collapse to whichever came first. | `parseAddress`, dedup key in `parseLsofOutput` | High |
| F4 | Full command line comes from `sysctl(CTL_KERN, KERN_PROCARGS2, pid)`, capped at 64 args, joined with spaces, falling back to the lsof process name when denied. Working directory comes from `proc_pidinfo(PROC_PIDVNODEPATHINFO)` and is nil when denied. Neither spawns a process. | `commandLine`, `PortScanner+WorkingDirectory.swift` | High |
| F5 | Process "type" (web server, database, development, system) is a substring match on the process name. It is a display hint, not identity or safety. | `ProcessType.detect` | High |
| F6 | `lsof` is run through a helper that reads the pipe to EOF **before** `waitUntilExit`, to avoid a pipe-buffer deadlock. There is **no timeout, no output cap, no cancellation of the child**. A hung lsof would hang the scan task. | `ProcessExecutor.swift` | High |
| F7 | Refresh is a polling loop, default 5 s, backing off to at most 30 s when the list is unchanged, plus a coalescing "pending refresh" flag so overlapping requests do not stack. | `AppState+AutoRefresh.swift`, `AppState+PortOperations.swift` `refresh` | High |
| F8 | **Stop is not graceful.** `killProcessGracefully` sends SIGTERM, waits 500 ms only if SIGTERM succeeded, then sends SIGKILL **unconditionally**, even if SIGTERM failed (for example EPERM) and even if the process exited and its PID was reused during the 500 ms. The docstring says "SIGTERM then SIGKILL" but there is no exit check between them. | `killProcessGracefully` | High |
| F9 | **No identity revalidation.** `killPort` guards only `isActive` and `pid > 0` (it notes that pid 0 would signal a process group), then signals the PID captured at the last scan. There is no start-time, UID, path or port ownership recheck before either signal. `killAll` signals every PID in the list. "Deep kill" also stops every PID that holds an ESTABLISHED connection to the port (clients included). Auto-kill rules fire on a timer using the same path. Confirmation is a setting (`skipKillConfirmation`). | `AppState+PortOperations.swift`, `AutoKillManager.swift`, `AppState.swift` | High |
| F10 | The installed binary contains the strings `-iTCP`, `-sTCP:LISTEN`, `-sTCP:ESTABLISHED`, `Force Kill (SIGKILL)`, `Deep Kill (+ Connections)`, `Kill All Processes`, and imports `kill`, `sysctl`, `proc_pidinfo`. This is consistent with F1 to F9. It does not show that the code paths are identical, and `strings` evidence cannot show an action runs. | `strings`, `nm -u -arch arm64` | Medium |
| F11 | The app is not sandboxed in any way this research confirmed (it launches `/usr/sbin/lsof` and signals other processes), which is consistent with the lsof visibility in O7. Entitlements were not extracted. | codesign summary only | Low |
| F12 | `killpg` is not imported by the binary and not used in source. Signals go to a single PID. | `nm -u`, source | Medium (binary) / High (source) |

## Safety assessment of the reference

PortKiller is a good model for **discovery** (public tools, libproc and sysctl enrichment, no shell) and a poor model for **termination**. Portside's tickets already require more than PortKiller does (DEV-03 and DEV-04 name revalidation, privileged/unknown refusal, separate force confirmation, no process-group kill), so Portside should copy the discovery structure and deliberately diverge on stop:

| Behavior | PortKiller | Portside rule |
| --- | --- | --- |
| Escalation | SIGTERM then automatic SIGKILL after 500 ms | SIGTERM only in DEV-03. SIGKILL is a separate user action in DEV-04 after a timeout is shown (F8) |
| Target check | Last-scan PID | Re-read identity immediately before each signal (F9) |
| Kill all / deep / auto-kill | Present | Out of scope. Not planned. One exact target per confirmation |
| Failure reporting | Boolean `kill == 0`, silently continues to SIGKILL | Distinct receipt per outcome (below) |
| lsof bounds | None (F6) | Deadline, byte cap, argument allowlist |
| IP family | Dropped, dedup merges (F3) | Kept per socket |

## Recommended discovery implementation (P2-DEV-01)

### Execution

1. Spawn `/usr/sbin/lsof` with `Process`, absolute path, argument array, no shell, minimal environment (`LC_ALL=C` only). Arguments, fixed by Portside and never built from user text: `-nP`, `-iTCP`, `-sTCP:LISTEN`, `+c`, `0`, `-F`, `pcLuftPnT0`. Optionally `-w` (suppress warnings) so stderr stays empty. Do not pass `-u`, `+M`, `-i@host`, `-r` (repeat mode) or `+L`. A single-port query appends `-iTCP:<port>` with `<port>` validated as an integer 1...65535 before use.
2. Redirect stdout to a pipe read on a background task, stderr to a second pipe with its own cap. Read both while the child runs (never `waitUntilExit` first).
3. **Deadline** (recommend 2 s, configurable constant): on expiry call `terminate()`, then SIGKILL the lsof child after a short grace, and return a `.timedOut` outcome. This is the only kill Portside performs in DEV-01 and it targets its own child.
4. **Byte cap** (recommend 1 MiB stdout, 64 KiB stderr): stop reading, terminate the child, return `.truncated` with the records parsed so far marked incomplete.
5. **Cancellation**: the caller's `Task` cancellation terminates the child. No polling timer; a snapshot is taken on demand (open of the Command Center server list, explicit refresh, AI-03 query). This keeps the reveal/hide path untouched (AGENTS.md rule 4).
6. Concurrent requests coalesce onto the in-flight snapshot, like PortKiller's pending-refresh flag, but with a hard cap of one lsof child at a time.
7. Never run with elevated privileges and never fall back to `sudo` or an admin prompt.

### Parsing (field mode)

Parse bytes, not a `String` line table. Split the stream on NUL; each token starts with a one-character field ID. `p` begins a process record, `f` begins a file record within the current process. Required file fields: `f`, `t` (IPv4 or IPv6), `P` (TCP), `n` (address:port), `TST=` (state). A record missing any required field is **malformed** and skipped, counted in the snapshot's diagnostics. Unknown field IDs are ignored. Decode `c` and `L` as UTF-8 with replacement and keep the raw bytes length for tests.

Address grammar for `n`: `*:PORT`, `IPv4:PORT`, `[IPv6]:PORT`. Split on the **last** colon, strip brackets, require port in 1...65535. Anything else, including a `->` (a connected socket, which the `-sTCP:LISTEN` filter should have excluded), is malformed.

### Snapshot model

```text
ListenerSocket   family (v4|v6), host (loopback|wildcard|specific + raw string), port, fd,
                 state=listen
ListenerProcess  pid, uid (from p/u), userName (L, optional), name (c), sockets [ListenerSocket]
                 identity: ProcessIdentity?   // see below, nil if libproc denied
Snapshot         processes, takenAt (monotonic + wall), outcome, diagnostics
Outcome          .complete | .partial(truncated|malformed n) | .failed(timedOut|launchFailed|nonZero)
                 .complete with zero records is a valid "no listeners visible to this user"
```

Rules that matter for later tickets:

- **Do not de-duplicate across families.** A row is `(pid, family, host, port)`. The UI may group by `(pid, port)` for display and must show both families and a wildcard/loopback label. (Fixes F3.)
- **Wildcard is not a URL.** `*` means "all interfaces". DEV-02's open action maps it to loopback deliberately and never to a LAN address (matches the ticket).
- **Do not infer HTTP.** TCP + port does not say HTTP. Scheme stays unknown unless the user picks one.
- **Exit code**: 0 with records is `.complete`. 1 with empty stdout and empty stderr is `.complete` with zero records (O6). Exit 1 with non-empty stderr, or any exit above 1, or a signal death, is `.failed`. This keeps "nothing found" distinct from "lsof broke".
- **Visibility disclosure**: because of O7, a complete snapshot means "listeners owned by this user". The UI and AI-03 answers must say so. It must not claim "nothing is using port N" for other users' sockets. Whether a root-owned listener on the requested port exists is unknowable from lsof without privilege. A cheap, privilege-free cross-check is a local connect attempt to `127.0.0.1:N`, but that probes a network service and is **not** recommended in DEV-01; record it as an open question.

### Enrichment (per PID, after lsof)

| Field | API | On failure |
| --- | --- | --- |
| Start identity | `proc_pidinfo(PROC_PIDTBSDINFO)`: `pbi_start_tvsec` + `pbi_start_tvusec`, `pbi_uid`, `pbi_ruid`, `pbi_ppid` | `identity = nil`, process is **not stoppable** |
| Executable path | `proc_pidpath` | `unknown` |
| Working directory | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` | `unknown`, never guessed |
| Command line | `sysctl(KERN_PROCARGS2)` | `unknown` |

Use the process name from lsof (`c`) and the libproc path as separate fields. They can disagree, and neither is identity. Do **not** read the environment (the tail of `KERN_PROCARGS2`) at all: it holds secrets (AGENTS.md rule 8, DEV-05 "no environment harvesting"). Parse only up to `argc` arguments, as the reference does, and drop the rest.

### Why lsof and not a pure API?

| Option | Verdict |
| --- | --- |
| `/usr/sbin/lsof -F` (recommended) | Public tool, stable field format, maps sockets to PIDs, 0.05 s. Needs a subprocess and the bounds above. Hidden-socket limits in O5/O7 apply. |
| `proc_listpids` + `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` | Public libproc, no subprocess, structured output. Not run in this research. Works only for processes the caller may inspect (same boundary as lsof). Reasonable **DEV-01 follow-up** to evaluate behind the same `ListenerSource` protocol; not the first PR. |
| `netstat -anv` | Gives PIDs on this OS (O5), but a text table meant for humans and no name or UID. Useful only as the O5 cross-check in a test, not in product code. |
| Network.framework / `NWListener` | Creates listeners, does not enumerate others'. Not applicable. |
| Endpoint Security / Network Extension | Needs entitlements and elevated approval. Excluded by the task constraints. |

Design `ListenerSource` as a protocol returning the snapshot types, with `LsofListenerSource` first and a fixture source for tests, so the libproc path can be added later without touching callers.

## Process identity and termination safety rules (for DEV-03 / DEV-04)

### Identity

`ProcessIdentity = (pid, startSec, startUSec, uid)` read from libproc, plus `executablePath` when available. Two reads match only if **all** of pid, start seconds, start microseconds and uid are equal. PID alone is never identity (PIDs wrap and are reused). Name and cwd are display data, not identity.

### Stop preconditions (all must hold, checked as late as possible)

1. The target came from a snapshot whose process had a non-nil `identity` and the listener socket the user selected.
2. `pid > 1`, `pid != getpid()`, and `pid` is not Portside's own parent or child helper (never allow 0 or negative; `kill(0, …)` and `kill(-1, …)` are process-group and broadcast signals).
3. `uid == geteuid()`. Refuse any other UID, including root.
4. Executable path is not under `/System`, `/usr/libexec`, `/usr/sbin`, `/sbin`, `/bin`, `/usr/bin` or `/Library/Apple`, and the process is not `launchd`, `WindowServer`, `Dock`, Finder or Portside itself. Prefer a **protected-target list with unit tests** over name matching; unknown path means refuse.
5. A **fresh** `proc_pidinfo(PROC_PIDTBSDINFO)` read equals the stored identity (sec, usec, uid).
6. The selected port is still listened on by that PID. Re-run the bounded single-port snapshot (`-iTCP:<port>`) and confirm the PID still owns it. If the port is now owned by a different PID or none, **abort** with `targetChanged`.
7. The user confirmed in a prompt that names the process name, PID, port(s) and, when known, project directory. The confirmation expires (recommend 60 s) and a stale approval re-runs steps 5 and 6.

### Signal sequence

- DEV-03: preconditions, `kill(pid, SIGTERM)` once. No automatic escalation. Then observe exit by re-reading identity (ESRCH, or identity mismatch, means the target is gone) with a bounded wait (recommend 5 s) driven by a cancelable task, not a poll in the reveal path. Report one receipt.
- DEV-04: only after a receipt of `stillRunning` and a **new, separate** confirmation that says "Force stop (SIGKILL)". Repeat preconditions 5 and 6 immediately before `kill(pid, SIGKILL)`.
- No `killpg`, no signalling of children, no "kill everything on this port", no client connection kill (reject F9's deep kill). One confirmation, one PID.
- A `kill` call has an unavoidable TOCTOU window between the identity read and the syscall. Narrow it by doing the fresh read and the syscall back to back with no `await` in between, and record the limitation. libproc offers no pidfd-style handle on macOS. `posix_spawn` children Portside owns could be tracked by `Process`, but listeners are arbitrary processes, so that does not apply.

### Receipt outcomes (exact, no boolean)

`stopped` (identity gone after SIGTERM), `stillRunning` (alive after wait), `alreadyExited` (ESRCH or identity gone before the signal), `targetChanged` (identity or port owner mismatch, nothing sent), `denied` (EPERM from `kill`, nothing happened), `refusedProtected`, `refusedForeignUser`, `refusedUnknownIdentity`, `failed(errno)`. `stopped` after an `EPERM` must be impossible by construction.

### Permission failures and protected processes (observed and design)

- Other users' listeners are not listed at all (O7). They cannot be selected, so there is nothing to refuse, but the UI should say listeners are limited to this user.
- A same-user process can still be a system helper or something the user depends on (a database, a VPN agent). Same-UID is necessary, not sufficient. Rule 4 plus the confirmation text are the guard. A local "never offer to stop" list the user can extend is a possible later setting; not required for DEV-03.
- `EPERM` from `kill` (O10) maps to `denied`. No retry, no privilege request, no `sudo`.

## Relevant macOS APIs and limitations

| Need | API | Class | Limit |
| --- | --- | --- | --- |
| Listener enumeration | `/usr/sbin/lsof` field mode | Public system tool | Own-user visibility, silent omission (O7), unexplained socket gap (O5), exit 1 ambiguity (O6), subprocess needs bounds |
| Start identity, UID, PPID | `proc_pidinfo(PROC_PIDTBSDINFO)` | Public libproc | EPERM for protected PIDs (O8); returns 0 not a clean error text |
| Executable path | `proc_pidpath` | Public libproc | Can succeed when other calls fail (O9) |
| Working directory | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` | Public libproc | Denied for others (O9) |
| Command line | `sysctl(KERN_PROCARGS2)` | Public but weakly documented | Layout is a de facto format; the tail holds the environment, which must not be read |
| Process exists / permitted | `kill(pid, 0)` | POSIX | Succeeds on zombies (O11); EPERM vs ESRCH (O10) |
| Stop | `kill(pid, SIGTERM / SIGKILL)` | POSIX | PID TOCTOU; SIGKILL cannot be handled and skips cleanup |
| Alternative enumeration | `proc_listpids`, `PROC_PIDLISTFDS`, `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` | Public libproc | Not exercised here (see "Why lsof") |
| Exit observation | Re-read identity; `NSRunningApplication` only for GUI apps | Public | Servers are usually not GUI apps; no kqueue `EVFILT_PROC` result observed in this research |

No private API is needed. No entitlement, no TCC permission and no elevated privilege is needed for own-user discovery or stop. Portside is not sandboxed for the Dock features, so launching `/usr/sbin/lsof` is consistent with the existing `Process` use in `NativeDock.swift` and `UsageWidget.swift`.

## Test fixture specifications

All fixtures are Portside-owned child processes bound to port 0 (OS-assigned) on loopback unless the case is about wildcard binding. No fixture touches a port a user process holds. No test signals a PID it did not spawn. Pure parser tests need no process.

### Parser fixtures for P2-DEV-01 (pure, stored text)

Store raw bytes under `Tests/portsideTests/Fixtures/lsof/` as `.f` files (NUL-separated). Hand-authored, not copied from a machine.

| Fixture | Content | Expected |
| --- | --- | --- |
| `v4-loopback.f` | One process, one `127.0.0.1:P` socket | 1 listener, family v4, loopback |
| `v6-loopback.f` | `[::1]:P` | family v6, host `::1` |
| `wildcard-v4-v6.f` | One process, two sockets, both NAME `*:P`, types IPv4 and IPv6 | **2** sockets, not merged (fixes F3) |
| `wildcard-and-loopback-same-port.f` | Same pid, `127.0.0.1:P` and `*:P` | 2 sockets |
| `multi-port-one-process.f` | One process, three ports | 1 process, 3 sockets, sorted by port then family |
| `two-processes-same-name.f` | Two `node` PIDs, different ports | 2 processes, distinct PIDs |
| `name-with-space-and-unicode.f` | `c` = `Code Helper (Plugin)` and a UTF-8 CJK name | Names preserved exactly |
| `empty.f` | Zero bytes | `.complete`, zero processes |
| `no-listeners-exit1.f` + meta exit=1, empty stderr | | `.complete`, zero processes, **not** a failure |
| `denied-stderr.f` + meta exit=1, stderr "can't stat" text | | `.failed(nonZero)` |
| `truncated-mid-record.f` | Stream ends inside an `n` field | `.partial(truncated)`, completed records kept, last record dropped |
| `malformed-address.f` | `n` = `abc`, `n` = `*:0`, `n` = `*:99999`, `n` = `[::1]` (no port) | Each skipped and counted; others unaffected |
| `connected-socket.f` | `n` = `127.0.0.1:5000->127.0.0.1:6000` | Skipped as malformed (filter should have removed it) |
| `unknown-field.f` | An extra `Z…` field | Ignored |
| `duplicate-record.f` | Same pid/fd/address twice | De-duplicated on `(pid, fd, family, address, port)` only |
| `oversized.f` | Output longer than the byte cap | `.partial(truncated)` and child terminated |

### Live fixtures for P2-DEV-01 (disposable child)

A small fixture executable or test helper spawns one child that opens, per case, IPv4 loopback, IPv4 wildcard, IPv6 loopback, IPv6 wildcard, then prints its ports and waits. It must start with a known cwd (a temp directory) and a known `argv[0]`.

| Case | Expected |
| --- | --- |
| Four binds (O1 layout) | Four sockets, correct families and host kinds, owner PID equals child PID, uid equals test uid |
| Child exits | Next snapshot does not list it, no stale entry |
| Fixture lsof that sleeps forever | Deadline fires, child lsof terminated, `.failed(timedOut)`, no zombie lsof, within deadline plus small slack |
| Fixture lsof that floods output | Byte cap fires, child terminated, `.partial(truncated)` |
| Missing `/usr/sbin/lsof` (injected path) | `.failed(launchFailed)`, no crash |
| libproc denied (injected PID 1) | Process listed with `identity == nil`, name from lsof, not stoppable |
| Cancellation mid-run | lsof child terminated, no result delivered |

### Acceptance criteria, P2-DEV-01

1. Every parser fixture above passes with exact expected counts. Wildcard IPv4 and IPv6 on one port stay two sockets.
2. lsof is launched by absolute path with a fixed argument array and no shell, verified by a test that inspects the constructed `Process`.
3. Every run is bounded by deadline and byte cap and cancellable. A test proves no lsof child survives a timeout, cancel or cap hit.
4. "No listeners" and "lsof failed" are distinct outcomes. Own-user scope is carried in the snapshot so UI can say it.
5. Missing metadata is `unknown`, never a guess. A process with unreadable start identity is marked non-stoppable.
6. No environment variables are read. No polling timer is added. No `com.apple.dock` change.
7. `CFFIXED_USER_HOME=/tmp/portside-tests swift test` passes; new tests are listed in the PR.

### Stop fixtures for P2-DEV-03 / DEV-04 (disposable child only)

| Case | Setup | Expected |
| --- | --- | --- |
| Happy path | Child with default SIGTERM handling and one listener | Confirmation text names name/PID/port, SIGTERM once, receipt `stopped`, no SIGKILL, port gone from next snapshot |
| Child exits before approval | Kill child, then approve | `alreadyExited` or `targetChanged`, no signal sent |
| Child exits between revalidation and signal (injected clock/seam) | Seam returns ESRCH from `kill` | `alreadyExited`, no crash |
| PID reuse | Replace the recorded identity with the same PID and a different start time (fake `ProcessInspector`) | `targetChanged`, **zero** `kill` calls (assert through a recording fake) |
| Same PID, different UID | Fake inspector reports a different uid | `refusedForeignUser`, zero kill calls |
| Port owner changed | Snapshot says PID B now owns the port | `targetChanged`, zero kill calls |
| Unknown identity | `identity == nil` | `refusedUnknownIdentity`, zero kill calls |
| Protected path / PID 1 / self / pid 0 / pid -1 | Fake inspector | Each `refusedProtected`, zero kill calls; `kill` never sees 0 or negative |
| SIGTERM ignored | Real child that ignores SIGTERM (O11 fixture) | `stillRunning` after the wait, no automatic SIGKILL. DEV-04 prompt offered |
| Force path | After the above, new confirmation | Revalidate, SIGKILL once, `stopped`; declined confirmation sends nothing |
| EPERM | Fake `kill` returns EPERM | `denied`, no retry, no SIGKILL |
| Child spawns its own child | Fixture forks a grandchild | Only the exact PID is signaled; no `killpg`; test asserts the grandchild is untouched |
| Expired approval | Advance injected clock past 60 s | Re-prompts and revalidates |

Use a recording `ProcessSignaler` fake for every case except the two that deliberately signal a real owned child (happy path and SIGTERM-ignored). Real signals are sent only to PIDs the test itself spawned and holds.

### Acceptance criteria, P2-DEV-03 (and the DEV-04 deltas)

1. Revalidation of start identity, UID and port ownership occurs immediately before every signal and is covered by the fake-inspector cases above.
2. No SIGKILL is sent unless a separate user confirmation follows a `stillRunning` receipt (DEV-04). No automatic escalation exists anywhere.
3. No code path calls `killpg`, signals a non-positive PID, or signals more than one PID per confirmation.
4. The receipt names the exact outcome from the list above. A denied or changed target never reads as success.
5. Refusals (changed, foreign UID, unknown, protected, self) happen **before** any confirmation is shown where they are knowable, and again before the signal where not.
6. The only real-signal tests target test-spawned children. The PR states which tests are real and which are fakes.
7. Command registry integration (DEV-03's CORE-03 dependency) goes through the permission gate; the module can be switched off and the command becomes unavailable with a reason.

## Unresolved questions

1. **O5 gap (31 vs 26).** Which sockets lsof omits is unknown. Test on a machine with a known root-owned local listener before telling users "no listener found". Fallback wording: "none visible to you".
2. **libproc-only enumeration.** Whether `PROC_PIDLISTFDS` sees what lsof does, and whether it is cheaper, is untested. Candidate DEV-01 follow-up behind `ListenerSource`.
3. **Exit observation without polling.** `kqueue` `EVFILT_PROC`/`NOTE_EXIT` on a non-child PID works for same-user processes on other Unixes; not tested here. It would replace the post-SIGTERM wait loop and feed DEV-05 exit events. Verify before DEV-04.
4. **TOCTOU.** The residual window between identity read and `kill` cannot be closed with public APIs. The accepted mitigation is back-to-back read and signal. Confirm acceptable at the gate review.
5. **macOS 26 behavior.** lsof output and libproc permissions were observed on 27.0.1 only.
6. **Wrapped servers.** `npm run dev` spawns `node`; the listener is the grandchild, and killing it does not kill the parent. Presentation of the parent chain and whether to offer stopping a parent are DEV-05/UX questions. Rule: one exact PID.
7. **Does `-w` change exit codes?** Not run; keep it out of the first PR if unverified.
8. **PortKiller runtime** (notification behavior, confirmation copy, Sparkle update checks) was not observed.
9. **Entitlements/sandbox state of PortKiller** (F11) not extracted.
10. **Project association** (git root from cwd) is DEV-05, deliberately not researched here beyond noting cwd is available with a per-PID permission outcome (O9).
11. **Same-UID system helpers** that are safe by UID but harmful to stop (VPN agents, databases). A user-extensible protect list is a possible setting, not decided.

## Decision

**Implement** DEV-01 using bounded `/usr/sbin/lsof` field mode plus libproc/sysctl enrichment, behind a `ListenerSource` protocol, exactly as specified. **Do not copy PortKiller's stop behavior.** DEV-03 and DEV-04 follow the identity and receipt rules above; automatic SIGKILL, kill-all, deep kill and auto-kill are no-go. Open questions 1 and 3 should be re-checked when the dependent ticket starts; neither blocks DEV-01. No further REA probe is required.

## Sources

- https://github.com/productdevbook/port-killer at tag `v3.4.0` (MIT): `platforms/macos/Sources/PortScanner.swift`, `PortScanner+WorkingDirectory.swift`, `AppState+PortOperations.swift`, `AppState+AutoRefresh.swift`, `Managers/AutoKillManager.swift`, `Models/PortInfo.swift`, `Models/ProcessType.swift`, `Services/ProcessExecutor.swift`, `Tests/PortScannerWorkingDirectoryTests.swift`. Fetched 2026-11-07 with the GitHub CLI.
- Local: `/Applications/PortKiller.app` (Info.plist, `codesign -dv`, `shasum`, `lipo -info`, `strings`, `nm -u`).
- Local tools and headers: `/usr/sbin/lsof` (man page field list), libproc (`proc_pidinfo`, `proc_pidpath`), `sysctl(3)` `KERN_PROCARGS2`, `kill(2)`.
- Portside: `Sources/portside/NativeDock.swift`, `Sources/portside/Widgets/UsageWidget.swift` (existing `Process` use), `docs/IMPLEMENTATION_PLAN_2_0.md` (DEV-01 to DEV-05), `docs/TEST_MATRIX_2_0.md` (T-09, T-10).
