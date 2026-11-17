import Darwin
import Dispatch

/// Tells the store when a process it is showing exits. One watcher per
/// process identity (never per pid), so a reused pid is a different watch.
@MainActor
protocol ProcessExitMonitoring: AnyObject {
    /// Runs on the main actor once for each watched identity that exits.
    var onExit: (@MainActor (ProcessIdentity) -> Void)? { get set }
    /// Watches exactly `identities`: adds the missing, cancels the rest.
    /// Never creates a second watcher for an identity already watched.
    func reconcile(_ identities: Set<ProcessIdentity>)
    var watchedCount: Int { get }
}

/// Public `DispatchSource.makeProcessSource` (kqueue `EVFILT_PROC`,
/// `NOTE_EXIT`): event driven, no timer and no scan. A process that is
/// already gone may never fire, so the caller verifies identity after
/// `reconcile`. Capped so a machine with many listeners stays bounded.
@MainActor
final class ProcessExitMonitor: ProcessExitMonitoring {
    static let limit = 128

    var onExit: (@MainActor (ProcessIdentity) -> Void)?
    private var sources: [ProcessIdentity: DispatchSourceProcess] = [:]

    var watchedCount: Int { sources.count }

    func reconcile(_ identities: Set<ProcessIdentity>) {
        for (identity, source) in sources where !identities.contains(identity) {
            source.cancel()
            sources[identity] = nil
        }
        for identity in identities.sorted(by: { $0.pid < $1.pid }) where sources[identity] == nil && sources.count < Self.limit {
            let source = DispatchSource.makeProcessSource(identifier: identity.pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.fire(identity) }
            }
            source.resume()
            sources[identity] = source
        }
    }

    private func fire(_ identity: ProcessIdentity) {
        // A canceled source can still deliver one queued event.
        guard sources.removeValue(forKey: identity) != nil else { return }
        onExit?(identity)
    }

    deinit {
        for source in sources.values { source.cancel() }
    }
}
