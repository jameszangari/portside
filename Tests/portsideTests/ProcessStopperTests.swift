import Combine
import Darwin
import XCTest
@testable import portside

/// Only fake PIDs reach this signaler. Real signaling has a separate fixture below.
private final class StopSystem: ProcessInspector, ProcessSignaler, @unchecked Sendable {
    var current: ProcessFact<ProcessIdentity> = .known(ProcessIdentity(pid: 4242, startSeconds: 1_000, startMicroseconds: 7, uid: 501))
    var path: ProcessFact<String> = .known("/tmp/fixture/bin/server")
    var parent: ProcessFact<pid_t> = .known(200)
    var signals: [pid_t] = []
    var signalError: Int32?
    var afterSignal: (() -> Void)?
    var identityRead: (() -> Void)?

    func identity(of pid: pid_t) -> ProcessFact<ProcessIdentity> { identityRead?(); return current }
    func executablePath(of pid: pid_t) -> ProcessFact<String> { path }
    func parentPID(of pid: pid_t) -> ProcessFact<pid_t> { parent }
    func terminate(_ pid: pid_t) -> Int32? {
        signals.append(pid)
        afterSignal?()
        return signalError
    }
}

private func stopServer(pid: pid_t = 4242, uid: uid_t = 501, path: String = "/tmp/fixture/bin/server", known: Bool = true) -> LocalServer {
    let sockets = [ListenerSocket(family: .v4, hostKind: .loopback, host: "127.0.0.1", port: 5173, fd: 3),
                   ListenerSocket(family: .v6, hostKind: .loopback, host: "::1", port: 5173, fd: 4)]
    let process = ListenerProcess(pid: pid, name: .known("fixture server"), uid: .known(uid), userName: .known("tester"),
                                  identity: known ? .known(ProcessIdentity(pid: pid, startSeconds: 1_000, startMicroseconds: 7, uid: uid)) : .unknown(.notReported),
                                  executablePath: .known(path), sockets: sockets)
    return LocalServer.servers(in: stopSnapshot(.all, processes: [process]))[0]
}

private func stopSnapshot(_ query: ListenerQuery, processes: [ListenerProcess], outcome: ListenerOutcome = .complete) -> ListenerSnapshot {
    ListenerSnapshot(query: query, processes: processes, outcome: outcome, diagnostics: ListenerDiagnostics(), visibleUID: 501,
                     takenAt: Date(), takenAtInstant: .now, duration: .zero)
}

private actor StopSource: ListenerSource {
    var processes = [stopServer().process]
    var outcome = ListenerOutcome.complete
    var queries: [ListenerQuery] = []
    var delay: Duration = .zero
    var onRead: (@Sendable () async -> Void)?

    func set(processes: [ListenerProcess]? = nil, outcome: ListenerOutcome? = nil, delay: Duration = .zero,
             onRead: (@Sendable () async -> Void)? = nil) {
        if let processes { self.processes = processes }
        if let outcome { self.outcome = outcome }
        self.delay = delay
        self.onRead = onRead
    }

    func snapshot(_ query: ListenerQuery) async throws -> ListenerSnapshot {
        queries.append(query)
        let processes = self.processes
        if delay > .zero { try await Task.sleep(for: delay) }
        await onRead?()
        return stopSnapshot(query, processes: processes, outcome: outcome)
    }
}

@MainActor
final class ProcessStopperTests: XCTestCase {
    private var system: StopSystem!
    private var source: StopSource!
    private var stopper: ProcessStopper!
    private var listeners: ListenerService!

    override func setUp() async throws {
        system = StopSystem()
        source = StopSource()
        listeners = ListenerService(source: source)
        stopper = ProcessStopper(inspector: system, signaler: system,
                                 policy: ProcessStopPolicy(uid: 501, ownPID: 100, parentPID: 99), timeout: .milliseconds(20))
    }

    private func stop(_ server: LocalServer = stopServer()) async -> ProcessStopOutcome {
        await stopper.stop(server, listeners: listeners, authorized: { true })
    }

    func testStopsOnlyExactPIDOnceAndQueriesSelectedPort() async {
        system.afterSignal = { self.system.current = .unknown(.exited) }
        let outcome = await stop()
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(system.signals, [4242])
        let queries = await source.queries
        XCTAssertEqual(queries, [ListenerQuery(port: 5173)!])
    }

    func testPIDReuseIncludingMicrosecondChangeSendsNothing() async {
        for identity in [ProcessIdentity(pid: 4242, startSeconds: 1_001, startMicroseconds: 7, uid: 501),
                         ProcessIdentity(pid: 4242, startSeconds: 1_000, startMicroseconds: 8, uid: 501),
                         ProcessIdentity(pid: 4243, startSeconds: 1_000, startMicroseconds: 7, uid: 501)] {
            system.current = .known(identity)
            let outcome = await stop()
            XCTAssertEqual(outcome, .targetChanged)
        }
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testOwnershipChangesDuringPortLookupSendsNothing() async {
        await source.set(onRead: { [system] in
            system?.current = .known(ProcessIdentity(pid: 4242, startSeconds: 1_000, startMicroseconds: 7, uid: 502))
        })
        let outcome = await stop()
        XCTAssertEqual(outcome, .denied)
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testIdentityChangesOnFinalReadSendsNothing() async {
        var reads = 0
        system.identityRead = {
            reads += 1
            if reads == 3 { self.system.current = .known(ProcessIdentity(pid: 4242, startSeconds: 2_000, startMicroseconds: 7, uid: 501)) }
        }
        let outcome = await stop()
        XCTAssertEqual(outcome, .targetChanged)
        XCTAssertEqual(reads, 3)
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testForeignAndRootOwnersRefused() async {
        for uid: uid_t in [0, 502] {
            let outcome = await stop(stopServer(uid: uid))
            XCTAssertEqual(outcome, .denied)
        }
        stopper.policy.uid = 0
        let outcome = await stop(stopServer(uid: 0))
        XCTAssertEqual(outcome, .denied)
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testProtectedPIDSelfParentAndHelperRefused() async {
        for pid: pid_t in [-1, 0, 1, 99, 100] {
            let outcome = await stop(stopServer(pid: pid))
            XCTAssertEqual(outcome, .protected)
        }
        system.parent = .known(100)
        let outcome = await stop()
        XCTAssertEqual(outcome, .protected)
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testProtectedPathsAndNamesRefused() async {
        for path in ["/System/Library/server", "/sYsTeM/Library/server", "/USR/BIN/server", "/usr/libexec/server", "/usr/sbin/server", "/sbin/server", "/bin/server",
                     "/usr/bin/server", "/Library/Apple/server", "/tmp/../usr/bin/server", "/opt/bin/Dock", "/opt/bin/Finder",
                     "/opt/bin/launchd", "/opt/bin/WindowServer", "/opt/bin/Portside"] {
            let outcome = await stop(stopServer(path: path))
            XCTAssertEqual(outcome, .protected, path)
        }
        XCTAssertFalse(stopper.policy.protects(path: "/usr/bin-local/server"))
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testSymlinkIntoProtectedPathRefused() throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/usr/bin"))
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertTrue(stopper.policy.protects(path: link.appendingPathComponent("true").path))
    }

    func testUnknownIdentityPathAndParentFailClosed() async {
        let unknownIdentity = await stop(stopServer(known: false))
        guard case .failed = unknownIdentity else { return XCTFail("unknown identity allowed") }
        system.path = .unknown(.notReported)
        let unknownPath = await stop()
        guard case .failed = unknownPath else { return XCTFail("unknown path allowed") }
        system.path = .known("/tmp/fixture/bin/server")
        system.parent = .unknown(.notReported)
        let unknownParent = await stop()
        guard case .failed = unknownParent else { return XCTFail("unknown helper ancestry allowed") }
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testChangedExecutableOrNewProtectedPathRefused() async {
        system.path = .known("/opt/other/server")
        let changed = await stop()
        XCTAssertEqual(changed, .targetChanged)
        system.path = .known("/usr/bin/server")
        let protected = await stop()
        XCTAssertEqual(protected, .protected)
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testPortLostOrReassignedSendsNothing() async {
        for processes in [[], [stopServer(pid: 4243).process]] {
            await source.set(processes: processes)
            let outcome = await stop()
            XCTAssertEqual(outcome, .targetChanged)
        }
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testIncompletePortLookupFailsClosed() async {
        for outcome: ListenerOutcome in [.partial(truncated: true, malformedRecords: 0), .timedOut, .failed(.exitStatus(2))] {
            await source.set(outcome: outcome)
            let result = await stop()
            guard case .failed = result else { return XCTFail("incomplete listing allowed") }
        }
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testExitBeforeAndDuringPortLookup() async {
        system.current = .unknown(.exited)
        let before = await stop()
        XCTAssertEqual(before, .alreadyExited)
        system.current = stopServer().process.identity
        await source.set(processes: [], onRead: { [system] in system?.current = .unknown(.exited) })
        let during = await stop()
        XCTAssertEqual(during, .alreadyExited)
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testSignalErrorsNeverBecomeStopped() async {
        for (code, expected): (Int32, ProcessStopOutcome) in [(ESRCH, .alreadyExited), (EPERM, .denied), (EACCES, .denied), (EINVAL, .failed("SIGTERM returned error 22."))] {
            system.signalError = code
            system.afterSignal = { self.system.current = .unknown(.exited) }
            system.current = stopServer().process.identity
            let outcome = await stop()
            XCTAssertEqual(outcome, expected)
        }
        XCTAssertEqual(system.signals, [4242, 4242, 4242, 4242])
    }

    func testTimeoutSendsOnlyOneSIGTERM() async {
        let start = ContinuousClock.now
        let outcome = await stop()
        XCTAssertEqual(outcome, .stillRunning)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(system.signals, [4242])
    }

    func testPIDReusedAfterSignalMeansOriginalStoppedNoSecondSignal() async {
        system.afterSignal = { self.system.current = .known(ProcessIdentity(pid: 4242, startSeconds: 2000, startMicroseconds: 7, uid: 501)) }
        let outcome = await stop()
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(system.signals, [4242])
    }

    func testOwnershipChangeAfterSignalIsNotAnExit() async {
        system.afterSignal = { self.system.current = .known(ProcessIdentity(pid: 4242, startSeconds: 1_000, startMicroseconds: 7, uid: 502)) }
        let outcome = await stop()
        XCTAssertEqual(outcome, .failed("SIGTERM was sent, but process ownership changed before exit was verified."))
        XCTAssertEqual(system.signals, [4242])
    }

    func testCannotInspectAfterSignalIsNotSuccess() async {
        system.afterSignal = { self.system.current = .unknown(.denied) }
        let outcome = await stop()
        XCTAssertEqual(outcome, .failed("SIGTERM was sent, but process exit could not be verified."))
    }

    func testCanceledBeforeAndDuringLookupSendsNothing() async throws {
        let before = Task { await self.stop() }
        before.cancel()
        let first = await before.value
        XCTAssertEqual(first, .canceled)
        await source.set(delay: .seconds(1))
        let during = Task { await self.stop() }
        try await Task.sleep(for: .milliseconds(20))
        during.cancel()
        let second = await during.value
        XCTAssertEqual(second, .canceled)
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testAuthorizationRevokedDuringLookupSendsNothing() async {
        var allowed = true
        await source.set(onRead: { await MainActor.run { allowed = false } })
        let result = await stopper.stop(stopServer(), listeners: listeners, authorized: { allowed })
        XCTAssertEqual(result, .canceled)
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testCancellationAfterSignalDoesNotClaimUndo() async throws {
        stopper.timeout = .seconds(5)
        let task = Task { await self.stop() }
        while system.signals.isEmpty { await Task.yield() }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed("SIGTERM was sent; exit observation was canceled."))
        XCTAssertEqual(system.signals, [4242])
    }

    func testFreshSnapshotDoesNotJoinExistingListing() async throws {
        await source.set(delay: .milliseconds(50))
        let query = ListenerQuery(port: 5173)!
        let first = Task { try await self.listeners.snapshot(query) }
        while await source.queries.isEmpty { await Task.yield() }
        _ = try await listeners.snapshot(query, fresh: true)
        _ = try await first.value
        let queries = await source.queries
        XCTAssertEqual(queries, [query, query])
    }

    func testConfirmationCancelAndExpiryNeverSignalAndRefresh() async {
        for lifetime: Duration in [.seconds(60), .zero] {
            let store = LocalServerStore(service: listeners, stopper: stopper, confirmationLifetime: lifetime)
            store.activate()
            _ = await store.refresh()
            var confirmations = 0
            store.confirmStop = { server in
                confirmations += 1
                XCTAssertEqual(server, stopServer())
                return lifetime == .zero
            }
            _ = await store.stop(stopServer().key)
            XCTAssertEqual(confirmations, 1)
            if lifetime == .zero {
                XCTAssertEqual(store.lastStopOutcome, .failed("Confirmation expired. Select Stop Server again."))
            } else { XCTAssertEqual(store.lastStopOutcome, .canceled) }
            XCTAssertNotNil(store.snapshot)
        }
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testConcurrentStopCannotReuseConfirmation() async {
        let store = LocalServerStore(service: listeners, stopper: stopper)
        store.activate()
        _ = await store.refresh()
        system.afterSignal = { self.system.current = .unknown(.exited) }
        store.confirmStop = { _ in
            let duplicate = await store.stop(stopServer().key)
            XCTAssertEqual(duplicate, .failure(CommandFailure(reason: "A server stop is already in progress.")))
            return true
        }
        _ = await store.stop(stopServer().key)
        XCTAssertEqual(store.lastStopOutcome, .stopped)
        XCTAssertEqual(system.signals, [4242])
    }

    func testPreflightRefusalSkipsConfirmation() async {
        let store = LocalServerStore(service: listeners, stopper: stopper)
        store.activate()
        _ = await store.refresh()
        system.current = .unknown(.denied)
        store.confirmStop = { _ in XCTFail("must refuse before approval"); return true }
        _ = await store.stop(stopServer().key)
        XCTAssertEqual(store.lastStopOutcome, .denied)
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testNoUIApprovalOrFabricatedKeyCannotSignal() async {
        let store = LocalServerStore(service: listeners, stopper: stopper)
        store.activate()
        _ = await store.refresh()
        let withoutUI = await store.stop(stopServer().key)
        XCTAssertEqual(withoutUI, .failure(CommandFailure(reason: "Select Stop Server in Command Center to confirm.")))
        store.confirmStop = { _ in XCTFail("unknown key should not confirm"); return true }
        _ = await store.stop("model-generated-4242")
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testSessionEndsDuringConfirmationSendsNothing() async {
        let store = LocalServerStore(service: listeners, stopper: stopper)
        store.activate()
        _ = await store.refresh()
        store.confirmStop = { _ in store.endSession(); return true }
        _ = await store.stop(stopServer().key)
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(system.signals.isEmpty)
    }

    func testClosingSessionCancelsPostSignalRefresh() async {
        let store = LocalServerStore(service: listeners, stopper: stopper)
        store.activate()
        _ = await store.refresh()
        store.confirmStop = { _ in true }
        system.afterSignal = { self.system.current = .unknown(.exited) }
        await source.set(onRead: { [source] in await source?.set(delay: .seconds(2)) })
        let work = Task { await store.stop(stopServer().key) }
        while await source.queries.count < 3 { await Task.yield() }
        let start = ContinuousClock.now
        store.endSession()
        _ = await work.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.lastStopReceipt)
        XCTAssertEqual(system.signals, [4242])
    }

    func testPostActionRefreshCannotJoinPreActionListing() async {
        stopper.timeout = .milliseconds(50)
        let store = LocalServerStore(service: listeners, stopper: stopper)
        store.activate()
        _ = await store.refresh()
        store.confirmStop = { _ in true }
        var competingRefresh: Task<Void, Never>?
        system.afterSignal = {
            competingRefresh = Task {
                await self.source.set(delay: .milliseconds(100))
                let old = Task { await store.refresh() }
                while await self.source.queries.count < 3 { await Task.yield() }
                await self.source.set(processes: [])
                _ = await old.value
            }
        }
        _ = await store.stop(stopServer().key)
        await competingRefresh?.value
        XCTAssertEqual(store.lastStopOutcome, .stillRunning)
        XCTAssertTrue(store.servers.isEmpty, "post-action refresh must not reuse the older all-ports listing")
        let queries = await source.queries
        XCTAssertEqual(queries, [.all, ListenerQuery(port: 5173)!, .all, .all])
    }

    func testSuccessRefreshDropsAllRowsForStoppedProcess() async {
        let store = LocalServerStore(service: listeners, stopper: stopper)
        store.activate()
        _ = await store.refresh()
        store.confirmStop = { _ in true }
        system.afterSignal = { self.system.current = .unknown(.exited) }
        await source.set(onRead: { [source] in await source?.set(processes: []) })
        let result = await store.stop(stopServer().key)
        guard case .success = result else { return XCTFail("\(result)") }
        XCTAssertEqual(store.lastStopOutcome, .stopped)
        XCTAssertTrue(store.servers.isEmpty)
        let queries = await source.queries
        XCTAssertEqual(queries, [.all, ListenerQuery(port: 5173)!, .all])
    }

    func testCanceledCommandShowsOnlyItsNewStopReceipt() {
        let receipt = LocalServerStopReceipt(pid: 4242, port: 5173, outcome: .failed("SIGTERM was sent; exit observation was canceled."))
        XCTAssertEqual(CommandCenter.stopResult(.canceled, command: LocalServersModule.stopCommand, previousReceipt: nil, receipt: receipt), .failed(receipt.message))
        XCTAssertEqual(CommandCenter.stopResult(.canceled, command: LocalServersModule.stopCommand, previousReceipt: receipt.id, receipt: receipt), .canceled)
        XCTAssertEqual(CommandCenter.stopResult(.canceled, command: LocalServersModule.refreshCommand, previousReceipt: nil, receipt: receipt), .canceled)
    }

    func testStoppedRowRemovalKeepsReceiptAndSkipsHistory() {
        var row = CommandCenterItem(id: .server(stopServer().key), kind: .server, title: "Fixture",
                                    invocation: CommandInvocation(command: LocalServersModule.stopCommand, input: .string(stopServer().key), staysOpen: true),
                                    primaryTitle: "Stop", copyValue: "", copyTitle: "Copy")
        row.moreActions = []
        var state = CommandCenterState()
        _ = state.send(.open([row]))
        _ = state.send(.key(.return))
        _ = state.send(.catalog([]))
        let done = state.send(.finished(row.id, .success("Stopped.")))
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.notice?.message, "Stopped.")
        XCTAssertEqual(done.effects, [.announce("Stopped.")])
    }

    func testConfirmationIdentifiesProcessPIDPortOwnerAndExecutable() {
        let text = CommandCenter.stopConfirmationText(stopServer())
        for expected in ["fixture server", "PID: 4242", "Selected port: 5173", "Owner UID: 501", "/tmp/fixture/bin/server", "SIGTERM", "other ports", "No force stop"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
    }
}

/// Compiles a tiny test-owned executable, keeping it outside protected OS
/// paths. Its stdin is the cleanup channel; no SIGKILL is needed, even on failure.
private final class DisposableStopServer {
    let directory: URL
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    var port: UInt16 = 0

    init(ignoresTerm: Bool) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("portside-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/process-stop/server.c")
        let binary = directory.appendingPathComponent("disposable-server")
        compiler.arguments = [fixture.path, "-o", binary.path]
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw CommandFailure(reason: "Fixture compiler failed") }
        process.executableURL = binary
        process.arguments = ignoresTerm ? ["ignore-term"] : []
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.availableData
        guard let value = UInt16(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            close()
            throw CommandFailure(reason: "Fixture did not publish its port")
        }
        port = value
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.waitUntilExit() }
        try? output.fileHandleForReading.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Hard guard: actual signaling only reaches the child this harness owns.
private final class OwnedChildSignaler: ProcessSignaler, @unchecked Sendable {
    let pid: pid_t
    var calls = 0
    init(pid: pid_t) { self.pid = pid }
    func terminate(_ pid: pid_t) -> Int32? {
        guard pid == self.pid, pid > 1 else { XCTFail("non-fixture target"); return EPERM }
        calls += 1
        return SIGTERMProcessSignaler().terminate(pid)
    }
}

@MainActor
final class ProcessStopIntegrationTests: XCTestCase {
    func testRealOwnedChildExitsAndPortDisappears() async throws {
        try await runChild(ignoresTerm: false)
    }

    func testRealOwnedChildIgnoringSIGTERMSurvivesTimeoutWithoutEscalation() async throws {
        try await runChild(ignoresTerm: true)
    }

    private func runChild(ignoresTerm: Bool) async throws {
        let child = try DisposableStopServer(ignoresTerm: ignoresTerm)
        defer { child.close() }
        let service = ListenerService()
        let query = ListenerQuery(port: Int(child.port))!
        let snapshot = try await service.snapshot(query)
        let server = try XCTUnwrap(LocalServer.servers(in: snapshot).first { $0.process.pid == child.process.processIdentifier })
        let signaler = OwnedChildSignaler(pid: child.process.processIdentifier)
        // Simulate a host distinct from XCTest, whose child is intentionally
        // the target. Production defaults still protect Portside's own helpers.
        var policy = ProcessStopPolicy()
        policy.ownPID = pid_t.max
        let stopper = ProcessStopper(signaler: signaler, policy: policy, timeout: ignoresTerm ? .milliseconds(150) : .seconds(2))
        XCTAssertEqual(LibprocProcessInspector().parentPID(of: server.process.pid), .known(getpid()))
        XCTAssertEqual(ProcessStopper().revalidate(server), .protected, "production protects its own child")
        let outcome = await stopper.stop(server, listeners: service, authorized: { true })
        XCTAssertEqual(outcome, ignoresTerm ? .stillRunning : .stopped)
        XCTAssertEqual(signaler.calls, 1)
        let after = try await service.snapshot(query)
        XCTAssertEqual(after.processes.contains { $0.pid == server.process.pid }, ignoresTerm)
        if ignoresTerm { XCTAssertTrue(child.process.isRunning) }
    }

    func testModuleGateAndDisableDuringValidationPreventSignal() async throws {
        let source = StopSource()
        let system = StopSystem()
        let stopper = ProcessStopper(inspector: system, signaler: system, policy: ProcessStopPolicy(uid: 501, ownPID: 100, parentPID: 99))
        let store = LocalServerStore(service: ListenerService(source: source), stopper: stopper)
        let commands = CommandRegistry()
        let modules = ModuleRegistry(commands: commands, permissions: PermissionGate())
        let center = CommandCenter(commands: commands, moduleTitle: { _ in nil }, registrar: { _, _ in NSObject() }, report: { _ in })
        try modules.register(CommandCenterModule(center: center, chords: Just(nil).eraseToAnyPublisher()))
        try modules.register(LocalServersModule(store: store))
        modules.enable(CommandCenterModule.moduleID)
        let input = CommandInput.string(stopServer().key)
        let off = await commands.execute(LocalServersModule.stopCommand, input: input)
        XCTAssertEqual(off, .unavailable("Local Servers is turned off."))
        modules.enable(LocalServersModule.moduleID)
        _ = await store.refresh()
        store.confirmStop = { _ in true }
        await source.set(onRead: { await MainActor.run { _ = modules.disable(LocalServersModule.moduleID) } })
        let disabled = await commands.execute(LocalServersModule.stopCommand, input: input)
        XCTAssertEqual(disabled, .failed("Local Servers stopped before the command finished."))
        XCTAssertTrue(system.signals.isEmpty)
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(modules.resourceCount(of: LocalServersModule.moduleID), 0)
        modules.stopAll()
    }
}
