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

/// The latest listener snapshot for one Command Center session. Nothing
/// lists until someone asks (a server search or Refresh); the snapshot is
/// dropped when the panel closes or the module stops, so a new session
/// never shows an old list. Concurrent refreshes share `ListenerService`'s
/// one listing.
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

    private let service: ListenerService
    private var session = 0

    nonisolated init(service: ListenerService = ListenerService()) {
        self.service = service
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
        snapshot = nil
        loading = 0
        lastRefreshCanceled = false
    }

    /// Lists every listener this user can see. Keeps the newest snapshot
    /// when two refreshes overlap. Canceling the caller cancels its share
    /// of the listing (the lsof child stops when no one else waits).
    func refresh() async -> Result<ListenerSnapshot, CommandFailure> {
        guard isActive else { return .failure(CommandFailure(reason: "Local Servers is turned off.")) }
        let session = self.session
        loading += 1
        lastRefreshCanceled = false
        onChange?()
        let result: Result<ListenerSnapshot, Error>
        do { result = .success(try await service.snapshot(.all)) } catch { result = .failure(error) }
        guard session == self.session else { return .failure(CommandFailure(reason: "Command Center closed before the list finished.")) }
        loading -= 1
        defer { onChange?() }
        switch result {
        case .success(let fresh):
            if snapshot.map({ fresh.takenAtInstant >= $0.takenAtInstant }) ?? true { snapshot = fresh }
            return .success(fresh)
        case .failure:
            // `ListenerService` throws only `CancellationError`.
            lastRefreshCanceled = loading == 0
            return .failure(CommandFailure(reason: "Refresh was canceled."))
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
/// process facts), so the restricted preset holds it off. Read-only: it
/// copies and opens addresses and never signals a process. Every command
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

    let id = LocalServersModule.moduleID
    let title = "Local Servers"
    let summary = "Finds TCP servers your account runs (port, process, PID, address) in Command Center when you search a port, or type port or server. Lists with lsof only when you search or refresh, and never stops a process."
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
