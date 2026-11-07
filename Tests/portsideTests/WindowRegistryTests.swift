import ApplicationServices
import XCTest
@testable import portside

/// Stand-in for Accessibility. Thread-safe: the registry calls it from one
/// lane per app. A pid can be made slow (blocks until released), failing,
/// or not ready for its first few observe attempts.
private final class FakeWindowSource: WindowSource, @unchecked Sendable {
    final class Observation: WindowObservation, @unchecked Sendable {
        let pid: pid_t
        let changed: () -> Void
        private let lock = NSLock()
        private var _canceled = false
        var canceled: Bool { lock.lock(); defer { lock.unlock() }; return _canceled }
        init(pid: pid_t, changed: @escaping () -> Void) { self.pid = pid; self.changed = changed }
        func cancel() { lock.lock(); _canceled = true; lock.unlock() }
    }

    private let lock = NSLock()
    private var windows: [pid_t: [WindowReading]] = [:]
    private var gates: [pid_t: DispatchSemaphore] = [:]
    private var failing: Set<pid_t> = []
    private var notReady: [pid_t: Int] = [:]
    private var _reads: [pid_t: Int] = [:]
    private var _observations: [Observation] = []
    private var _observeCalls = 0

    func set(_ pid: pid_t, _ list: [WindowReading]) { locked { windows[pid] = list } }
    func block(_ pid: pid_t) { locked { gates[pid] = DispatchSemaphore(value: 0) } }
    func unblock(_ pid: pid_t) { locked { gates.removeValue(forKey: pid) }?.signal() }
    /// Later reads no longer wait; the returned gate still holds the one in flight.
    func detachGate(_ pid: pid_t) -> DispatchSemaphore? { locked { gates.removeValue(forKey: pid) } }
    func fail(_ pid: pid_t, _ on: Bool) { locked { if on { failing.insert(pid) } else { failing.remove(pid) } } }
    func notReady(_ pid: pid_t, times: Int) { locked { notReady[pid] = times } }
    func reads(_ pid: pid_t) -> Int { locked { _reads[pid] ?? 0 } }
    var observeCalls: Int { locked { _observeCalls } }
    var totalReads: Int { locked { _reads.values.reduce(0, +) } }
    func live(_ pid: pid_t) -> [Observation] { locked { _observations.filter { $0.pid == pid && !$0.canceled } } }
    var liveCount: Int { locked { _observations.filter { !$0.canceled }.count } }

    /// A change notification from the app, delivered on a background thread.
    func emit(_ pid: pid_t) { live(pid).forEach { obs in DispatchQueue.global().async { obs.changed() } } }

    func observe(_ pid: pid_t, changed: @escaping () -> Void) -> WindowObserveResult {
        locked {
            _observeCalls += 1
            if let left = notReady[pid], left > 0 {
                notReady[pid] = left - 1
                return .notReady
            }
            let observation = Observation(pid: pid, changed: changed)
            _observations.append(observation)
            return .observing(observation)
        }
    }

    /// Answers with the windows as they were when the call began, like a
    /// slow app replying late.
    func readWindows(of pid: pid_t, observation: WindowObservation?) -> WindowReadResult {
        let (gate, result) = locked { () -> (DispatchSemaphore?, WindowReadResult) in
            _reads[pid, default: 0] += 1
            return (gates[pid], failing.contains(pid) ? .failed : .windows(windows[pid] ?? []))
        }
        gate?.wait()
        return result
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private func app(_ pid: pid_t, _ name: String, launched: TimeInterval = 0) -> RunningAppRecord {
    RunningAppRecord(pid: pid, bundleIdentifier: "test.\(name)", name: name, launchDate: Date(timeIntervalSince1970: launched))
}

private func win(_ handle: String, _ title: String, focused: Bool = false, frame: CGRect? = nil) -> WindowReading {
    WindowReading(handle: handle, title: title, frame: frame, isFocused: focused, isMain: focused)
}

@MainActor
final class WindowRegistryTests: XCTestCase {
    private var source: FakeWindowSource!
    private var granted = true
    private var apps: [RunningAppRecord] = []
    private var frontmost: pid_t?
    private var displays: [DisplayFrame] = []
    private var releases: [() -> Void] = []

    override func setUp() async throws {
        source = FakeWindowSource()
        granted = true
        apps = []
        frontmost = nil
        displays = []
    }

    override func tearDown() async throws {
        releases.forEach { $0() }
        releases = []
    }

    private func makeRegistry() -> WindowRegistry {
        WindowRegistry(
            source: source,
            isAccessGranted: { [unowned self] in self.granted },
            currentApps: { [unowned self] in (self.apps, self.frontmost) },
            currentDisplays: { [unowned self] in self.displays },
            retryDelay: .milliseconds(10)
        )
    }

    private func start(_ registry: WindowRegistry) {
        releases.append(registry.addClient())
    }

    /// Lets lane and main-queue hops run until the condition holds.
    private func wait(
        _ what: String, timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
        until condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out: \(what)", file: file, line: line) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func titles(_ registry: WindowRegistry) -> [String] { registry.snapshot.windows.map(\.title) }

    // MARK: Snapshots and MRU

    func testSeedsAppsAndWindowsInRecentOrderWithDisplays() async {
        displays = [
            DisplayFrame(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            DisplayFrame(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ]
        apps = [app(10, "Alpha"), app(20, "Beta")]
        frontmost = 20
        source.set(10, [win("a1", "A one", frame: CGRect(x: 10, y: 10, width: 400, height: 300))])
        source.set(20, [
            win("b1", "B one", focused: true, frame: CGRect(x: 1100, y: 10, width: 400, height: 300)),
            win("b2", "B two", frame: CGRect(x: 900, y: 10, width: 300, height: 300)),
        ])
        let registry = makeRegistry()
        start(registry)

        XCTAssertEqual(registry.snapshot.apps.map(\.name), ["Beta", "Alpha"], "frontmost app first")
        XCTAssertTrue(registry.snapshot.apps[0].isActive)
        await wait("windows read") { registry.snapshot.windows.count == 3 }
        XCTAssertEqual(titles(registry), ["B one", "B two", "A one"])
        XCTAssertEqual(registry.snapshot.windows.map(\.displayID), [2, 2, 1], "center, then largest overlap")
        XCTAssertTrue(registry.snapshot.windows[0].isFocused)
        XCTAssertEqual(registry.snapshot.apps.map(\.windowAccess), [.ready, .ready])
        XCTAssertTrue(registry.snapshot.accessibilityGranted)
    }

    func testActivationAndFocusUpdateRecentOrder() async {
        apps = [app(10, "Alpha"), app(20, "Beta")]
        frontmost = 10
        source.set(10, [win("a1", "A one", focused: true)])
        source.set(20, [win("b1", "B one"), win("b2", "B two", focused: true)])
        let registry = makeRegistry()
        start(registry)
        await wait("seed") { registry.snapshot.windows.count == 3 }
        XCTAssertEqual(titles(registry).first, "A one")

        registry.appActivated(app(20, "Beta"))
        XCTAssertEqual(registry.snapshot.apps.map(\.name), ["Beta", "Alpha"])
        XCTAssertEqual(titles(registry).first, "B two", "focused window of the activated app is most recent")

        // Focus moves inside the active app.
        source.set(20, [win("b1", "B one", focused: true), win("b2", "B two")])
        source.emit(20)
        await wait("focus change") { self.titles(registry).first == "B one" }
        XCTAssertEqual(titles(registry), ["B one", "B two", "A one"])
    }

    // MARK: Lifecycle

    func testLaunchCreateTitleCloseAndQuit() async {
        let registry = makeRegistry()
        start(registry)
        XCTAssertEqual(registry.snapshot.apps, [])

        source.set(30, [win("c1", "Draft")])
        registry.appLaunched(app(30, "Gamma"))
        XCTAssertEqual(registry.snapshot.apps.first?.windowAccess, .loading)
        await wait("first read") { registry.snapshot.windows.count == 1 }
        let first = registry.snapshot.windows[0].id

        source.set(30, [win("c1", "Draft"), win("c2", "Second")])
        source.emit(30)
        await wait("window created") { registry.snapshot.windows.count == 2 }

        source.set(30, [win("c1", "Final"), win("c2", "Second")])
        source.emit(30)
        await wait("title change") { registry.window(first)?.title == "Final" }
        XCTAssertEqual(registry.window(first)?.id, first, "a title change keeps the identity")

        source.set(30, [win("c2", "Second")])
        source.emit(30)
        await wait("window closed") { registry.snapshot.windows.count == 1 }
        XCTAssertNil(registry.window(first), "a closed window's id is rejected")

        let second = registry.snapshot.windows[0].id
        XCTAssertEqual(source.live(30).count, 1)
        registry.appTerminated(app(30, "Gamma"))
        XCTAssertEqual(registry.snapshot.apps, [])
        XCTAssertNil(registry.window(second))
        XCTAssertEqual(source.live(30).count, 0, "quit releases the observer")
    }

    func testReleasingLastClientStopsEverything() async {
        apps = [app(10, "Alpha")]
        source.set(10, [win("a1", "A one")])
        let registry = makeRegistry()
        let first = registry.addClient()
        let second = registry.addClient()
        await wait("seed") { registry.snapshot.windows.count == 1 }

        first()
        first()
        XCTAssertTrue(registry.isRunning, "a second release of the same client does nothing")
        XCTAssertEqual(source.liveCount, 1)
        second()
        XCTAssertFalse(registry.isRunning)
        XCTAssertEqual(registry.snapshot, .empty)
        XCTAssertEqual(source.liveCount, 0)

        let reads = source.totalReads
        registry.appLaunched(app(40, "Delta"))
        registry.appActivated(app(10, "Alpha"))
        XCTAssertEqual(registry.snapshot, .empty, "idle registry ignores events")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(source.totalReads, reads)
    }

    func testLaunchingAppRetriesObserverThenReads() async {
        source.notReady(50, times: 2)
        source.set(50, [win("e1", "Ready")])
        let registry = makeRegistry()
        start(registry)
        registry.appLaunched(app(50, "Echo"))
        await wait("retry then read") { registry.snapshot.windows.count == 1 }
        XCTAssertEqual(source.observeCalls, 3)
        XCTAssertEqual(registry.snapshot.apps.first?.windowAccess, .ready)
    }

    // MARK: Stale identity and PID reuse

    func testRelaunchOnSamePIDGetsNewIdentity() async {
        apps = [app(60, "Foxtrot", launched: 1)]
        source.set(60, [win("f1", "Old")])
        let registry = makeRegistry()
        start(registry)
        await wait("seed") { registry.snapshot.windows.count == 1 }
        let oldWindow = registry.snapshot.windows[0].id
        let oldApp = registry.snapshot.apps[0].key

        registry.appTerminated(app(60, "Foxtrot", launched: 1))
        // Same pid, same handle value, later launch.
        source.set(60, [win("f1", "New")])
        registry.appLaunched(app(60, "Foxtrot", launched: 2))
        await wait("relaunch read") { registry.snapshot.windows.count == 1 }

        XCTAssertNotEqual(registry.snapshot.apps[0].key, oldApp)
        XCTAssertNotEqual(registry.snapshot.windows[0].id, oldWindow)
        XCTAssertNil(registry.window(oldWindow), "a window id from the earlier launch is rejected")
        XCTAssertNil(registry.app(oldApp))
        XCTAssertEqual(registry.snapshot.windows[0].title, "New")
    }

    func testMissedQuitIsDetectedByLaunchDate() async {
        apps = [app(70, "Golf", launched: 1)]
        source.set(70, [win("g1", "Old")])
        let registry = makeRegistry()
        start(registry)
        await wait("seed") { registry.snapshot.windows.count == 1 }
        let oldWindow = registry.snapshot.windows[0].id

        // No terminate event: a different launch reuses the pid.
        source.set(70, [win("g9", "Other")])
        registry.appActivated(app(70, "Golf", launched: 5))
        XCTAssertNil(registry.window(oldWindow))
        await wait("new launch read") { registry.snapshot.windows.map(\.title) == ["Other"] }
        XCTAssertEqual(source.live(70).count, 1, "the earlier launch's observer was released")

        // A late terminate for the earlier launch must not remove the new one.
        registry.appTerminated(app(70, "Golf", launched: 1))
        XCTAssertEqual(registry.snapshot.apps.count, 1)
    }

    func testLateReadFromEarlierLaunchIsDropped() async {
        apps = [app(80, "Hotel", launched: 1)]
        source.set(80, [win("h1", "Stale")])
        source.block(80)
        let registry = makeRegistry()
        start(registry)
        await wait("old read in flight") { self.source.reads(80) == 1 }

        registry.appTerminated(app(80, "Hotel", launched: 1))
        let oldRead = source.detachGate(80)
        source.set(80, [win("h2", "Fresh")])
        registry.appLaunched(app(80, "Hotel", launched: 2))
        await wait("new read") { self.titles(registry) == ["Fresh"] }
        // The earlier launch answers last.
        oldRead?.signal()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(titles(registry), ["Fresh"], "the old launch's answer never lands on the new one")
    }

    // MARK: Slow Accessibility

    func testSlowAppDoesNotBlockMainThreadOrOtherApps() async {
        apps = [app(90, "Slow"), app(91, "Quick")]
        source.set(90, [win("s1", "Slow window")])
        source.set(91, [win("q1", "Quick window")])
        source.block(90)
        let registry = makeRegistry()

        let started = CFAbsoluteTimeGetCurrent()
        start(registry)
        registry.appActivated(app(90, "Slow"))
        for _ in 0..<20 { source.emit(90) }
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 0.05, "main thread never waits on an app")

        await wait("quick app read while slow one hangs") { registry.snapshot.windows.map(\.title) == ["Quick window"] }
        XCTAssertEqual(registry.app(registry.snapshot.apps.first { $0.name == "Slow" }!.key)?.windowAccess, .loading)

        source.unblock(90)
        await wait("slow app answers") { registry.snapshot.windows.count == 2 }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertLessThanOrEqual(source.reads(90), 2, "changes during a read coalesce into one more read")
    }

    func testTimedOutReadKeepsLastWindowsAsUnresponsive() async {
        apps = [app(95, "India")]
        source.set(95, [win("i1", "Kept")])
        let registry = makeRegistry()
        start(registry)
        await wait("seed") { registry.snapshot.windows.count == 1 }

        source.fail(95, true)
        source.emit(95)
        await wait("timeout reported") { registry.snapshot.apps.first?.windowAccess == .unresponsive }
        XCTAssertEqual(titles(registry), ["Kept"])

        source.fail(95, false)
        source.emit(95)
        await wait("recovers") { registry.snapshot.apps.first?.windowAccess == .ready }
    }

    // MARK: Permission

    func testDeniedAccessibilityGivesAppOnlyStateWithoutAXCalls() async {
        granted = false
        apps = [app(100, "Juliet"), app(101, "Kilo")]
        frontmost = 101
        source.set(100, [win("j1", "Hidden from us")])
        let registry = makeRegistry()
        start(registry)
        registry.appLaunched(app(102, "Lima"))
        registry.appActivated(app(100, "Juliet"))
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(registry.snapshot.accessibilityGranted)
        XCTAssertEqual(registry.snapshot.apps.map(\.name), ["Juliet", "Kilo", "Lima"], "apps still switch in recent order")
        XCTAssertEqual(Set(registry.snapshot.apps.map(\.windowAccess)), [.appOnly])
        XCTAssertEqual(registry.snapshot.windows, [])
        XCTAssertEqual(source.observeCalls, 0)
        XCTAssertEqual(source.totalReads, 0)
    }

    func testGrantThenRevokeAccessibility() async {
        granted = false
        apps = [app(110, "Mike")]
        source.set(110, [win("m1", "Window")])
        let registry = makeRegistry()
        start(registry)

        granted = true
        registry.accessibilityChanged()
        await wait("granted read") { registry.snapshot.windows.count == 1 }
        let id = registry.snapshot.windows[0].id

        // Revoked while a read is in flight: the late answer is dropped.
        source.block(110)
        source.emit(110)
        await wait("read in flight") { self.source.reads(110) == 2 }
        granted = false
        registry.accessibilityChanged()
        XCTAssertEqual(registry.snapshot.windows, [])
        XCTAssertEqual(registry.snapshot.apps.first?.windowAccess, .appOnly)
        XCTAssertEqual(source.liveCount, 0, "revoking releases observers")
        XCTAssertNil(registry.window(id))
        source.unblock(110)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(registry.snapshot.windows, [])
    }

    // MARK: Ownership

    func testRegistryNeverObservesWhatWindowFitterOwns() {
        let registry = Set(AXWindowSource.appNotifications + AXWindowSource.windowNotifications)
        XCTAssertFalse(registry.contains(kAXWindowMovedNotification))
        XCTAssertFalse(registry.contains(kAXWindowResizedNotification))
        XCTAssertTrue(WindowFitter.observedNotifications.contains(kAXWindowMovedNotification))
    }
}
