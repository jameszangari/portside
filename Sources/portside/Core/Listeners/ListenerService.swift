import Foundation

/// On-demand listener snapshots, one listing at a time. A request for the
/// query already running joins it; any other request waits for it to end.
/// A canceled caller returns `CancellationError` at once, and the listing
/// is canceled (its lsof stopped) only when no caller still wants it. A
/// canceled listing still counts as running until its source returns, so
/// two never overlap. No timer: nothing runs unless someone asks.
actor ListenerService {
    private typealias Waiter = CheckedContinuation<ListenerSnapshot, Error>

    private final class Listing {
        let query: ListenerQuery
        var waiters: [UInt64: Waiter] = [:]
        var task: Task<Void, Never>?
        var isCanceled = false

        init(query: ListenerQuery) { self.query = query }
    }

    let source: any ListenerSource
    private var current: Listing?
    private var queued: [(id: UInt64, query: ListenerQuery, waiter: Waiter)] = []
    private var nextID: UInt64 = 0
    private(set) var listingsStarted = 0

    init(source: any ListenerSource = LsofListenerSource()) {
        self.source = source
    }

    func snapshot(_ query: ListenerQuery = .all) async throws -> ListenerSnapshot {
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: Waiter) in
                if Task.isCancelled { return waiter.resume(throwing: CancellationError()) }
                enqueue(id, query, waiter)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func enqueue(_ id: UInt64, _ query: ListenerQuery, _ waiter: Waiter) {
        if let current {
            if current.query == query, !current.isCanceled {
                current.waiters[id] = waiter
            } else {
                queued.append((id, query, waiter))
            }
            return
        }
        start(query, waiters: [id: waiter])
    }

    private func start(_ query: ListenerQuery, waiters: [UInt64: Waiter]) {
        let listing = Listing(query: query)
        listing.waiters = waiters
        current = listing
        listingsStarted += 1
        let source = source
        listing.task = Task {
            let result: Result<ListenerSnapshot, Error>
            do { result = .success(try await source.snapshot(query)) } catch { result = .failure(error) }
            self.finish(listing, result)
        }
    }

    private func finish(_ listing: Listing, _ result: Result<ListenerSnapshot, Error>) {
        guard current === listing else { return }
        current = nil
        for waiter in listing.waiters.values { waiter.resume(with: result) }
        listing.waiters.removeAll()
        guard let next = queued.first else { return }
        let joining = queued.filter { $0.query == next.query }
        queued.removeAll { $0.query == next.query }
        start(next.query, waiters: Dictionary(uniqueKeysWithValues: joining.map { ($0.id, $0.waiter) }))
    }

    private func cancelWaiter(_ id: UInt64) {
        if let index = queued.firstIndex(where: { $0.id == id }) {
            queued.remove(at: index).waiter.resume(throwing: CancellationError())
            return
        }
        guard let current, let waiter = current.waiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        if current.waiters.isEmpty {
            current.isCanceled = true
            current.task?.cancel()
        }
    }
}
