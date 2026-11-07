#if DEBUG
import Foundation

/// `portside --check-listeners`: takes one live listener snapshot and prints
/// counts only (no process names, users, paths or ports). Read-only: it
/// runs lsof once and signals nothing but that lsof child.
enum ListenerProbe {
    static func run() -> Int32 {
        let done = DispatchSemaphore(value: 0)
        let box = SnapshotBox()
        Task.detached {
            box.snapshot = try? await ListenerService().snapshot(.all)
            done.signal()
        }
        done.wait()
        guard let snapshot = box.snapshot else {
            print("FAIL no snapshot")
            return 1
        }
        let sockets = snapshot.sockets
        let identified = snapshot.processes.filter(\.hasVerifiedIdentity).count
        print("""
            outcome: \(snapshot.outcome), visible to uid \(snapshot.visibleUID) only
            processes: \(snapshot.processes.count) (identity known \(identified), unknown \(snapshot.processes.count - identified))
            sockets: \(sockets.count) (IPv4 \(sockets.filter { $0.family == .v4 }.count), IPv6 \(sockets.filter { $0.family == .v6 }.count); \
            wildcard \(sockets.filter { $0.hostKind == .wildcard }.count), loopback \(sockets.filter { $0.hostKind == .loopback }.count), \
            specific \(sockets.filter { $0.hostKind == .specific }.count))
            malformed: \(snapshot.diagnostics.malformedRecords), duplicates: \(snapshot.diagnostics.duplicateSockets), \
            stdout \(snapshot.diagnostics.stdoutBytes) B, stderr \(snapshot.diagnostics.stderrBytes) B
            duration: \(snapshot.duration)
            """)
        switch snapshot.outcome {
        case .complete, .partial: return 0
        case .timedOut, .failed: return 1
        }
    }

    private final class SnapshotBox: @unchecked Sendable {
        var snapshot: ListenerSnapshot?
    }
}
#endif
