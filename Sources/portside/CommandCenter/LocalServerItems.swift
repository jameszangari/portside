import Darwin
import Foundation

/// Words that ask Command Center for local servers, and the copy for their
/// rows. Every count says "visible to you": lsof lists only this user's
/// listeners, so an empty list never means a port is free.
enum LocalServerText {
    static let keywords = ["port", "ports", "server", "servers", "localhost", "listener", "listeners", "listening"]

    /// A whole query word is a server keyword, or the first word is a port
    /// number (`5173`, `:5173`, `localhost:5173`, `127.0.0.1:8080`).
    static func isServerQuery(_ terms: [String]) -> Bool {
        if terms.contains(where: keywords.contains) { return true }
        guard let first = terms.first, (1...5).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(first) else { return false }
        return (1...65535).contains(port)
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 server" : "\(n) servers" }

    static func found(_ n: Int) -> String {
        n == 0 ? "No listening servers visible to you." : "\(count(n)) visible to you."
    }

    /// Why a finished listing shows nothing, or nil when it listed.
    static func failure(_ outcome: ListenerOutcome) -> String? {
        switch outcome {
        case .complete, .partial: return nil
        case .timedOut: return "Listing servers took too long and was stopped. Refresh to try again."
        case .failed(.launchFailed(let reason)): return "Could not run lsof. \(reason)"
        case .failed(.exitStatus(let status)): return "lsof failed (status \(status)). Refresh to try again."
        case .failed(.signaled(let signal)): return "lsof stopped unexpectedly (signal \(signal)). Refresh to try again."
        case .failed(.previousRunStillExiting): return "An earlier lookup is still stopping. Refresh in a moment."
        }
    }

    /// The status row's second line: loading, empty, partial, failed, or
    /// how many are listed and when.
    @MainActor
    static func status(_ store: LocalServerStore?) -> (detail: String, symbol: String) {
        guard let store, store.isActive else { return ("Lists TCP servers your account runs.", "server.rack") }
        guard let snapshot = store.snapshot else {
            if store.loading > 0 { return ("Looking up listening servers…", "hourglass") }
            if store.lastRefreshCanceled { return ("Listing was canceled. Return to try again.", "xmark.circle") }
            return ("Return to list servers your account runs, or search a port.", "server.rack")
        }
        let time = snapshot.takenAt.formatted(date: .omitted, time: .standard)
        if store.loading > 0 { return ("Refreshing… showing the list from \(time).", "hourglass") }
        let canceled = store.lastRefreshCanceled ? "Refresh canceled. " : ""
        if let problem = failure(snapshot.outcome) { return (canceled + problem, "exclamationmark.triangle") }
        let n = LocalServer.servers(in: snapshot).count
        if case .partial(let truncated, let malformed) = snapshot.outcome {
            let why = truncated ? "the listing was cut short" : (malformed == 1 ? "1 entry could not be read" : "\(malformed) entries could not be read")
            return ("\(canceled)\(count(n)) shown, but some may be missing: \(why).", "exclamationmark.triangle")
        }
        if n == 0 {
            return ("\(canceled)No listening servers visible to you at \(time). Other users' and system servers are not shown.", "server.rack")
        }
        return ("\(canceled)\(count(n)) visible to you, listed at \(time). Return to refresh.", "server.rack")
    }

    /// "127.0.0.1, ::1 · IPv4 and IPv6" style summary of where it listens.
    static func binds(_ sockets: [ListenerSocket]) -> String {
        var hosts: [String] = []
        for socket in sockets {
            let label = socket.hostKind == .wildcard ? "all interfaces" : socket.host
            if !hosts.contains(label) { hosts.append(label) }
        }
        let families = Set(sockets.map(\.family))
        let family = families.count == 2 ? "IPv4 and IPv6" : (families.first == .v6 ? "IPv6" : "IPv4")
        return "\(hosts.joined(separator: ", ")) · \(family)"
    }

    static func socket(_ socket: ListenerSocket) -> String {
        let family = socket.family == .v4 ? "IPv4" : "IPv6"
        switch socket.hostKind {
        case .wildcard:
            return "All interfaces, \(family) (opens on \(socket.family == .v4 ? "127.0.0.1" : "[::1]"))"
        case .loopback: return "\(socket.host), \(family) loopback"
        case .specific: return "\(socket.host), \(family)"
        }
    }

    static func unknown(_ reason: UnknownReason) -> String {
        switch reason {
        case .notReported: return "Unknown (not reported)"
        case .denied: return "Unknown (macOS did not allow reading it)"
        case .exited: return "Unknown (the process exited)"
        case .changed: return "Unknown (the PID now belongs to another process)"
        case .failed(let code): return "Unknown (error \(code))"
        }
    }

    static func name(_ process: ListenerProcess) -> String {
        process.name.value.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown process"
    }

    /// The server card. Never arguments, environment or working directory
    /// (Portside does not read them); the home folder in a path shows as `~`.
    static func facts(_ server: LocalServer, snapshot: ListenerSnapshot) -> [CommandCenterFact] {
        let process = server.process
        var facts = [
            CommandCenterFact(label: "Port", value: "\(server.port) (TCP; whether it speaks HTTP is not checked)"),
            CommandCenterFact(label: "Process", value: name(process)),
            CommandCenterFact(label: "PID", value: String(process.pid)),
        ]
        if let address = server.address {
            facts.append(CommandCenterFact(
                label: "Address",
                value: address.isLoopback ? address.text : "\(address.text) (not loopback, so it is copied but not opened)"
            ))
        }
        facts += server.sockets.enumerated().map { index, socket in
            CommandCenterFact(label: index == 0 ? "Listening on" : "", value: Self.socket(socket))
        }
        switch process.identity {
        case .known(let identity):
            facts.append(CommandCenterFact(label: "Started", value: identity.startDate.formatted(date: .abbreviated, time: .standard)))
            facts.append(CommandCenterFact(label: "Identity", value: "Verified by PID and start time"))
        case .unknown(let reason):
            facts.append(CommandCenterFact(label: "Identity", value: unknown(reason)))
        }
        let owner: String
        switch process.uid {
        case .known(let uid): owner = uid == snapshot.visibleUID ? "You" : "Another account (uid \(uid))"
        case .unknown(let reason): owner = unknown(reason)
        }
        facts.append(CommandCenterFact(label: "Owner", value: owner))
        switch process.executablePath {
        case .known(let path): facts.append(CommandCenterFact(label: "Executable", value: abbreviatingHome(path)))
        case .unknown(let reason): facts.append(CommandCenterFact(label: "Executable", value: unknown(reason)))
        }
        facts.append(CommandCenterFact(label: "Listed", value: "\(snapshot.takenAt.formatted(date: .omitted, time: .standard)). Refresh for current state."))
        return facts
    }

    static func abbreviatingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/", path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

extension CommandCenterCatalog {
    /// The Local Servers status row (the refresh command, always listed so
    /// a server search shows loading, empty, failed or turned-off states)
    /// plus one row per listed server. Every row runs a `localServers`
    /// registry command; nothing here lists or opens anything. Servers on
    /// `answering.port` rank first for that lookup's query.
    static func serverItems(
        _ store: LocalServerStore?, registry: CommandRegistry, moduleTitle: (String) -> String?,
        answering: (key: String, port: UInt16)? = nil
    ) -> [CommandCenterItem] {
        guard let refresh = registry.descriptor(for: LocalServersModule.refreshCommand) else { return [] }
        let module = moduleTitle(LocalServersModule.moduleID.rawValue) ?? "Local Servers"
        let reason = refresh.unavailableReason()
        let status = LocalServerText.status(store)
        let listed = store?.snapshot != nil
        var row = CommandCenterItem(
            id: .command(refresh.id),
            kind: .command,
            title: "Local Servers",
            subtitle: module,
            symbolName: status.symbol,
            keywords: refresh.keywords,
            unavailableReason: reason,
            permissions: refresh.requiredPermissions.map(\.description),
            invocation: CommandInvocation(command: refresh.id, staysOpen: true),
            primaryTitle: listed ? "Refresh Servers" : "List Servers",
            copyValue: refresh.id.rawValue,
            copyTitle: "Copy Command ID"
        )
        row.detail = status.detail
        row.matchesServerQueries = true
        guard reason == nil, let store, let snapshot = store.snapshot else { return [row] }

        let copyAddress = registry.descriptor(for: LocalServersModule.copyAddressCommand)
        return [row] + store.servers.map { server in
            let input = CommandInput.string(server.key)
            let name = LocalServerText.name(server.process)
            let address = server.address
            var item = CommandCenterItem(
                id: .server(server.key),
                kind: .server,
                title: "Port \(server.port) · \(name)",
                subtitle: module,
                symbolName: "network",
                keywords: [name] + LocalServerText.keywords,
                unavailableReason: copyAddress == nil ? "This build cannot copy it." : copyAddress?.unavailableReason(),
                invocation: CommandInvocation(command: LocalServersModule.copyAddressCommand, input: input),
                primaryTitle: "Copy \(address?.text ?? "Address")",
                copyValue: address?.text ?? String(server.port),
                copyTitle: "Copy Address"
            )
            var detail = "PID \(server.process.pid) · \(LocalServerText.binds(server.sockets))"
            if !server.process.hasVerifiedIdentity { detail += " · identity unknown" }
            item.detail = detail
            item.facts = LocalServerText.facts(server, snapshot: snapshot)
            if let answering, answering.port == server.port { item.answers = answering.key }
            var actions = [
                CommandCenterItemAction(title: "Copy Port \(server.port)", symbolName: "number",
                                        invocation: CommandInvocation(command: LocalServersModule.copyPortCommand, input: input)),
            ]
            // Open only on loopback, only with a scheme the person picks.
            for (scheme, command) in [(LocalServerScheme.http, LocalServersModule.openHTTPCommand), (.https, LocalServersModule.openHTTPSCommand)] {
                guard let address, address.url(scheme) != nil else { continue }
                actions.append(CommandCenterItemAction(title: "Open \(scheme.rawValue)://\(address.text)", symbolName: "safari",
                                                       invocation: CommandInvocation(command: command, input: input)))
            }
            actions.append(CommandCenterItemAction(title: "Refresh Servers", symbolName: "arrow.clockwise",
                                                   invocation: CommandInvocation(command: refresh.id, staysOpen: true)))
            item.moreActions = actions
            return item
        }
    }
}
