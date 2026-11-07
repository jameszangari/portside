import Foundation

/// What one Command Center query asks of a port lookup, decided without a
/// model. A bare port never reaches `ModelRouter`. A port question reaches
/// it only when it holds exactly one in-range number, because
/// `IntentValidator` refuses every other proposal anyway.
enum PortQuery: Equatable {
    /// Not a port question. A server word alone still lists every server.
    case none
    /// `5173`, `:5173`, `port 5173`, `localhost:5173`, `127.0.0.1:5173`, `[::1]:5173`.
    case port(UInt16)
    /// A port question that cannot be answered as typed. Fixed text.
    case clarify(String)
    /// A port question with one number for the on-device model to read.
    /// `port` is that number, offered as a numeric search when the model
    /// cannot run; it is never looked up without the model's validated proposal.
    case interpret(port: UInt16)

    /// One of these makes a query of two or more words a port question.
    static let questionWords = LocalServerText.keywords + ["running", "using"]

    static func classify(_ query: String) -> PortQuery {
        if let port = bare(query) { return .port(port) }
        let terms = CommandCenterRanker.terms(query)
        guard terms.count >= 2, terms.contains(where: questionWords.contains) else { return .none }
        let numbers = IntentValidator.numbers(in: query)
        switch numbers.count {
        case 0:
            // "show servers" lists every server; "what's running?" needs a port.
            return LocalServerText.isServerQuery(terms) ? .none : .clarify(IntentValidator.Message.needsPort)
        case 1:
            guard let number = numbers.first.flatMap({ Int($0) }), IntentValidator.ports.contains(number),
                  let port = UInt16(exactly: number) else { return .clarify(IntentValidator.Message.outOfRange) }
            return .interpret(port: port)
        default:
            return .clarify(IntentValidator.Message.onePort)
        }
    }

    /// The whole query is one port, optionally after `port` and a loopback
    /// or wildcard host. A trailing question mark is ignored.
    static func bare(_ query: String) -> UInt16? {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix("?") { text.removeLast() }
        if text.hasPrefix("port") {
            text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        for host in ["localhost:", "127.0.0.1:", "[::1]:", "0.0.0.0:", ":"] where text.hasPrefix(host) {
            text.removeFirst(host.count)
            break
        }
        guard (1...5).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), IntentValidator.ports.contains(value) else { return nil }
        return UInt16(value)
    }
}

/// Where the lookup for the current query stands. Every message is fixed
/// text or a provider's fixed text; nothing the model writes is shown.
enum PortLookupPhase: Equatable {
    /// The on-device model is reading the request.
    case interpreting(port: UInt16)
    /// Look this port up in the native listing. `interpreted` when the model
    /// proposed it and `IntentValidator` accepted it.
    case port(UInt16, interpreted: Bool)
    /// The request needs the person to say more.
    case clarify(String)
    /// The model says the request is not a port lookup.
    case unsupported(String)
    /// Local intelligence cannot run now. Offers a numeric search for `port`.
    case unavailable(String, port: UInt16)
    /// The model ran but gave nothing usable. Offers a numeric search for `port`.
    case failed(String, port: UInt16)
    /// Local Servers cannot list (module off, a permission), so no model runs.
    case serversUnavailable(String)
}

struct PortLookupState: Equatable {
    /// The query this answers, as `CommandCenterRanker.answerKey`.
    let key: String
    var phase: PortLookupPhase
}

/// Natural-language port lookup for one Command Center session (P2-AI-03).
/// The model only narrows a request to a port through `ModelRouter`, and
/// `IntentValidator` decides; the listing (`LocalServerStore`, through the
/// registry) is the only source of process facts. A new query cancels the
/// request in flight and drops its result; closing the panel does the
/// same. Nothing runs at launch or without a query.
@MainActor
final class PortLookup {
    enum Message {
        static let off = "Local Intelligence is off, so Portside cannot read this request."
        static let busy = "The on-device model is busy with another request."
        static let timedOut = "The on-device model took too long to answer."
        static let stopped = "Local Intelligence stopped before it answered."
        static let noServers = "This build cannot list servers."
    }

    private(set) var current: PortLookupState?
    /// Runs when a request in flight finishes for the current query.
    var onChange: (@MainActor () -> Void)?
    let router: ModelRouter?
    /// A request starts only after the query rests this long, so typing a
    /// question does not run the model once per keystroke.
    private let settle: Duration
    private var task: Task<Void, Never>?
    private var generation = 0

    nonisolated init(router: ModelRouter?, settle: Duration = .milliseconds(250)) {
        self.router = router
        self.settle = settle
    }

    /// The current query has a port to look up, so it needs the listing.
    /// A question still being read lists nothing: validation comes first.
    func wantsListing(_ query: String) -> Bool {
        guard let current, current.key == CommandCenterRanker.answerKey(query), case .port = current.phase else { return false }
        return true
    }

    /// The query changed. `serversUnavailable` is why Local Servers cannot
    /// list right now, if it cannot; then no model runs.
    func update(_ query: String, serversUnavailable: String?) {
        let key = CommandCenterRanker.answerKey(query)
        if let current, current.key == key { return }
        generation += 1
        task?.cancel()
        let phase: PortLookupPhase?
        switch PortQuery.classify(query) {
        case .none: phase = nil
        case .clarify(let message): phase = .clarify(message)
        case .port(let port): phase = serversUnavailable.map { .serversUnavailable($0) } ?? .port(port, interpreted: false)
        case .interpret(let port):
            if let serversUnavailable {
                phase = .serversUnavailable(serversUnavailable)
            } else if let router, router.state != .disabled {
                phase = .interpreting(port: port)
                start(query, port: port, router: router)
            } else {
                phase = .unavailable(Message.off, port: port)
            }
        }
        current = phase.map { PortLookupState(key: key, phase: $0) }
    }

    /// The panel closed: cancels the request and forgets the query.
    func end() {
        generation += 1
        task?.cancel()
        current = nil
    }

    private func start(_ query: String, port: UInt16, router: ModelRouter) {
        let generation = generation
        let previous = task
        task = Task { @MainActor [weak self, settle] in
            // The router runs one request at a time: let the canceled one unwind.
            await previous?.value
            do { try await Task.sleep(for: settle) } catch { return }
            guard !Task.isCancelled else { return }
            let outcome = await router.proposeIntent(for: query)
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            self.current?.phase = Self.phase(for: outcome, port: port)
            self.onChange?()
        }
    }

    static func phase(for outcome: IntentOutcome, port: UInt16) -> PortLookupPhase {
        switch outcome {
        case .proposed(.findPortOwner(let proposed)): return .port(proposed, interpreted: true)
        case .needsDetail(let message): return .clarify(message)
        case .unsupportedIntent(let message): return .unsupported(message)
        case .invalidIntent(let message): return .failed(message, port: port)
        case .stopped(let stop):
            switch stop {
            case .disabled: return .unavailable(Message.off, port: port)
            case .unsupported(let reason), .unavailable(let reason), .notReady(let reason): return .unavailable(reason, port: port)
            case .busy: return .failed(Message.busy, port: port)
            case .timedOut: return .failed(Message.timedOut, port: port)
            // Reached only when nothing newer took over (the module stopped).
            case .canceled, .completed: return .failed(Message.stopped, port: port)
            case .invalidRequest(let reason), .refused(let reason), .failed(let reason): return .failed(reason, port: port)
            }
        }
    }
}

extension CommandCenterCatalog {
    /// What the lookup row says and does for one phase.
    private struct LookupRow {
        var title: String
        var detail: String?
        var symbol = "network"
        var unavailable: String?
        var primaryTitle = "Refresh Servers"
        /// Return searches this port instead of running Refresh.
        var search: UInt16?
    }

    /// The lookup row for the current query. It runs Refresh, offers a
    /// numeric search, or says why it cannot; the facts stay on the server
    /// cards, which `serverItems` marks as this query's answer.
    static func lookupItem(_ lookup: PortLookup?, store: LocalServerStore?, refresh: CommandDescriptor?) -> CommandCenterItem? {
        guard let lookup, let state = lookup.current else { return nil }
        let model = lookup.router?.provider.displayName ?? "The on-device model"
        let row: LookupRow
        switch state.phase {
        case .interpreting(let port):
            row = LookupRow(title: "Reading your request…", detail: "\(model) is finding the port on this Mac. Return searches \(port) now.",
                            symbol: "sparkles", primaryTitle: "Search Port \(port)", search: port)
        case .port(let port, let interpreted):
            row = portRow(port, interpreted: interpreted, model: model, store: store, refresh: refresh)
        case .clarify(let message):
            row = LookupRow(title: "Which port?", symbol: "questionmark.circle", unavailable: message)
        case .unsupported(let message):
            row = LookupRow(title: "Not a port lookup", symbol: "questionmark.circle", unavailable: message)
        case .unavailable(let reason, let port):
            row = LookupRow(title: "Search port \(port) instead", detail: reason, symbol: "number", primaryTitle: "Search Port \(port)", search: port)
        case .failed(let reason, let port):
            row = LookupRow(title: "Could not read the request", detail: "\(reason) Return searches \(port).",
                            symbol: "exclamationmark.triangle", primaryTitle: "Search Port \(port)", search: port)
        case .serversUnavailable(let reason):
            row = LookupRow(title: "Port lookup", unavailable: reason)
        }
        var item = CommandCenterItem(
            id: .portLookup,
            kind: .lookup,
            title: row.title,
            subtitle: "Port Lookup",
            symbolName: row.symbol,
            unavailableReason: row.unavailable,
            invocation: CommandInvocation(command: LocalServersModule.refreshCommand, staysOpen: true),
            primaryTitle: row.primaryTitle,
            copyValue: "",
            copyTitle: ""
        )
        item.detail = row.detail
        item.answers = state.key
        item.queryReplacement = row.search.map(String.init)
        return item
    }

    private static func portRow(_ port: UInt16, interpreted: Bool, model: String, store: LocalServerStore?, refresh: CommandDescriptor?) -> LookupRow {
        guard let refresh else { return LookupRow(title: "Port \(port)", unavailable: PortLookup.Message.noServers) }
        if let reason = refresh.unavailableReason() { return LookupRow(title: "Port \(port)", unavailable: reason) }
        let source = interpreted ? "\(model) read the port on this Mac; the process facts come from lsof. " : ""
        guard let store, let snapshot = store.snapshot else {
            if store?.lastRefreshCanceled == true, store?.loading == 0 {
                return LookupRow(title: "Port \(port) lookup was canceled", detail: "Return to try again.", symbol: "xmark.circle", primaryTitle: "List Servers")
            }
            return LookupRow(title: "Looking up port \(port)…", detail: source.isEmpty ? "Listing servers your account runs." : source,
                             symbol: "hourglass", primaryTitle: "List Servers")
        }
        if let problem = LocalServerText.failure(snapshot.outcome) {
            return LookupRow(title: "Could not look up port \(port)", detail: problem, symbol: "exclamationmark.triangle")
        }
        let time = snapshot.takenAt.formatted(date: .omitted, time: .standard)
        let count = LocalServer.servers(in: snapshot).filter { $0.port == port }.count
        var missing = ""
        if case .partial = snapshot.outcome { missing = " Some entries could not be read, so one may be missing." }
        if count == 0 {
            return LookupRow(
                title: "Nothing visible to you on port \(port)",
                detail: "\(source)Only processes your account can see are listed; other users' and system processes are not shown. Listed at \(time).\(missing)",
                symbol: "server.rack"
            )
        }
        return LookupRow(title: "Port \(port): \(LocalServerText.count(count)) visible to you", detail: "\(source)Listed at \(time).\(missing)")
    }
}
