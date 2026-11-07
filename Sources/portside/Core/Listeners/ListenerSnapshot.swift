import Darwin
import Foundation

/// Which TCP listeners to read. `all` lists every listener this user may
/// see; a port query lists only that port's.
struct ListenerQuery: Hashable, Sendable, CustomStringConvertible {
    /// nil for every port.
    let port: UInt16?

    static let all = ListenerQuery(validPort: nil)

    /// nil unless `port` is 1...65535.
    init?(port: Int) {
        guard (1...65535).contains(port) else { return nil }
        self.port = UInt16(port)
    }

    private init(validPort: UInt16?) { port = validPort }

    var description: String { port.map { "port \($0)" } ?? "all ports" }
}

enum IPFamily: Int, Comparable, Sendable {
    case v4 = 4
    case v6 = 6

    static func < (lhs: IPFamily, rhs: IPFamily) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a socket is bound to. A wildcard bind accepts on every interface,
/// so it is not an address to open: DEV-02 maps it to loopback on purpose.
enum ListenerHostKind: Int, Comparable, Sendable {
    case wildcard
    case loopback
    case specific

    static func < (lhs: ListenerHostKind, rhs: ListenerHostKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One listening TCP socket. Kept per family and per bind: an IPv4 and an
/// IPv6 wildcard on the same port by the same process are two sockets.
/// Nothing here says the service speaks HTTP.
struct ListenerSocket: Hashable, Sendable {
    let family: IPFamily
    let hostKind: ListenerHostKind
    /// As lsof printed it, without brackets: `*`, `127.0.0.1`, `::1`.
    let host: String
    let port: UInt16
    /// The descriptor number in the owning process.
    let fd: Int32

    static func ordered(_ a: ListenerSocket, _ b: ListenerSocket) -> Bool {
        (a.port, a.family, a.hostKind, a.host, a.fd) < (b.port, b.family, b.hostKind, b.host, b.fd)
    }
}

/// Why a process fact is missing. Never replaced with a guess.
enum UnknownReason: Equatable, Sendable {
    /// lsof did not print the field.
    case notReported
    /// macOS refused to say (EPERM): another user's or a protected process.
    case denied
    /// The process exited before it was read (ESRCH).
    case exited
    /// The pid now belongs to a different process than the one lsof listed
    /// (another user, or started after the listing finished).
    case changed
    /// Any other error, with its errno (0 when the call set none).
    case failed(Int32)
}

enum ProcessFact<Value: Equatable & Sendable>: Equatable, Sendable {
    case known(Value)
    case unknown(UnknownReason)

    var value: Value? {
        if case .known(let value) = self { return value }
        return nil
    }
}

/// Who a process is, read from libproc. Two reads are the same process only
/// when pid, start seconds, start microseconds and uid are all equal; pid
/// alone is never identity (pids are reused). Name and path are display data.
struct ProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    /// Effective uid.
    let uid: uid_t

    var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startSeconds) + TimeInterval(startMicroseconds) / 1_000_000)
    }

    /// True when the process started after `date`, so it cannot be the one
    /// that was listed before then.
    func started(after date: Date) -> Bool {
        let limit = UInt64(max(0, (date.timeIntervalSince1970 * 1_000_000).rounded(.up)))
        return startSeconds * 1_000_000 + startMicroseconds > limit
    }
}

/// One process with at least one listening socket.
struct ListenerProcess: Equatable, Sendable {
    let pid: pid_t
    /// lsof's command name, full length, decoded as UTF-8 with replacement.
    let name: ProcessFact<String>
    /// The uid lsof reported.
    let uid: ProcessFact<uid_t>
    /// The login name lsof reported.
    let userName: ProcessFact<String>
    /// Start identity from libproc, or why it could not be read.
    let identity: ProcessFact<ProcessIdentity>
    /// From `proc_pidpath`; independent of `identity` (either can be denied).
    let executablePath: ProcessFact<String>
    /// Ordered by port, then family, host kind, host and fd.
    let sockets: [ListenerSocket]

    /// False when start identity is unknown. A later stop must refuse such a
    /// process; true is necessary for a stop, never sufficient.
    var hasVerifiedIdentity: Bool { identity.value != nil }
}

enum ListenerFailure: Equatable, Sendable {
    /// lsof could not be started (missing, not executable), with the reason.
    case launchFailed(String)
    /// lsof exited non-zero in a way that is not "nothing matched".
    case exitStatus(Int32)
    /// lsof died from a signal Portside did not send.
    case signaled(Int32)
    /// An earlier lsof did not exit after SIGKILL, so no second one was started.
    case previousRunStillExiting
}

/// How a snapshot ended. Zero processes with `.complete` means no listener
/// is visible to this user, not that none exists: lsof silently omits other
/// users' sockets.
enum ListenerOutcome: Equatable, Sendable {
    case complete
    /// The listed processes are real, but some are missing: output was cut
    /// at the byte cap or ended inside a record (`truncated`), or records
    /// were malformed and skipped.
    case partial(truncated: Bool, malformedRecords: Int)
    /// lsof missed its deadline and was stopped. Nothing it printed is kept.
    case timedOut
    /// lsof broke. Nothing it printed is kept.
    case failed(ListenerFailure)
}

/// Counts for tests and diagnostics. No names, paths or stderr text.
struct ListenerDiagnostics: Equatable, Sendable {
    var stdoutBytes = 0
    var stderrBytes = 0
    var malformedRecords = 0
    var duplicateSockets = 0
    var ignoredFields = 0
    var endedMidRecord = false
    var exitStatus: Int32?
}

struct ListenerSnapshot: Sendable {
    let query: ListenerQuery
    /// Ordered by pid. Empty unless the outcome is complete or partial.
    let processes: [ListenerProcess]
    let outcome: ListenerOutcome
    let diagnostics: ListenerDiagnostics
    /// The user whose listeners this can show (Portside's effective uid).
    let visibleUID: uid_t
    /// When the listing finished, wall clock and monotonic.
    let takenAt: Date
    let takenAtInstant: ContinuousClock.Instant
    let duration: Duration

    var sockets: [ListenerSocket] { processes.flatMap(\.sockets) }
}
