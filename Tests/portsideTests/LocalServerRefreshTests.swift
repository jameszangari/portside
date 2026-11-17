import Darwin
import Foundation
import XCTest
@testable import portside

/// Hands the store exit events on demand and records how it was driven.
@MainActor
private final class FakeExitMonitor: ProcessExitMonitoring {
    var onExit: (@MainActor (ProcessIdentity) -> Void)?
    private(set) var watched: Set<ProcessIdentity> = []
    private(set) var reconciles = 0
    var watchedCount: Int { watched.count }

    func reconcile(_ identities: Set<ProcessIdentity>) {
        reconciles += 1
        watched = identities
    }

    func fire(_ identity: ProcessIdentity) { onExit?(identity) }
}

/// An inspector the test changes while the store runs.
private final class MutableInspector: ProcessInspector, @unchecked Sendable {
    private let lock = NSLock()
    private var facts: [pid_t: ProcessFact<ProcessIdentity>] = [:]

    init(_ pids: [pid_t], startSeconds: UInt64 = 1_000) {
        for pid in pids { facts[pid] = .known(ident(pid, startSeconds)) }
    }

    func set(_ pid: pid_t, _ fact: ProcessFact<ProcessIdentity>) {
        lock.lock()
        defer { lock.unlock() }
        facts[pid] = fact
    }

    func identity(of pid: pid_t) -> ProcessFact<ProcessIdentity> {
        lock.lock()
        defer { lock.unlock() }
        return facts[pid] ?? .unknown(.exited)
    }

    func executablePath(of pid: pid_t) -> ProcessFact<String> { .known("/tmp/fixture/bin/server") }
    func parentPID(of pid: pid_t) -> ProcessFact<pid_t> { .known(1) }
}

private func ident(_ pid: pid_t, _ start: UInt64 = 1_000) -> ProcessIdentity {
    ProcessIdentity(pid: pid, startSeconds: start, startMicroseconds: 7, uid: 501)
}

private let fast = VisibleRefreshPolicy(base: .milliseconds(15), maximum: .milliseconds(60), idleLimit: 3)

@MainActor
final class LocalServerRefreshTests: XCTestCase {
    private var source: SwitchableSource!
    private var inspector: MutableInspector!
    private var monitor: FakeExitMonitor!
    private var monitorsMade = 0
    private var store: LocalServerStore!

    private func makeStore(policy: VisibleRefreshPolicy = fast, stdout: Data = node3000) {
        inspector = MutableInspector([4242, 4243, 5001])
        source = SwitchableSource(stdout, inspector: FakeProcessInspector.owning([4242, 4243, 5001]))
        monitor = FakeExitMonitor()
        monitorsMade = 0
        store = LocalServerStore(
            service: ListenerService(source: source),
            stopper: ProcessStopper(inspector: inspector),
            policy: policy,
            inspector: inspector,
            makeMonitor: { [unowned self] in
                monitorsMade += 1
                return monitor
            }
        )
        store.activate()
    }

    private func waitUntil(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func viewList() async {
        _ = await store.refresh()
        store.setViewing(true)
    }

    // MARK: Exit events

    func testVerifiedExitRemovesTheListenerWithoutListingAgain() async {
        makeStore(policy: VisibleRefreshPolicy(base: .seconds(60), maximum: .seconds(60), idleLimit: 3))
        await viewList()
        XCTAssertEqual(monitor.watched, [ident(4242)])
        var changes = 0
        store.onChange = { changes += 1 }
        inspector.set(4242, .unknown(.exited))
        monitor.fire(ident(4242))
        XCTAssertTrue(store.servers.isEmpty, "removed at once")
        XCTAssertEqual(source.listings, 1, "no new lsof for an exit")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(LocalServerText.status(store).detail.hasPrefix("No listening servers"), true, "status reads the same snapshot")
        XCTAssertTrue(monitor.watched.isEmpty)
    }

    func testExitEventForAProcessStillRunningKeepsIt() async {
        makeStore()
        await viewList()
        monitor.fire(ident(4242))
        XCTAssertEqual(store.servers.map(\.port), [3000], "an event is a hint, not proof")
        XCTAssertEqual(monitor.watched, [ident(4242)], "watched again")
    }

    func testUnverifiableExitKeepsTheCardAndListsSoon() async {
        makeStore()
        await viewList()
        inspector.set(4242, .unknown(.denied))
        monitor.fire(ident(4242))
        XCTAssertEqual(store.servers.map(\.port), [3000])
        let reached1 = await waitUntil { source.listings >= 2 }
        XCTAssertTrue(reached1, "the loop verifies by listing")
    }

    func testReusedPidIsNotTheExitedProcess() async {
        makeStore()
        source.set(node3000, inspector: FakeProcessInspector.owning([4242], startSeconds: 2_000))
        inspector.set(4242, .known(ident(4242, 2_000)))
        await viewList()
        let reused = store.servers
        XCTAssertEqual(reused.first?.key, "3000-4242-2000.7")
        // The exit of the old process (same pid, earlier start) arrives late.
        monitor.fire(ident(4242, 1_000))
        XCTAssertEqual(store.servers, reused, "the new owner of the pid stays")
    }

    func testReusedPidReplacesTheOldOneAfterExit() async {
        makeStore()
        await viewList()
        let old = store.servers.first?.key
        inspector.set(4242, .known(ident(4242, 3_000)))
        monitor.fire(ident(4242, 1_000))
        XCTAssertTrue(store.servers.isEmpty, "old identity gone, even though the pid is alive")
        XCTAssertEqual(old, "3000-4242-1000.7")
    }

    func testExitBeforeTheWatcherExistsIsCaughtWhenTheListingLands() async {
        makeStore()
        inspector.set(4242, .unknown(.exited))
        _ = await store.refresh()
        store.setViewing(true)
        XCTAssertTrue(store.servers.isEmpty, "a dead pid gets no event, so adoption verifies")
    }

    func testProjectMetadataSurvivesExitOfAnotherListener() async {
        let both = lsof([(4242, "node", [("IPv4", "*:3000", 20)]), (4243, "node", [("IPv4", "*:4000", 21)])])
        makeStore(stdout: both)
        var fake = FakeProcessInspector.owning([4242, 4243])
        fake.cwds[4242] = .known("/tmp/fixture/app")
        source.set(both, inspector: fake)
        await viewList()
        let kept = store.servers.first { $0.port == 3000 }
        XCTAssertEqual(kept?.process.workingDirectory, .known("/tmp/fixture/app"))
        inspector.set(4243, .unknown(.exited))
        monitor.fire(ident(4243))
        XCTAssertEqual(store.servers, [kept].compactMap { $0 }, "the other card is untouched, project and all")
    }

    // MARK: Refresh loop

    func testNewListenerAppearsThroughTheVisibleLoop() async {
        makeStore()
        await viewList()
        source.set(lsof([(4242, "node", [("IPv4", "*:3000", 20)]), (4243, "vite", [("IPv4", "*:5173", 21)])]))
        let reached2 = await waitUntil { store.servers.map(\.port) == [3000, 5173] }
        XCTAssertTrue(reached2)
        XCTAssertEqual(monitor.watched, [ident(4242), ident(4243)], "new listener is watched too")
        XCTAssertGreaterThan(store.autoRefreshes, 0)
    }

    func testNothingRunsUntilAListingExistsAndTheListIsVisible() async {
        makeStore()
        store.setViewing(true)
        _ = await store.refresh()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(source.listings, 1, "viewing plus a list starts the loop")
        makeStore()
        _ = await store.refresh()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(source.listings, 1, "not viewing: no polling")
        XCTAssertEqual(monitorsMade, 0, "not viewing: no observer")
    }

    func testQuietLoopBacksOffAndIdlesUntilAnExitWakesIt() async {
        makeStore()
        await viewList()
        let reached3 = await waitUntil { store.autoRefreshes == 3 }
        XCTAssertTrue(reached3, "idleLimit bounds the loop")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.autoRefreshes, 3)
        XCTAssertEqual(source.listings, 4)
        // An exit wakes it with a fresh budget.
        source.set(lsof([(4242, "node", [("IPv4", "*:3000", 20)]), (4243, "node", [("IPv4", "*:4000", 21)])]))
        inspector.set(4242, .unknown(.exited))
        monitor.fire(ident(4242))
        let reached4 = await waitUntil { store.autoRefreshes > 3 }
        XCTAssertTrue(reached4)
    }

    func testBackoffDoublesToTheCap() {
        let policy = VisibleRefreshPolicy(base: .seconds(3), maximum: .seconds(30), idleLimit: 8)
        var delay = policy.base
        var seen: [Duration] = []
        for _ in 0..<6 {
            delay = policy.backoff(after: delay)
            seen.append(delay)
        }
        XCTAssertEqual(seen, [.seconds(6), .seconds(12), .seconds(24), .seconds(30), .seconds(30), .seconds(30)])
    }

    func testFailedAutoListingKeepsTheGoodListAndBacksOff() async {
        makeStore()
        await viewList()
        source.set(termination: .exited(2))
        let reached5 = await waitUntil { store.autoRefreshes >= 1 }
        XCTAssertTrue(reached5)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.servers.map(\.port), [3000], "a failed listing never empties the list")
        XCTAssertEqual(store.snapshot?.outcome, .complete)
        let reached6 = await waitUntil { store.autoRefreshes == 3 }
        XCTAssertTrue(reached6, "failures count toward idling")
    }

    func testSettingViewingTwiceAddsNoSecondLoopOrObserver() async {
        makeStore(policy: VisibleRefreshPolicy(base: .milliseconds(40), maximum: .milliseconds(40), idleLimit: 100))
        await viewList()
        store.setViewing(true)
        store.setViewing(true)
        XCTAssertEqual(monitorsMade, 1)
        try? await Task.sleep(for: .milliseconds(170))
        // One loop at 40 ms lists about 4 times; two loops would be about 8.
        XCTAssertLessThanOrEqual(store.autoRefreshes, 5)
        XCTAssertEqual(monitor.watchedCount, 1)
    }

    func testConcurrentRefreshRequestsShareOneListing() async {
        makeStore(policy: VisibleRefreshPolicy(base: .seconds(60), maximum: .seconds(60), idleLimit: 3))
        source.set(delay: .milliseconds(80))
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 { group.addTask { @MainActor in
                if case .success = await self.store.refresh() { return true }
                return false
            } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results, Array(repeating: true, count: 6))
        XCTAssertEqual(source.listings, 1, "no overlapping lsof")
        XCTAssertEqual(store.loading, 0)
    }

    func testLoopSkipsATickWhileAPersonsRefreshIsRunning() async {
        makeStore(policy: VisibleRefreshPolicy(base: .milliseconds(10), maximum: .milliseconds(10), idleLimit: 100))
        await viewList()
        source.set(delay: .milliseconds(150))
        let before = source.listings
        let manual = Task { await store.refresh(fresh: true) }
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertLessThanOrEqual(source.listings - before, 1, "one listing runs, the loop waits its turn")
        _ = await manual.value
    }

    // MARK: Cancellation and shutdown

    func testLeavingServerResultsCancelsTheListingAndTheLoop() async {
        makeStore(policy: VisibleRefreshPolicy(base: .milliseconds(10), maximum: .milliseconds(10), idleLimit: 100))
        await viewList()
        source.set(delay: .seconds(5))
        let reached7 = await waitUntil { source.listings >= 2 }
        XCTAssertTrue(reached7, "loop listing in flight")
        store.setViewing(false)
        let count = source.listings
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(source.listings, count, "no further listing")
        XCTAssertEqual(store.loading, 0)
        XCTAssertTrue(monitor.watched.isEmpty)
        XCTAssertEqual(store.servers.map(\.port), [3000], "the list itself stays")
    }

    func testSessionCloseStopsEverythingAndDropsTheList() async {
        makeStore()
        await viewList()
        store.endSession()
        let count = source.listings
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(source.listings, count)
        XCTAssertFalse(store.viewing)
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(monitor.watched.isEmpty)
        monitor.fire(ident(4242))
        XCTAssertNil(store.snapshot, "a late event is ignored")
    }

    func testDisablingTheModuleStopsEverything() async {
        makeStore()
        await viewList()
        store.deactivate()
        let count = source.listings
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(source.listings, count)
        XCTAssertFalse(store.viewing)
        store.setViewing(true)
        XCTAssertFalse(store.viewing, "an off module cannot be viewed")
        XCTAssertTrue(monitor.watched.isEmpty)
    }

    func testExitDuringAStopLeavesTheStopFlowAlone() async {
        makeStore(policy: VisibleRefreshPolicy(base: .seconds(60), maximum: .seconds(60), idleLimit: 3))
        await viewList()
        let key = store.servers[0].key
        var sawListed: [Bool] = []
        store.confirmStop = { [unowned self] _ in
            inspector.set(4242, .unknown(.exited))
            monitor.fire(ident(4242))
            sawListed.append(store.server(key) != nil)
            return false
        }
        _ = await store.stop(key)
        XCTAssertEqual(sawListed, [true], "no mutation while a confirmation is open")
    }

    // MARK: Real kernel event

    func testRealExitEventFromADisposableChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let id = try XCTUnwrap(LibprocProcessInspector().identity(of: child.processIdentifier).value)
        let live = ProcessExitMonitor()
        var exited: [ProcessIdentity] = []
        live.onExit = { exited.append($0) }
        live.reconcile([id])
        live.reconcile([id])
        XCTAssertEqual(live.watchedCount, 1, "one watcher per identity")
        child.terminate()
        let reached8 = await waitUntil { exited == [id] }
        XCTAssertTrue(reached8, "kqueue exit event arrives")
        XCTAssertEqual(live.watchedCount, 0)
    }

    func testRealMonitorStopsWatchingWhatIsNoLongerWanted() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let id = try XCTUnwrap(LibprocProcessInspector().identity(of: child.processIdentifier).value)
        let live = ProcessExitMonitor()
        var fired = 0
        live.onExit = { _ in fired += 1 }
        live.reconcile([id])
        live.reconcile([])
        XCTAssertEqual(live.watchedCount, 0)
        child.terminate()
        child.waitUntilExit()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fired, 0, "a canceled watch stays quiet")
    }
}
