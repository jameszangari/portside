import Darwin
import Foundation

/// Where listener snapshots come from. Read-only: nothing here signals,
/// stops or connects to a listed process. Call through `ListenerService`,
/// which keeps one listing at a time. Canceling the caller throws
/// `CancellationError` and delivers no snapshot.
protocol ListenerSource: Sendable {
    func snapshot(_ query: ListenerQuery) async throws -> ListenerSnapshot
}

/// Bounded `/usr/sbin/lsof` field-mode listing plus libproc identity. Runs
/// off the main thread, never with elevated privileges, and starts no
/// second lsof while an earlier one it gave up on is still exiting.
final class LsofListenerSource: ListenerSource, @unchecked Sendable {
    private let limits: LsofLimits
    private let inspector: any ProcessInspector
    private let invocation: @Sendable (ListenerQuery) -> LsofInvocation
    private let lock = NSLock()
    private var childAlive = false

    init(
        limits: LsofLimits = LsofLimits(),
        inspector: any ProcessInspector = LibprocProcessInspector(),
        invocation: @escaping @Sendable (ListenerQuery) -> LsofInvocation = { LsofInvocation.listeners($0) }
    ) {
        self.limits = limits
        self.inspector = inspector
        self.invocation = invocation
    }

    func snapshot(_ query: ListenerQuery) async throws -> ListenerSnapshot {
        try Task.checkCancellation()
        let instant = ContinuousClock.now
        guard claimChild() else {
            return ListenerSnapshotBuilder.failure(query, .previousRunStillExiting, takenAt: Date(), instant: instant)
        }
        let run = await LsofRunner.run(invocation(query), limits: limits) { [weak self] in self?.releaseChild() }
        if run.termination == .canceled { throw CancellationError() }
        try Task.checkCancellation()
        return ListenerSnapshotBuilder.snapshot(query, run: run, inspector: inspector)
    }

    private func claimChild() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !childAlive else { return false }
        childAlive = true
        return true
    }

    private func releaseChild() {
        lock.lock()
        childAlive = false
        lock.unlock()
    }
}

/// Stored lsof output for tests and isolated runs. Goes through the same
/// byte cap and interpretation as a real run; launches nothing.
struct FixtureListenerSource: ListenerSource {
    var stdout: Data
    var stderr = Data()
    var termination = LsofRun.Termination.exited(0)
    var limits = LsofLimits()
    var inspector: any ProcessInspector = LibprocProcessInspector()
    /// Waits this long first (cancelable), to stand in for a slow lsof.
    var delay: Duration?

    func snapshot(_ query: ListenerQuery) async throws -> ListenerSnapshot {
        if let delay { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        if termination == .canceled { throw CancellationError() }
        var run = LsofRun(termination: termination)
        run.stdout = stdout.prefix(limits.stdoutCap)
        run.stdoutTruncated = stdout.count > limits.stdoutCap
        run.stderr = stderr.prefix(limits.stderrCap)
        run.stderrTruncated = stderr.count > limits.stderrCap
        return ListenerSnapshotBuilder.snapshot(query, run: run, inspector: inspector)
    }
}

/// Turns one lsof run into a snapshot. Exit 0, or exit 1 with nothing on
/// stderr (lsof's "nothing matched"), is a listing; exit 1 with stderr text,
/// any other status or a signal Portside did not send is a failure.
enum ListenerSnapshotBuilder {
    static func snapshot(
        _ query: ListenerQuery,
        run: LsofRun,
        inspector: any ProcessInspector,
        visibleUID: uid_t = geteuid()
    ) -> ListenerSnapshot {
        let instant = ContinuousClock.now
        var diagnostics = ListenerDiagnostics()
        diagnostics.stdoutBytes = run.stdout.count
        diagnostics.stderrBytes = run.stderr.count

        func make(_ outcome: ListenerOutcome, _ processes: [ListenerProcess] = []) -> ListenerSnapshot {
            ListenerSnapshot(
                query: query, processes: processes, outcome: outcome, diagnostics: diagnostics,
                visibleUID: visibleUID, takenAt: run.finishedAt, takenAtInstant: instant, duration: run.duration
            )
        }

        switch run.termination {
        case .timedOut, .canceled: return make(.timedOut)
        case .launchFailed(let reason): return make(.failed(.launchFailed(reason)))
        case .exited(let status): diagnostics.exitStatus = status
        case .signaled: break
        }

        if !run.stdoutTruncated {
            switch run.termination {
            case .exited(0): break
            case .exited(1) where run.stderr.isEmpty: break
            case .exited(let status): return make(.failed(.exitStatus(status)))
            case .signaled(let signal): return make(.failed(.signaled(signal)))
            default: break
            }
        }

        let parsed = LsofFieldParser.parse(run.stdout)
        diagnostics.malformedRecords = parsed.malformedRecords
        diagnostics.duplicateSockets = parsed.duplicateSockets
        diagnostics.ignoredFields = parsed.ignoredFields
        diagnostics.endedMidRecord = parsed.endedMidRecord
        let processes = parsed.processes.map { enrich($0, inspector: inspector, listedBy: run.finishedAt) }
        let truncated = run.stdoutTruncated || parsed.endedMidRecord
        let outcome: ListenerOutcome = truncated || parsed.malformedRecords > 0
            ? .partial(truncated: truncated, malformedRecords: parsed.malformedRecords)
            : .complete
        return make(outcome, processes)
    }

    static func failure(_ query: ListenerQuery, _ failure: ListenerFailure, takenAt: Date, instant: ContinuousClock.Instant) -> ListenerSnapshot {
        ListenerSnapshot(
            query: query, processes: [], outcome: .failed(failure), diagnostics: ListenerDiagnostics(),
            visibleUID: geteuid(), takenAt: takenAt, takenAtInstant: instant, duration: .zero
        )
    }

    /// Adds libproc identity. A pid whose uid differs from lsof's, or whose
    /// process started after the listing finished, was reused: its identity
    /// and path are `changed`, never the new process's.
    static func enrich(_ record: LsofProcessRecord, inspector: any ProcessInspector, listedBy: Date) -> ListenerProcess {
        var identity = inspector.identity(of: record.pid)
        if let read = identity.value,
           (record.uid.map { $0 != read.uid } ?? false) || read.started(after: listedBy) {
            identity = .unknown(.changed)
        }
        let path: ProcessFact<String> = identity == .unknown(.changed) ? .unknown(.changed) : inspector.executablePath(of: record.pid)
        return ListenerProcess(
            pid: record.pid,
            name: record.name.map(ProcessFact.known) ?? .unknown(.notReported),
            uid: record.uid.map(ProcessFact.known) ?? .unknown(.notReported),
            userName: record.userName.map(ProcessFact.known) ?? .unknown(.notReported),
            identity: identity,
            executablePath: path,
            sockets: record.sockets
        )
    }
}
