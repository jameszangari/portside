import Darwin
import XCTest
@testable import portside

/// Listening sockets opened by this test process, so the only listeners
/// these tests look for are their own. Closed on `close()` or deinit.
final class OwnedListeners {
    private(set) var descriptors: [Int32] = []
    private(set) var port: UInt16 = 0

    /// Binds `addresses` in order on one OS-chosen port. IPv6 sockets are
    /// v6-only so the IPv4 and IPv6 wildcards can share the port.
    init(_ addresses: [(Int32, String)]) throws {
        for (family, address) in addresses {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            descriptors.append(fd)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            let bound: Int32
            if family == AF_INET {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                inet_pton(AF_INET, address, &addr.sin_addr)
                bound = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            } else {
                setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in6()
                addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = port.bigEndian
                inet_pton(AF_INET6, address, &addr.sin6_addr)
                bound = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
                }
            }
            guard bound == 0, listen(fd, 4) == 0 else { close(); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if port == 0 {
                var addr = sockaddr_in6()
                var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
                _ = withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
                }
                // sin_port and sin6_port sit at the same offset.
                port = UInt16(bigEndian: addr.sin6_port)
            }
        }
    }

    func close() {
        for fd in descriptors { Darwin.close(fd) }
        descriptors.removeAll()
    }

    deinit { close() }
}

/// Counts concurrent snapshots and blocks each one until released.
private actor GatedSource: ListenerSource {
    private(set) var started: [ListenerQuery] = []
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var canceled = 0
    private var gates: [CheckedContinuation<Void, Never>] = []

    func snapshot(_ query: ListenerQuery) async throws -> ListenerSnapshot {
        started.append(query)
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        await withCheckedContinuation { gates.append($0) }
        if Task.isCancelled {
            canceled += 1
            throw CancellationError()
        }
        return ListenerSnapshotBuilder.failure(query, .exitStatus(9), takenAt: Date(), instant: .now)
    }

    func releaseAll() {
        let waiting = gates
        gates.removeAll()
        waiting.forEach { $0.resume() }
    }

    var waiting: Int { gates.count }
}

/// Waits (bounded) for a condition another task makes true.
private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<400 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("condition never became true", file: file, line: line)
}

/// True when `pid` names no process (and so no zombie): only checked for
/// pids these tests spawned.
private func isGone(_ pid: pid_t) -> Bool {
    errno = 0
    return kill(pid, 0) == -1 && errno == ESRCH
}

final class ListenerDiscoveryTests: XCTestCase {
    // MARK: Invocation

    func testInvocationIsAbsolutePathFixedArgumentsAndNoShell() {
        let all = LsofInvocation.listeners(.all)
        XCTAssertEqual(all.executableURL.path, "/usr/sbin/lsof")
        XCTAssertEqual(all.arguments, ["-nP", "-iTCP", "-sTCP:LISTEN", "+c", "0", "-F", "pcLuftPnT0"])
        XCTAssertEqual(all.environment, ["LC_ALL": "C"])
        let port = LsofInvocation.listeners(ListenerQuery(port: 5173)!)
        XCTAssertEqual(port.arguments, ["-nP", "-iTCP:5173", "-sTCP:LISTEN", "+c", "0", "-F", "pcLuftPnT0"])
        for invocation in [all, port] {
            XCTAssertFalse(["/bin/sh", "/bin/zsh", "/bin/bash", "/usr/bin/env"].contains(invocation.executableURL.path))
            XCTAssertFalse(invocation.arguments.contains { ["-u", "-r", "+r", "+M", "-c", "-w", "+L"].contains($0) })
        }
    }

    func testPortQueryRejectsOutOfRange() {
        XCTAssertNil(ListenerQuery(port: 0))
        XCTAssertNil(ListenerQuery(port: -1))
        XCTAssertNil(ListenerQuery(port: 65536))
        XCTAssertEqual(ListenerQuery(port: 1)?.port, 1)
        XCTAssertEqual(ListenerQuery(port: 65535)?.port, 65535)
        XCTAssertNil(ListenerQuery.all.port)
    }

    // MARK: libproc

    func testOwnProcessIdentityIsKnown() throws {
        let inspector = LibprocProcessInspector()
        let identity = try XCTUnwrap(inspector.identity(of: getpid()).value)
        XCTAssertEqual(identity.pid, getpid())
        XCTAssertEqual(identity.uid, geteuid())
        XCTAssertLessThan(identity.startDate, Date())
        XCTAssertEqual(inspector.identity(of: getpid()).value, identity, "two reads of one process match")
        XCTAssertEqual(inspector.executablePath(of: getpid()).value?.hasPrefix("/"), true)
    }

    func testLaunchdIdentityIsDeniedNotInvented() throws {
        try XCTSkipIf(geteuid() == 0, "running as root")
        let inspector = LibprocProcessInspector()
        XCTAssertEqual(inspector.identity(of: 1), .unknown(.denied))
        let process = ListenerSnapshotBuilder.enrich(
            LsofProcessRecord(pid: 1, name: "launchd", uid: 0, userName: "root", sockets: []),
            inspector: inspector, listedBy: Date()
        )
        XCTAssertFalse(process.hasVerifiedIdentity)
        XCTAssertEqual(process.name, .known("launchd"))
    }

    func testInvalidPidsAreNotRead() {
        let inspector = LibprocProcessInspector()
        XCTAssertEqual(inspector.identity(of: 0), .unknown(.failed(EINVAL)))
        XCTAssertEqual(inspector.identity(of: -1), .unknown(.failed(EINVAL)))
        XCTAssertEqual(inspector.executablePath(of: 0), .unknown(.failed(EINVAL)))
        XCTAssertEqual(LibprocProcessInspector.reason(ESRCH), .exited)
        XCTAssertEqual(LibprocProcessInspector.reason(EPERM), .denied)
    }

    // MARK: Bounded subprocess (stand-in executables, never lsof's target)

    func testDeadlineStopsAChildThatNeverFinishes() async {
        var limits = LsofLimits()
        limits.deadline = .milliseconds(200)
        let invocation = LsofInvocation(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:])
        let clock = ContinuousClock()
        let started = clock.now
        let run = await LsofRunner.run(invocation, limits: limits)
        XCTAssertEqual(run.termination, .timedOut)
        XCTAssertLessThan(clock.now - started, .seconds(2))
        XCTAssertGreaterThan(run.pid, 0)
        XCTAssertTrue(run.reaped)
        XCTAssertTrue(isGone(run.pid), "no zombie or surviving child")
        let snapshot = ListenerSnapshotBuilder.snapshot(.all, run: run, inspector: FakeProcessInspector())
        XCTAssertEqual(snapshot.outcome, .timedOut)
    }

    func testDeadlineEscalatesToSigkillForAChildIgnoringSigterm() async {
        var limits = LsofLimits()
        limits.deadline = .milliseconds(200)
        limits.killGrace = .milliseconds(100)
        // `trap '' TERM` makes the stand-in ignore SIGTERM. This shell is the
        // test's own child; it is not how lsof is run.
        let invocation = LsofInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do sleep 0.05; done"],
            environment: [:]
        )
        let run = await LsofRunner.run(invocation, limits: limits)
        XCTAssertEqual(run.termination, .timedOut)
        XCTAssertTrue(run.reaped)
        XCTAssertTrue(isGone(run.pid))
    }

    func testByteCapStopsAFloodingChild() async {
        var limits = LsofLimits()
        limits.stdoutCap = 64 << 10
        let invocation = LsofInvocation(executableURL: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], environment: [:])
        let run = await LsofRunner.run(invocation, limits: limits)
        XCTAssertTrue(run.stdoutTruncated)
        XCTAssertEqual(run.stdout.count, 64 << 10)
        XCTAssertEqual(run.termination, .signaled(SIGTERM))
        XCTAssertTrue(isGone(run.pid))
        let snapshot = ListenerSnapshotBuilder.snapshot(.all, run: run, inspector: FakeProcessInspector())
        XCTAssertEqual(snapshot.outcome, .partial(truncated: true, malformedRecords: 0))
    }

    func testStderrIsCappedSeparately() async {
        var limits = LsofLimits()
        limits.stderrCap = 1024
        let invocation = LsofInvocation(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 100000 /dev/zero >&2; exit 1"],
            environment: [:]
        )
        let run = await LsofRunner.run(invocation, limits: limits)
        XCTAssertEqual(run.termination, .exited(1))
        XCTAssertTrue(run.stderrTruncated)
        XCTAssertEqual(run.stderr.count, 1024)
        XCTAssertEqual(ListenerSnapshotBuilder.snapshot(.all, run: run, inspector: FakeProcessInspector()).outcome, .failed(.exitStatus(1)))
    }

    func testMissingExecutableIsLaunchFailure() async throws {
        let source = LsofListenerSource { _ in
            LsofInvocation(executableURL: URL(fileURLWithPath: "/nonexistent/portside-tests/lsof"), arguments: [], environment: [:])
        }
        let snapshot = try await source.snapshot(.all)
        guard case .failed(.launchFailed(let reason)) = snapshot.outcome else { return XCTFail("\(snapshot.outcome)") }
        XCTAssertTrue(reason.contains("/nonexistent/portside-tests/lsof"))
        // The gate was released: a second call runs (and fails the same way).
        guard case .failed(.launchFailed) = try await source.snapshot(.all).outcome else { return XCTFail() }
    }

    func testCancellationStopsTheChildAndDeliversNoResult() async throws {
        let runner = Task {
            await LsofRunner.run(
                LsofInvocation(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:]),
                limits: LsofLimits()
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        runner.cancel()
        let run = await runner.value
        XCTAssertEqual(run.termination, .canceled)
        XCTAssertTrue(run.reaped)
        XCTAssertTrue(isGone(run.pid))

        let source = LsofListenerSource { _ in
            LsofInvocation(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:])
        }
        let task = Task { try await source.snapshot(.all) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a canceled snapshot delivered a result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCanceledBeforeStartLaunchesNothing() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LsofRunner.run(
                LsofInvocation(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:]),
                limits: LsofLimits()
            )
        }
        let run = await task.value
        XCTAssertEqual(run.termination, .canceled)
        XCTAssertEqual(run.pid, 0)
    }

    // MARK: Real lsof against this test's own sockets

    private func ownSnapshot(port: UInt16) async throws -> (ListenerSnapshot, ListenerProcess?) {
        let query = try XCTUnwrap(ListenerQuery(port: Int(port)))
        let snapshot = try await ListenerService().snapshot(query)
        return (snapshot, snapshot.processes.first { $0.pid == getpid() })
    }

    func testRealLsofSeesFourBindsOnOnePortAsFourSockets() async throws {
        let listeners = try OwnedListeners([(AF_INET, "127.0.0.1"), (AF_INET, "0.0.0.0"), (AF_INET6, "::1"), (AF_INET6, "::")])
        let (snapshot, mine) = try await ownSnapshot(port: listeners.port)
        XCTAssertEqual(snapshot.outcome, .complete)
        let process = try XCTUnwrap(mine, "own listeners not listed")
        XCTAssertEqual(process.sockets.count, 4)
        XCTAssertEqual(Set(process.sockets.map { "\($0.family.rawValue)/\($0.hostKind)" }),
                       ["4/loopback", "4/wildcard", "6/loopback", "6/wildcard"])
        XCTAssertTrue(process.sockets.allSatisfy { $0.port == listeners.port })
        XCTAssertEqual(Set(process.sockets.map(\.fd)), Set(listeners.descriptors))
        XCTAssertEqual(process.uid, .known(geteuid()))
        XCTAssertEqual(process.identity.value?.uid, geteuid())
        XCTAssertEqual(process.identity.value, LibprocProcessInspector().identity(of: getpid()).value)
        XCTAssertEqual(snapshot.visibleUID, geteuid())
        XCTAssertLessThan(snapshot.duration, .seconds(2))
    }

    func testRealLsofDropsAClosedListener() async throws {
        let listeners = try OwnedListeners([(AF_INET, "127.0.0.1")])
        let port = listeners.port
        let (_, before) = try await ownSnapshot(port: port)
        XCTAssertEqual(before?.sockets.count, 1)
        listeners.close()
        let (after, mine) = try await ownSnapshot(port: port)
        XCTAssertNil(mine, "stale entry after close")
        // lsof exits 1 with no output: no listener visible, not a failure.
        XCTAssertEqual(after.outcome, .complete)
        XCTAssertEqual(after.diagnostics.exitStatus, 1)
    }

    func testRealFullListingIncludesOwnListener() async throws {
        let listeners = try OwnedListeners([(AF_INET6, "::1")])
        let snapshot = try await ListenerService().snapshot(.all)
        XCTAssertNotEqual(snapshot.outcome, .timedOut)
        let mine = try XCTUnwrap(snapshot.processes.first { $0.pid == getpid() })
        XCTAssertTrue(mine.sockets.contains { $0.port == listeners.port && $0.family == .v6 && $0.hostKind == .loopback })
        // Read-only: every listed process is still there afterwards.
        for process in snapshot.processes where process.identity.value != nil {
            XCTAssertEqual(LibprocProcessInspector().identity(of: process.pid), process.identity)
        }
    }

    // MARK: Service: one listing at a time

    func testSameQueryCoalescesOntoOneListing() async throws {
        let source = GatedSource()
        let service = ListenerService(source: source)
        let a = Task { try await service.snapshot(.all) }
        let b = Task { try await service.snapshot(.all) }
        await eventually { await source.waiting == 1 }
        try await Task.sleep(for: .milliseconds(30))
        await source.releaseAll()
        let first = try await a.value
        let second = try await b.value
        XCTAssertEqual(first.outcome, second.outcome)
        let started = await source.started.count
        XCTAssertEqual(started, 1)
        let listings = await service.listingsStarted
        XCTAssertEqual(listings, 1)
    }

    func testDifferentQueriesNeverOverlap() async throws {
        let source = GatedSource()
        let service = ListenerService(source: source)
        let port = try XCTUnwrap(ListenerQuery(port: 5173))
        let a = Task { try await service.snapshot(.all) }
        await eventually { await source.waiting == 1 }
        let b = Task { try await service.snapshot(port) }
        let c = Task { try await service.snapshot(port) }
        try await Task.sleep(for: .milliseconds(30))
        let startedEarly = await source.started.count
        XCTAssertEqual(startedEarly, 1, "second listing started while the first ran")
        await source.releaseAll()
        _ = try await a.value
        await eventually { await source.waiting == 1 }
        await source.releaseAll()
        _ = try await b.value
        _ = try await c.value
        let started = await source.started
        XCTAssertEqual(started, [.all, port])
        let maxActive = await source.maxActive
        XCTAssertEqual(maxActive, 1)
    }

    func testCanceledCallerReturnsAtOnceAndLastCancelStopsTheListing() async throws {
        let source = GatedSource()
        let service = ListenerService(source: source)
        let a = Task { try await service.snapshot(.all) }
        let b = Task { try await service.snapshot(.all) }
        await eventually { await source.waiting == 1 }
        try await Task.sleep(for: .milliseconds(20))
        a.cancel()
        do { _ = try await a.value; XCTFail("canceled caller got a result") } catch { XCTAssertTrue(error is CancellationError) }
        // b still wants it, so the listing keeps going.
        await source.releaseAll()
        _ = try await b.value

        let c = Task { try await service.snapshot(.all) }
        await eventually { await source.waiting == 1 }
        c.cancel()
        do { _ = try await c.value; XCTFail("canceled caller got a result") } catch { XCTAssertTrue(error is CancellationError) }
        // A request after the cancel waits for the canceled listing to end.
        let d = Task { try await service.snapshot(.all) }
        try await Task.sleep(for: .milliseconds(30))
        let startedBeforeRelease = await source.started.count
        XCTAssertEqual(startedBeforeRelease, 2)
        await source.releaseAll()
        await eventually { await source.waiting == 1 }
        let canceled = await source.canceled
        XCTAssertEqual(canceled, 1)
        await source.releaseAll()
        _ = try await d.value
        let maxActive = await source.maxActive
        XCTAssertEqual(maxActive, 1)
    }

    func testQueuedCallerCanCancel() async throws {
        let source = GatedSource()
        let service = ListenerService(source: source)
        let port = try XCTUnwrap(ListenerQuery(port: 8080))
        let a = Task { try await service.snapshot(.all) }
        await eventually { await source.waiting == 1 }
        let b = Task { try await service.snapshot(port) }
        try await Task.sleep(for: .milliseconds(20))
        b.cancel()
        do { _ = try await b.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await source.releaseAll()
        _ = try await a.value
        try await Task.sleep(for: .milliseconds(30))
        let started = await source.started
        XCTAssertEqual(started, [.all], "a canceled queued query still ran")
    }

    func testSourceGateRefusesASecondChildWhileOneIsAlive() async throws {
        // A stand-in that ignores SIGTERM and SIGKILL cannot exist, so hold
        // the gate with a long deadline instead and check the second call.
        var limits = LsofLimits()
        limits.deadline = .seconds(5)
        let source = LsofListenerSource(limits: limits) { _ in
            LsofInvocation(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:])
        }
        let first = Task { try await source.snapshot(.all) }
        try await Task.sleep(for: .milliseconds(150))
        let second = try await source.snapshot(.all)
        XCTAssertEqual(second.outcome, .failed(.previousRunStillExiting))
        first.cancel()
        _ = try? await first.value
        try await Task.sleep(for: .milliseconds(50))
        // Released once the child was reaped.
        let third = Task { try await source.snapshot(.all) }
        try await Task.sleep(for: .milliseconds(150))
        third.cancel()
        do { _ = try await third.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
}
