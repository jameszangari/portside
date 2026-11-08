import AppKit
import Darwin

/// One listener as Command Center shows it: one process on one port, with
/// every socket it holds there (IPv4 and IPv6, loopback and wildcard stay
/// separate sockets inside it). Nothing here says the service speaks HTTP.
struct LocalServer: Equatable, Sendable {
    /// `<port>-<pid>-<start sec>.<start usec>`, or `-unknown` when the start
    /// identity could not be read. Two processes on one port, or one process
    /// on two ports, never share a key; a reused pid gets a new one.
    let key: String
    let port: UInt16
    let process: ListenerProcess
    /// This port's sockets, in `ListenerSocket.ordered` order.
    let sockets: [ListenerSocket]

    /// The address Copy and Open use. nil only without sockets.
    var address: LocalServerAddress? { LocalServerAddress(port: port, sockets: sockets) }

    /// Ordered by port, then pid. Empty for a timed-out or failed listing.
    static func servers(in snapshot: ListenerSnapshot) -> [LocalServer] {
        var servers: [LocalServer] = []
        for process in snapshot.processes {
            var ports: [UInt16] = []
            for socket in process.sockets where !ports.contains(socket.port) { ports.append(socket.port) }
            for port in ports {
                servers.append(LocalServer(
                    key: key(port: port, process: process),
                    port: port,
                    process: process,
                    sockets: process.sockets.filter { $0.port == port }
                ))
            }
        }
        return servers.sorted { ($0.port, $0.process.pid) < ($1.port, $1.process.pid) }
    }

    static func key(port: UInt16, process: ListenerProcess) -> String {
        let start = process.identity.value.map { "\($0.startSeconds).\($0.startMicroseconds)" } ?? "unknown"
        return "\(port)-\(process.pid)-\(start)"
    }
}

/// The schemes a person can pick for Open. Portside never guesses one: a
/// listener is TCP, and only the person knows whether it serves HTTP.
enum LocalServerScheme: String, CaseIterable, Sendable {
    case http, https
}

/// Where to reach a listener from this Mac. A wildcard bind (`*`, `0.0.0.0`,
/// `::`) accepts on every interface, so it maps to loopback on purpose,
/// never to a LAN address. Literal loopback is used rather than `localhost`,
/// which a hosts file can point elsewhere.
struct LocalServerAddress: Equatable, Sendable {
    /// IPv6 in brackets, so `host:port` and URLs read the same.
    let host: String
    let port: UInt16
    /// A loopback bind or a wildcard mapped to loopback. Only these can open.
    let isLoopback: Bool

    var text: String { "\(host):\(port)" }

    /// Preference: IPv4 loopback (`127.0.0.1` for a wildcard), then IPv6
    /// loopback (`::1` for a wildcard), then the first specific bind as
    /// printed (copy only).
    init?(port: UInt16, sockets: [ListenerSocket]) {
        func pick(_ family: IPFamily, canonical: String) -> String? {
            let mine = sockets.filter { $0.family == family }
            if mine.contains(where: { $0.hostKind == .wildcard || $0.host == canonical }) { return canonical }
            return mine.first { $0.hostKind == .loopback }?.host
        }
        if let v4 = pick(.v4, canonical: "127.0.0.1") {
            self.init(host: v4, port: port, isLoopback: true)
        } else if let v6 = pick(.v6, canonical: "::1") {
            self.init(host: "[\(v6)]", port: port, isLoopback: true)
        } else if let socket = sockets.first {
            self.init(host: socket.family == .v6 ? "[\(socket.host)]" : socket.host, port: port, isLoopback: false)
        } else {
            return nil
        }
    }

    init(host: String, port: UInt16, isLoopback: Bool) {
        self.host = host
        self.port = port
        self.isLoopback = isLoopback
    }

    /// nil unless the address is loopback.
    func url(_ scheme: LocalServerScheme) -> URL? {
        guard isLoopback else { return nil }
        return URL(string: "\(scheme.rawValue)://\(host):\(port)/")
    }
}

struct LocalServerStopReceipt {
    let id = UUID()
    let pid: pid_t
    let port: UInt16
    let outcome: ProcessStopOutcome
    var force = false
    var message: String { "\(force ? "Force stop (SIGKILL) · " : "")PID \(pid) · port \(port): \(outcome.message)" }
}

/// Bounds for the refresh that runs only while server results are on
/// screen (P2-DEV-05B). It starts after a listing exists, never on
/// presentation, and stops by itself after `idleLimit` listings that found
/// nothing new or failed, until a person or an exit event wakes it.
struct VisibleRefreshPolicy: Sendable {
    var base: Duration = .seconds(3)
    var maximum: Duration = .seconds(30)
    var idleLimit = 8

    func backoff(after delay: Duration) -> Duration { min(delay * 2, maximum) }
}

/// The latest listener snapshot for one Command Center session. Nothing
/// lists until someone asks (a server search or Refresh); the snapshot is
/// dropped when the panel closes or the module stops, so a new session
/// never shows an old list. Concurrent refreshes share `ListenerService`'s
/// one listing. While server results are visible (`setViewing`), verified
/// process exits remove stale listeners at once and one cancelable
/// backed-off loop lists again to find new ones; nothing runs otherwise.
@MainActor
final class LocalServerStore {
    private(set) var snapshot: ListenerSnapshot?
    /// Refreshes in flight.
    private(set) var loading = 0
    /// The last refresh was canceled before it delivered.
    private(set) var lastRefreshCanceled = false
    /// The `localServers` module runs.
    private(set) var isActive = false
    /// Runs after every change while Command Center is open.
    var onChange: (@MainActor () -> Void)?

    /// Installed only while Command Center is open. No model or background
    /// command can supply approval or an arbitrary PID.
    var confirmStop: (@MainActor (LocalServer) async -> Bool)?
    var confirmForceStop: (@MainActor (LocalServer) async -> Bool)?
    private(set) var lastStopReceipt: LocalServerStopReceipt?
    var lastStopOutcome: ProcessStopOutcome? { lastStopReceipt?.outcome }
    private var stopping = false
    private var forceCandidate: LocalServer?
    private var forceIntent: (token: String, key: String, expires: ContinuousClock.Instant)?
    private var stopRefreshTask: Task<Result<ListenerSnapshot, CommandFailure>, Never>?
    private let stopper: ProcessStopper
    private let confirmationLifetime: Duration
    private let service: ListenerService
    private var session = 0

    /// Server results are on screen: exit watching and the refresh loop may run.
    private(set) var viewing = false
    /// Listings the visible loop started this session.
    private(set) var autoRefreshes = 0
    private let policy: VisibleRefreshPolicy
    private let inspector: any ProcessInspector
    private nonisolated let makeMonitor: @MainActor () -> any ProcessExitMonitoring
    private var monitor: (any ProcessExitMonitoring)?
    private var autoTask: Task<Void, Never>?
    private var loopGeneration = 0
    private var autoDelay: Duration
    private var quietListings = 0

    nonisolated init(
        service: ListenerService = ListenerService(),
        stopper: ProcessStopper = ProcessStopper(),
        confirmationLifetime: Duration = .seconds(60),
        policy: VisibleRefreshPolicy = VisibleRefreshPolicy(),
        inspector: any ProcessInspector = LibprocProcessInspector(),
        makeMonitor: @escaping @MainActor () -> any ProcessExitMonitoring = { ProcessExitMonitor() }
    ) {
        self.service = service
        self.stopper = stopper
        self.confirmationLifetime = confirmationLifetime
        self.policy = policy
        self.inspector = inspector
        self.makeMonitor = makeMonitor
        autoDelay = policy.base
    }

    var servers: [LocalServer] { snapshot.map(LocalServer.servers(in:)) ?? [] }

    func server(_ key: String) -> LocalServer? { servers.first { $0.key == key } }

    func activate() {
        isActive = true
    }

    func deactivate() {
        isActive = false
        endSession()
        onChange?()
    }

    /// Drops the snapshot. A refresh still in flight delivers nothing.
    func endSession() {
        session += 1
        viewing = false
        stopLoop()
        monitor?.reconcile([])
        autoRefreshes = 0
        stopRefreshTask?.cancel()
        stopRefreshTask = nil
        confirmStop = nil
        confirmForceStop = nil
        forceCandidate = nil
        forceIntent = nil
        lastStopReceipt = nil
        snapshot = nil
        loading = 0
        lastRefreshCanceled = false
    }

    /// One confirmation per invocation, bounded to 60 seconds. A late
    /// approval requires a new action; it is never reused for another PID.
    func stop(_ key: String) async -> Result<String?, CommandFailure> {
        await stop(key, force: false)
    }

    func canForceStop(_ server: LocalServer) -> Bool {
        guard isActive, !stopping, lastStopOutcome == .stillRunning,
              let candidate = forceCandidate, candidate.key == server.key else { return false }
        return candidate.process.identity == server.process.identity
            && candidate.process.uid == server.process.uid
            && candidate.process.executablePath == server.process.executablePath
    }

    func beginForceStop(_ key: String) -> String? {
        guard let server = server(key), canForceStop(server) else { return nil }
        let token = UUID().uuidString
        forceIntent = (token, key, .now.advanced(by: confirmationLifetime))
        return token
    }

    func forceStop(_ token: String) async -> Result<String?, CommandFailure> {
        guard let intent = forceIntent, intent.token == token else {
            return .failure(CommandFailure(reason: "Select Force Stop in Command Center. A graceful timeout and separate confirmation are required."))
        }
        forceIntent = nil
        defer {
            forceCandidate = nil
            if isActive { onChange?() }
        }
        guard ContinuousClock.now < intent.expires else {
            return .failure(CommandFailure(reason: "Force stop request expired. Try graceful stop again."))
        }
        return await stop(intent.key, force: true)
    }

    private func stop(_ key: String, force: Bool) async -> Result<String?, CommandFailure> {
        guard isActive else { return .failure(CommandFailure(reason: "Local Servers is turned off.")) }
        guard !stopping else { return .failure(CommandFailure(reason: "A server stop is already in progress.")) }
        guard let server = server(key) else { return .failure(CommandFailure(reason: "That server is no longer listed. Refresh to check again.")) }
        guard !force || canForceStop(server) else {
            return .failure(CommandFailure(reason: "Force stop requires a still-running receipt for this exact server. Try graceful stop first."))
        }
        guard let confirmStop = force ? confirmForceStop : confirmStop else { return .failure(CommandFailure(reason: "Select \(force ? "Force Stop" : "Stop Server") in Command Center to confirm.")) }
        forceCandidate = nil
        forceIntent = nil
        stopping = true
        defer {
            stopping = false
            if isActive { onChange?() }
        }
        let session = self.session
        let outcome: ProcessStopOutcome
        if Task.isCancelled {
            outcome = .canceled
        } else if let refusal = stopper.revalidate(server) {
            outcome = refusal
        } else {
            let expires = ContinuousClock.now.advanced(by: confirmationLifetime)
            let confirmed = await confirmStop(server)
            if !confirmed || Task.isCancelled || session != self.session || !isActive {
                outcome = .canceled
            } else if ContinuousClock.now >= expires {
                outcome = .failed(force ? "Confirmation expired. Try graceful stop again before another Force Stop." : "Confirmation expired. Select Stop Server again.")
            } else {
                let authorized = { [self] in
                    isActive && session == self.session && ContinuousClock.now < expires
                }
                outcome = force
                    ? await stopper.forceStop(server, listeners: service, authorized: authorized)
                    : await stopper.stop(server, listeners: service, authorized: authorized)
            }
        }
        let receipt = LocalServerStopReceipt(pid: server.process.pid, port: server.port, outcome: outcome, force: force)
        if session == self.session, isActive {
            lastStopReceipt = receipt
            if !force, outcome == .stillRunning { forceCandidate = server }
            // Refresh even if the caller canceled after signaling. A new
            // session or module shutdown still discards this refresh.
            snapshot = nil
            let refresh = Task { [self] in
                guard session == self.session, isActive, !Task.isCancelled else {
                    return Result<ListenerSnapshot, CommandFailure>.failure(CommandFailure(reason: "Server session closed."))
                }
                return await self.refresh(fresh: true)
            }
            stopRefreshTask = refresh
            _ = await refresh.value
            stopRefreshTask = nil
        }
        let message = receipt.message
        switch outcome {
        case .stopped, .alreadyExited: return .success(message)
        default: return .failure(CommandFailure(reason: message))
        }
    }

    /// Lists every listener this user can see. Keeps the newest snapshot
    /// when two refreshes overlap. Canceling the caller cancels its share
    /// of the listing (the lsof child stops when no one else waits).
    func refresh(fresh: Bool = false) async -> Result<ListenerSnapshot, CommandFailure> {
        let result = await load(fresh: fresh, silent: false)
        if case .success = result, viewing { wake() }
        return result
    }

    /// `silent` is the visible loop's listing: no loading state, a good list
    /// is never replaced by a timed-out or failed one, and observers hear
    /// only about a real change.
    private func load(fresh: Bool, silent: Bool) async -> Result<ListenerSnapshot, CommandFailure> {
        guard isActive else { return .failure(CommandFailure(reason: "Local Servers is turned off.")) }
        let session = self.session
        if !silent {
            loading += 1
            lastRefreshCanceled = false
            onChange?()
        }
        let result: Result<ListenerSnapshot, Error>
        do { result = .success(try await service.snapshot(.all, fresh: fresh)) } catch { result = .failure(error) }
        guard session == self.session else { return .failure(CommandFailure(reason: "Command Center closed before the list finished.")) }
        if !silent { loading -= 1 }
        switch result {
        case .success(let fresh):
            let usable: Bool
            switch fresh.outcome {
            case .complete, .partial: usable = true
            case .timedOut, .failed: usable = !silent || snapshot == nil
            }
            let newer = snapshot.map { fresh.takenAtInstant >= $0.takenAtInstant } ?? true
            let before = servers
            if usable, newer {
                snapshot = fresh
                if viewing {
                    syncWatchers()
                    pruneExited()
                }
            }
            if !silent || servers != before { onChange?() }
            return .success(fresh)
        case .failure:
            // `ListenerService` throws only `CancellationError`.
            if !silent {
                lastRefreshCanceled = loading == 0
                onChange?()
            }
            return .failure(CommandFailure(reason: "Refresh was canceled."))
        }
    }

    /// Command Center calls this when its query shows or stops showing
    /// server results. Idempotent: it never adds a second loop or observer.
    func setViewing(_ wanted: Bool) {
        let on = wanted && isActive
        guard on != viewing else { return }
        viewing = on
        if on {
            syncWatchers()
            pruneExited()
            wake()
        } else {
            stopLoop()
            monitor?.reconcile([])
        }
    }

    // MARK: Exit events

    private func ensureMonitor() -> any ProcessExitMonitoring {
        if let monitor { return monitor }
        let made = makeMonitor()
        made.onExit = { [weak self] identity in self?.processExited(identity) }
        monitor = made
        return made
    }

    private func syncWatchers() {
        guard viewing, isActive, let snapshot else {
            monitor?.reconcile([])
            return
        }
        ensureMonitor().reconcile(Set(snapshot.processes.compactMap { $0.identity.value }))
    }

    /// An exit event is a hint, never proof: the process is removed only
    /// when libproc confirms it is gone or the pid now belongs to another
    /// process. A read that cannot say (denied) keeps the card and asks the
    /// loop to list again soon.
    private func processExited(_ identity: ProcessIdentity) {
        guard viewing, isActive, !stopping, snapshot != nil else { return }
        switch exitState(of: identity) {
        case .running:
            syncWatchers()
        case .unverified:
            wake()
        case .gone:
            removeGone([identity])
        }
    }

    private enum ExitState { case running, unverified, gone }

    private func exitState(of identity: ProcessIdentity) -> ExitState {
        switch inspector.identity(of: identity.pid) {
        case .known(let current): return current == identity ? .running : .gone
        case .unknown(.exited): return .gone
        case .unknown: return .unverified
        }
    }

    /// A process can exit between a listing and its watcher, and a watcher
    /// on a dead pid may never fire, so every adopted snapshot is checked.
    private func pruneExited() {
        guard viewing, isActive, !stopping, let snapshot else { return }
        let gone = Set(snapshot.processes.compactMap(\.identity.value).filter { exitState(of: $0) == .gone })
        if !gone.isEmpty { removeGone(gone) }
    }

    private func removeGone(_ gone: Set<ProcessIdentity>) {
        guard let current = snapshot else { return }
        let next = current.removing(gone)
        guard next.processes.count != current.processes.count else { return }
        snapshot = next
        syncWatchers()
        wake()
        onChange?()
    }

    // MARK: Visible refresh loop

    /// Resets the backoff and makes sure exactly one loop runs, once a
    /// listing exists.
    private func wake() {
        autoDelay = policy.base
        quietListings = 0
        guard viewing, isActive, snapshot != nil, autoTask == nil else { return }
        loopGeneration += 1
        let generation = loopGeneration
        autoTask = Task { [weak self] in await self?.runLoop(generation) }
    }

    private func stopLoop() {
        loopGeneration += 1
        autoTask?.cancel()
        autoTask = nil
        autoDelay = policy.base
        quietListings = 0
    }

    private func runLoop(_ generation: Int) async {
        defer { if generation == loopGeneration { autoTask = nil } }
        while generation == loopGeneration {
            do { try await Task.sleep(for: autoDelay) } catch { return }
            guard generation == loopGeneration, viewing, isActive else { return }
            // A person's refresh or a stop owns the listing right now.
            if stopping || stopRefreshTask != nil || loading > 0 { continue }
            autoRefreshes += 1
            let before = servers
            let result = await load(fresh: false, silent: true)
            guard generation == loopGeneration else { return }
            if case .success(let listing) = result, listing.outcome.isUsable, servers != before {
                autoDelay = policy.base
                quietListings = 0
            } else {
                quietListings += 1
                autoDelay = policy.backoff(after: autoDelay)
                if quietListings >= policy.idleLimit { return }
            }
        }
    }
}

private extension ListenerOutcome {
    var isUsable: Bool {
        switch self {
        case .complete, .partial: return true
        case .timedOut, .failed: return false
        }
    }
}

/// What the server commands do outside Portside. Injected so tests never
/// touch the pasteboard or open a URL.
struct LocalServerActions {
    var copy: @MainActor (String) -> Void
    /// Opens an already built loopback URL. false when macOS refused.
    var openURL: @MainActor (URL) -> Bool

    static let live = LocalServerActions(
        copy: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        },
        openURL: { NSWorkspace.shared.open($0) }
    )

    static let none = LocalServerActions(copy: { _ in }, openURL: { _ in false })
}

/// The optional `localServers` module (P2-DEV-02): server results in
/// Command Center. Off by default and sensitive (it runs lsof and reads
/// process facts), so the restricted preset holds it off. Stop requires
/// confirmation and fresh process and port validation. Every command
/// takes a server key and resolves it against the latest snapshot, so a
/// listener that is gone is refused, not acted on.
@MainActor
final class LocalServersModule: PortsideModule {
    static let moduleID = ModuleID("localServers")!
    static let refreshCommand = CommandID("localServers.refresh")!
    static let copyAddressCommand = CommandID("localServers.copyAddress")!
    static let copyPortCommand = CommandID("localServers.copyPort")!
    static let openHTTPCommand = CommandID("localServers.openHTTP")!
    static let openHTTPSCommand = CommandID("localServers.openHTTPS")!
    static let stopCommand = CommandID("localServers.stop")!
    static let forceStopCommand = CommandID("localServers.forceStop")!

    let id = LocalServersModule.moduleID
    let title = "Local Servers"
    let summary = "Finds TCP servers your account runs (port, process, PID, address) in Command Center when you search a port, or type port or server. Lists with lsof when you search, refresh or stop. Stop Server confirms and validates one owned process before SIGTERM; only a timeout offers separately confirmed Force Stop (SIGKILL), warning about data loss."
    let fallback = "Command Center and the dock work the same without it."
    let dependencies: [ModuleDependency] = [.module(CommandCenterModule.moduleID)]

    let store: LocalServerStore
    private let actions: LocalServerActions

    init(store: LocalServerStore, actions: LocalServerActions = .none) {
        self.store = store
        self.actions = actions
    }

    func commands() -> [CommandDescriptor] {
        let keyInput = CommandInputSchema.string(maxLength: 64)
        return [
            CommandDescriptor(
                id: Self.refreshCommand,
                title: "Refresh Local Servers",
                keywords: LocalServerText.keywords,
                symbolName: "arrow.clockwise",
                handler: { [store] _ in
                    switch await store.refresh() {
                    case .failure(let failure): return .failure(failure)
                    case .success(let snapshot):
                        if let problem = LocalServerText.failure(snapshot.outcome) { return .failure(CommandFailure(reason: problem)) }
                        return .success(LocalServerText.found(LocalServer.servers(in: snapshot).count))
                    }
                }
            ),
            CommandDescriptor(
                id: Self.copyAddressCommand,
                title: "Copy Server Address",
                symbolName: "doc.on.doc",
                input: keyInput,
                handler: { [store, actions] input in
                    resolve(input, in: store).flatMap { server in
                        guard let address = server.address else { return .failure(CommandFailure(reason: "This server has no address.")) }
                        actions.copy(address.text)
                        return .success("Copied \(address.text).")
                    }
                }
            ),
            CommandDescriptor(
                id: Self.copyPortCommand,
                title: "Copy Server Port",
                symbolName: "number",
                input: keyInput,
                handler: { [store, actions] input in
                    resolve(input, in: store).map { server in
                        actions.copy(String(server.port))
                        return "Copied \(server.port)."
                    }
                }
            ),
            CommandDescriptor(
                id: Self.stopCommand,
                title: "Stop Server…",
                symbolName: "stop.circle",
                input: keyInput,
                handler: { [store] input in
                    guard case .string(let key) = input else { return .failure(CommandFailure(reason: "No server given.")) }
                    return await store.stop(key)
                }
            ),
            CommandDescriptor(
                id: Self.forceStopCommand,
                title: "Force Stop (SIGKILL)…",
                symbolName: "exclamationmark.octagon",
                input: keyInput,
                handler: { [store] input in
                    guard case .string(let token) = input else { return .failure(CommandFailure(reason: "No force stop request given.")) }
                    return await store.forceStop(token)
                }
            ),
            open(Self.openHTTPCommand, .http),
            open(Self.openHTTPSCommand, .https),
        ]
    }

    /// Opens only the loopback URL of a listed server with the scheme the
    /// person picked.
    private func open(_ id: CommandID, _ scheme: LocalServerScheme) -> CommandDescriptor {
        CommandDescriptor(
            id: id,
            title: "Open Server as \(scheme.rawValue.uppercased())",
            symbolName: "safari",
            input: .string(maxLength: 64),
            handler: { [store, actions] input in
                resolve(input, in: store).flatMap { server in
                    guard let url = server.address?.url(scheme) else {
                        return .failure(CommandFailure(reason: "Port \(server.port) is not on a loopback address, so Portside does not open it."))
                    }
                    return actions.openURL(url) ? .success(nil) : .failure(CommandFailure(reason: "macOS could not open \(url.absoluteString)."))
                }
            }
        )
    }

    func start(_ context: ModuleContext) throws {
        store.activate()
        context.onStop { [store] in
            MainActor.assumeIsolated { store.deactivate() }
        }
    }
}

@MainActor
private func resolve(_ input: CommandInput, in store: LocalServerStore) -> Result<LocalServer, CommandFailure> {
    guard case .string(let key) = input else { return .failure(CommandFailure(reason: "No server given.")) }
    guard store.snapshot != nil else { return .failure(CommandFailure(reason: "List servers first.")) }
    guard let server = store.server(key) else {
        return .failure(CommandFailure(reason: "That server is no longer listed. Refresh to check again."))
    }
    return .success(server)
}
