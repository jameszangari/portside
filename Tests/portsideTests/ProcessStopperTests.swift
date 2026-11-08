import Combine
import Darwin
import XCTest
@testable import portside

/// Only fake PIDs reach this signaler. Real signaling has a separate fixture below.
private final class StopSystem: ProcessInspector, ProcessSignaler, ForceProcessSignaler, @unchecked Sendable {
    var current: ProcessFact<ProcessIdentity> = .known(ProcessIdentity(pid: 4242, startSeconds: 1_000, startMicroseconds: 7, uid: 501))
    var path: ProcessFact<String> = .known("/tmp/fixture/bin/server")
    var parent: ProcessFact<pid_t> = .known(200)
    var signals: [pid_t] = []
    var forceSignals: [pid_t] = []
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
    func forceStop(_ pid: pid_t) -> Int32? {
        forceSignals.append(pid)
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
        stopper = ProcessStopper(inspector: system, signaler: system, forceSignaler: system,
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

    private func forceStore(lifetime: Duration = .seconds(60)) async -> LocalServerStore {
        let store = LocalServerStore(service: listeners, stopper: stopper, confirmationLifetime: lifetime)
        store.activate()
        _ = await store.refresh()
        store.confirmStop = { _ in true }
        store.confirmForceStop = { _ in true }
        _ = await store.stop(stopServer().key)
        XCTAssertEqual(store.lastStopOutcome, .stillRunning)
        return store
    }

    func testForceRequiresGracefulTimeoutAndUnforgeableUIIntent() async {
        let store = LocalServerStore(service: listeners, stopper: stopper)
        store.activate()
        _ = await store.refresh()
        XCTAssertNil(store.beginForceStop(stopServer().key))
        _ = await store.forceStop(stopServer().key)
        XCTAssertTrue(system.forceSignals.isEmpty)
        store.confirmStop = { _ in true }
        _ = await store.stop(stopServer().key)
        XCTAssertTrue(store.canForceStop(stopServer()))
        _ = await store.forceStop(stopServer().key)
        XCTAssertTrue(system.forceSignals.isEmpty)
        let token = store.beginForceStop(stopServer().key)!
        var prompts = 0
        store.confirmForceStop = { _ in prompts += 1; return true }
        system.afterSignal = { self.system.current = .unknown(.exited) }
        _ = await store.forceStop(token)
        _ = await store.forceStop(token)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(system.signals, [4242])
        XCTAssertEqual(system.forceSignals, [4242])
        XCTAssertEqual(store.lastStopOutcome, .stopped)
        XCTAssertTrue(store.lastStopReceipt!.message.contains("SIGKILL"))
        XCTAssertFalse(store.canForceStop(stopServer()))
    }

    func testForceRegistryRequiresUIIntentAndPublishesEligibilityAfterRefresh() async throws {
        let store = LocalServerStore(service: listeners, stopper: stopper)
        store.activate()
        _ = await store.refresh()
        let registry = CommandRegistry()
        for command in LocalServersModule(store: store).commands() { try registry.register(command) }
        var offered = false
        store.onChange = { offered = offered || store.canForceStop(stopServer()) }
        store.confirmStop = { _ in true }
        _ = await store.stop(stopServer().key)
        XCTAssertTrue(offered)
        var prompts = 0
        store.confirmForceStop = { _ in prompts += 1; return true }
        let refused = await registry.execute(LocalServersModule.forceStopCommand, input: .string(stopServer().key))
        guard case .failed = refused else { return XCTFail("server key bypassed UI intent") }
        XCTAssertEqual(prompts, 0)
        XCTAssertTrue(system.forceSignals.isEmpty)
        let token = try XCTUnwrap(store.beginForceStop(stopServer().key))
        system.afterSignal = { self.system.current = .unknown(.exited) }
        let approved = await registry.execute(LocalServersModule.forceStopCommand, input: .string(token))
        guard case .success = approved else { return XCTFail("\(approved)") }
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(system.forceSignals, [4242])
        store.onChange = nil
    }

    func testForceCancelExpiredMissingAndClosedConfirmationSendNothing() async {
        for scenario in ["cancel", "expire", "missing", "close", "disable", "taskCancel"] {
            let store = await forceStore(lifetime: .milliseconds(60))
            let token = store.beginForceStop(stopServer().key)!
            store.confirmForceStop = { _ in
                switch scenario {
                case "expire": try? await Task.sleep(for: .milliseconds(100))
                case "close": store.endSession()
                case "disable": store.deactivate()
                case "taskCancel": withUnsafeCurrentTask { $0?.cancel() }
                default: break
                }
                return scenario != "cancel"
            }
            if scenario == "missing" { store.confirmForceStop = nil }
            let task = Task { await store.forceStop(token) }
            _ = await task.value
            XCTAssertTrue(system.forceSignals.isEmpty, scenario)
            XCTAssertFalse(store.canForceStop(stopServer()), scenario)
            _ = await store.forceStop(token)
            XCTAssertTrue(system.forceSignals.isEmpty, "replay: \(scenario)")
        }
    }

    func testForceApprovalExpiresDuringFreshPortLookup() async {
        let store = await forceStore(lifetime: .milliseconds(60))
        let token = store.beginForceStop(stopServer().key)!
        await source.set(delay: .milliseconds(100))
        _ = await store.forceStop(token)
        XCTAssertTrue(system.forceSignals.isEmpty)
    }

    func testForceDoubleInvocationCannotConfirmOrSignalTwice() async {
        let store = await forceStore()
        let token = store.beginForceStop(stopServer().key)!
        var prompts = 0
        store.confirmForceStop = { _ in
            prompts += 1
            XCTAssertNil(store.beginForceStop(stopServer().key))
            _ = await store.forceStop(token)
            return true
        }
        system.afterSignal = { self.system.current = .unknown(.exited) }
        _ = await store.forceStop(token)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(system.forceSignals, [4242])
    }

    func testForceExpiredUIIntentAndPreflightExitSkipConfirmation() async throws {
        for expired in [false, true] {
            let store = await forceStore(lifetime: .milliseconds(60))
            let token = store.beginForceStop(stopServer().key)!
            var prompts = 0
            store.confirmForceStop = { _ in prompts += 1; return true }
            if expired { try await Task.sleep(for: .milliseconds(100)) }
            else { system.current = .unknown(.exited) }
            _ = await store.forceStop(token)
            XCTAssertEqual(prompts, 0)
            XCTAssertTrue(system.forceSignals.isEmpty)
            XCTAssertFalse(store.canForceStop(stopServer()))
            system.current = stopServer().process.identity
        }
    }

    func testForceRechecksAllSecurityFactsBeforeSignal() async {
        for scenario in ["seconds", "microseconds", "uid", "root", "missingIdentity", "missingPath", "missingParent", "path", "protected", "helper", "exit", "port", "partial", "timeout"] {
            system = StopSystem()
            source = StopSource()
            listeners = ListenerService(source: source)
            stopper = ProcessStopper(inspector: system, signaler: system, forceSignaler: system,
                                     policy: ProcessStopPolicy(uid: 501, ownPID: 100, parentPID: 99), timeout: .zero)
            let store = await forceStore()
            let token = store.beginForceStop(stopServer().key)!
            store.confirmForceStop = { _ in
                switch scenario {
                case "seconds": self.system.current = .known(ProcessIdentity(pid: 4242, startSeconds: 1001, startMicroseconds: 7, uid: 501))
                case "microseconds": self.system.current = .known(ProcessIdentity(pid: 4242, startSeconds: 1000, startMicroseconds: 8, uid: 501))
                case "uid", "root": self.system.current = .known(ProcessIdentity(pid: 4242, startSeconds: 1000, startMicroseconds: 7, uid: scenario == "root" ? 0 : 502))
                case "missingIdentity": self.system.current = .unknown(.notReported)
                case "missingPath": self.system.path = .unknown(.notReported)
                case "missingParent": self.system.parent = .unknown(.notReported)
                case "path": self.system.path = .known("/tmp/replaced")
                case "protected": self.system.path = .known("/usr/bin/server")
                case "helper": self.system.parent = .known(100)
                case "exit": self.system.current = .unknown(.exited)
                case "port": await self.source.set(processes: [stopServer(pid: 4243).process])
                case "partial": await self.source.set(outcome: .partial(truncated: true, malformedRecords: 0))
                case "timeout": await self.source.set(outcome: .timedOut)
                default: XCTFail(scenario)
                }
                return true
            }
            _ = await store.forceStop(token)
            XCTAssertTrue(system.forceSignals.isEmpty, scenario)
            XCTAssertFalse(store.canForceStop(stopServer()), scenario)
            if scenario == "exit" { XCTAssertEqual(store.lastStopOutcome, .alreadyExited) }
        }
    }

    func testForceFinalReadAndFinalApprovalGuard() async {
        for revoke in [false, true] {
            system.current = stopServer().process.identity
            var reads = 0
            var authorized = true
            system.identityRead = {
                reads += 1
                if reads == 3 {
                    if revoke { authorized = false }
                    else { self.system.current = .known(ProcessIdentity(pid: 4242, startSeconds: 2000, startMicroseconds: 7, uid: 501)) }
                }
            }
            let result = await stopper.forceStop(stopServer(), listeners: listeners, authorized: { authorized })
            XCTAssertEqual(result, revoke ? .canceled : .targetChanged)
            XCTAssertTrue(system.forceSignals.isEmpty)
        }
    }

    func testForceProtectedPIDsMissingSelectionFactsAndNoLongerOwnedPort() async {
        for pid: pid_t in [-1, 0, 1, 99, 100] {
            let result = await stopper.forceStop(stopServer(pid: pid), listeners: listeners, authorized: { true })
            XCTAssertEqual(result, .protected)
        }
        let unknown = await stopper.forceStop(stopServer(known: false), listeners: listeners, authorized: { true })
        guard case .failed = unknown else { return XCTFail("unknown identity allowed") }
        await source.set(processes: [])
        let lost = await stopper.forceStop(stopServer(), listeners: listeners, authorized: { true })
        XCTAssertEqual(lost, .targetChanged)
        XCTAssertTrue(system.forceSignals.isEmpty)
    }

    func testForceCancellationAfterSignalRefreshesWithoutClaimingUndo() async {
        let store = await forceStore()
        let token = store.beginForceStop(stopServer().key)!
        system.afterSignal = { withUnsafeCurrentTask { $0?.cancel() } }
        await source.set(onRead: { [source] in await source?.set(processes: []) })
        let task = Task { await store.forceStop(token) }
        _ = await task.value
        XCTAssertEqual(store.lastStopOutcome, .failed("SIGKILL was sent; exit observation was canceled."))
        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertEqual(system.forceSignals, [4242])
        XCTAssertFalse(store.canForceStop(stopServer()))
    }

    func testForceCloseDuringLookupInvalidatesApprovalAndReceipt() async {
        let store = await forceStore()
        let token = store.beginForceStop(stopServer().key)!
        await source.set(onRead: { await MainActor.run { store.endSession() } })
        _ = await store.forceStop(token)
        XCTAssertTrue(system.forceSignals.isEmpty)
        XCTAssertNil(store.lastStopReceipt)
        XCTAssertNil(store.snapshot)
    }

    func testForceSignalErrorsExitRacesAndObservationNeverRetry() async {
        for code in [EPERM, EACCES, ESRCH, EINVAL] {
            system.signalError = code
            let outcome = await stopper.forceStop(stopServer(), listeners: listeners, authorized: { true })
            if code == ESRCH { XCTAssertEqual(outcome, .alreadyExited) }
            else if code == EPERM || code == EACCES { XCTAssertEqual(outcome, .denied) }
            else { XCTAssertEqual(outcome, .failed("SIGKILL returned error \(code).")) }
        }
        XCTAssertEqual(system.forceSignals, Array(repeating: 4242, count: 4))
        system.signalError = nil
        let result = await stopper.forceStop(stopServer(), listeners: listeners, authorized: { true })
        XCTAssertEqual(result, .failed("SIGKILL was sent, but exit was not observed before the deadline. No retry was sent."))
        XCTAssertEqual(system.forceSignals.count, 5)
        system.afterSignal = { self.system.current = .unknown(.denied) }
        let unknown = await stopper.forceStop(stopServer(), listeners: listeners, authorized: { true })
        XCTAssertEqual(unknown, .failed("SIGKILL was sent, but process exit could not be verified."))
    }

    func testForceReconcilesAllPortsCardsLookupAndPreservesUnrelatedProcess() async {
        let original = stopServer().process
        let extra = ListenerSocket(family: .v4, hostKind: .loopback, host: "127.0.0.1", port: 8080, fd: 5)
        let multi = ListenerProcess(pid: original.pid, name: original.name, uid: original.uid, userName: original.userName,
                                    identity: original.identity, executablePath: original.executablePath, sockets: original.sockets + [extra])
        let other = stopServer(pid: 4243).process
        await source.set(processes: [multi, other])
        let store = await forceStore()
        let registry = CommandRegistry()
        for command in LocalServersModule(store: store).commands() { try! registry.register(command) }
        func items() -> [CommandCenterItem] {
            CommandCenterCatalog.serverItems(store, registry: registry, moduleTitle: { _ in nil })
        }
        XCTAssertEqual(items().filter { $0.moreActions.contains { $0.invocation.command == LocalServersModule.forceStopCommand } }.count, 1)
        let lookup = PortLookup(router: nil)
        lookup.update("8080", serversUnavailable: nil)
        let token = store.beginForceStop(stopServer().key)!
        system.afterSignal = { self.system.current = .unknown(.exited) }
        await source.set(onRead: { [source] in await source?.set(processes: [other]) })
        _ = await store.forceStop(token)
        XCTAssertEqual(store.servers.map(\.process.pid), [4243])
        XCTAssertEqual(items().filter { $0.kind == .server }.count, 1)
        XCTAssertFalse(items().contains { $0.moreActions.contains { $0.invocation.command == LocalServersModule.forceStopCommand } })
        let row = CommandCenterCatalog.lookupItem(lookup, store: store, refresh: registry.descriptor(for: LocalServersModule.refreshCommand))
        XCTAssertEqual(row?.title, "Nothing visible to you on port 8080")
        XCTAssertEqual(store.lastStopOutcome, .stopped)
        let queries = await source.queries
        XCTAssertEqual(queries, [.all, ListenerQuery(port: 5173)!, .all, ListenerQuery(port: 5173)!, .all])
    }

    func testForceConfirmationAndCanceledReceiptAreExplicit() {
        let text = CommandCenter.stopConfirmationText(stopServer(), force: true)
        for expected in ["fixture server", "PID: 4242", "5173", "/tmp/fixture/bin/server", "Graceful termination failed", "SIGTERM", "SIGKILL", "Unsaved data", "cleanup", "No automatic retry"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        let receipt = LocalServerStopReceipt(pid: 4242, port: 5173, outcome: .failed("SIGKILL was sent; exit observation was canceled."), force: true)
        XCTAssertEqual(CommandCenter.stopResult(.canceled, command: LocalServersModule.forceStopCommand, previousReceipt: nil, receipt: receipt), .failed(receipt.message))
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
private final class OwnedChildSignaler: ProcessSignaler, ForceProcessSignaler, @unchecked Sendable {
    let pid: pid_t
    var calls = 0
    var forceCalls = 0
    init(pid: pid_t) { self.pid = pid }
    func terminate(_ pid: pid_t) -> Int32? {
        guard pid == self.pid, pid > 1 else { XCTFail("non-fixture target"); return EPERM }
        calls += 1
        return SIGTERMProcessSignaler().terminate(pid)
    }
    func forceStop(_ pid: pid_t) -> Int32? {
        guard pid == self.pid, pid > 1 else { XCTFail("non-fixture force target"); return EPERM }
        forceCalls += 1
        return SIGKILLProcessSignaler().forceStop(pid)
    }
}

@MainActor
final class ProcessStopIntegrationTests: XCTestCase {
    func testRealOwnedChildForceStopsOnlyAfterTimeoutAndNewApproval() async throws {
        let child = try DisposableStopServer(ignoresTerm: true)
        defer { child.close() }
        let sibling = try DisposableStopServer(ignoresTerm: true)
        defer { sibling.close() }
        let signaler = OwnedChildSignaler(pid: child.process.processIdentifier)
        var policy = ProcessStopPolicy()
        policy.ownPID = pid_t.max
        let stopper = ProcessStopper(signaler: signaler, forceSignaler: signaler, policy: policy, timeout: .milliseconds(200))
        let store = LocalServerStore(stopper: stopper)
        store.activate()
        _ = await store.refresh()
        let server = try XCTUnwrap(store.servers.first { $0.process.pid == child.process.processIdentifier })
        store.confirmStop = { _ in true }
        _ = await store.stop(server.key)
        XCTAssertEqual(store.lastStopOutcome, .stillRunning)
        XCTAssertEqual(signaler.forceCalls, 0)
        XCTAssertTrue(child.process.isRunning)
        store.confirmForceStop = { confirmed in
            XCTAssertEqual(confirmed.process.identity, server.process.identity)
            XCTAssertEqual(confirmed.process.pid, child.process.processIdentifier)
            return true
        }
        let token = try XCTUnwrap(store.beginForceStop(server.key))
        _ = await store.forceStop(token)
        XCTAssertEqual(store.lastStopOutcome, .stopped)
        XCTAssertEqual(signaler.calls, 1)
        XCTAssertEqual(signaler.forceCalls, 1)
        XCTAssertFalse(store.servers.contains { $0.process.pid == child.process.processIdentifier })
        XCTAssertTrue(sibling.process.isRunning)
        XCTAssertTrue(store.servers.contains { $0.process.pid == sibling.process.processIdentifier })
        _ = await store.forceStop(token)
        XCTAssertEqual(signaler.forceCalls, 1)
    }

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
