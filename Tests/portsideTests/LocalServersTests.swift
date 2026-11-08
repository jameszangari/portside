import Combine
import Darwin
import XCTest
@testable import portside

/// lsof field output for hand-built listeners, one set per line like the
/// `Fixtures/lsof` files.
private func lsof(_ processes: [(pid: Int, name: String, sockets: [(type: String, name: String, fd: Int)])]) -> Data {
    var text = ""
    for process in processes {
        text += "p\(process.pid)\0c\(process.name)\0u501\0Ltester\0\n"
        for socket in process.sockets {
            text += "f\(socket.fd)\0t\(socket.type)\0PTCP\0n\(socket.name)\0TST=LISTEN\0\n"
        }
    }
    return Data(text.utf8)
}

private let node3000 = lsof([(4242, "node", [("IPv4", "*:3000", 20), ("IPv6", "*:3000", 21)])])

/// A source whose output the test changes between listings. Counts listings.
private final class SwitchableSource: ListenerSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout: Data
    private var _termination = LsofRun.Termination.exited(0)
    private var _delay: Duration?
    private var _inspector: FakeProcessInspector
    private var _listings = 0
    var cap = LsofLimits().stdoutCap

    init(_ stdout: Data, inspector: FakeProcessInspector = .owning([4242, 4243, 5001, 5002])) {
        _stdout = stdout
        _inspector = inspector
    }

    func set(_ stdout: Data? = nil, termination: LsofRun.Termination? = nil, delay: Duration?? = nil, inspector: FakeProcessInspector? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let stdout { _stdout = stdout }
        if let termination { _termination = termination }
        if let delay { _delay = delay }
        if let inspector { _inspector = inspector }
    }

    var listings: Int {
        lock.lock()
        defer { lock.unlock() }
        return _listings
    }

    func snapshot(_ query: ListenerQuery) async throws -> ListenerSnapshot {
        lock.lock()
        _listings += 1
        var limits = LsofLimits()
        limits.stdoutCap = cap
        let source = FixtureListenerSource(stdout: _stdout, termination: _termination, limits: limits, inspector: _inspector, delay: _delay)
        lock.unlock()
        return try await source.snapshot(query)
    }
}

private func socket(_ family: IPFamily, _ kind: ListenerHostKind, _ host: String, _ port: UInt16 = 8080) -> ListenerSocket {
    ListenerSocket(family: family, hostKind: kind, host: host, port: port, fd: 3)
}

/// Grouping, keys, the wildcard-to-loopback rule and the card text.
final class LocalServerModelTests: XCTestCase {
    private func snapshot(_ data: Data, inspector: FakeProcessInspector = .owning([4242, 4243, 5001, 5002])) async throws -> ListenerSnapshot {
        try await FixtureListenerSource(stdout: data, inspector: inspector).snapshot(.all)
    }

    private func fixture(_ name: String) async throws -> ListenerSnapshot {
        try await snapshot(Fixture.data("lsof/\(name)"))
    }

    func testWildcardIPv4AndIPv6IsOneServerWithTwoSocketsOpenedOnLoopback() async throws {
        let servers = LocalServer.servers(in: try await fixture("wildcard-v4-v6.f"))
        XCTAssertEqual(servers.count, 1, "grouped by process and port")
        let server = try XCTUnwrap(servers.first)
        XCTAssertEqual(server.sockets.map(\.family), [.v4, .v6], "both families kept")
        XCTAssertEqual(server.address, LocalServerAddress(host: "127.0.0.1", port: 3000, isLoopback: true), "never a LAN address")
        XCTAssertEqual(server.address?.url(.http)?.absoluteString, "http://127.0.0.1:3000/")
        XCTAssertEqual(server.address?.url(.https)?.absoluteString, "https://127.0.0.1:3000/")
        XCTAssertEqual(server.key, "3000-4242-1000.7")
        XCTAssertEqual(LocalServerText.binds(server.sockets), "all interfaces · IPv4 and IPv6")
    }

    func testIPv6OnlyUsesBracketedLoopback() async throws {
        let snapshot = try await fixture("v6-loopback.f")
        let server = try XCTUnwrap(LocalServer.servers(in: snapshot).first)
        XCTAssertEqual(server.address?.text, "[::1]:5173")
        XCTAssertEqual(server.address?.url(.http)?.absoluteString, "http://[::1]:5173/")
        let wildcard = LocalServerAddress(port: 8080, sockets: [socket(.v6, .wildcard, "*")])
        XCTAssertEqual(wildcard?.text, "[::1]:8080")
    }

    func testSpecificBindIsCopiedButNeverOpened() throws {
        let lan = try XCTUnwrap(LocalServerAddress(port: 8080, sockets: [socket(.v4, .specific, "192.168.1.20")]))
        XCTAssertEqual(lan.text, "192.168.1.20:8080")
        XCTAssertFalse(lan.isLoopback)
        XCTAssertNil(lan.url(.http))
        let v6 = try XCTUnwrap(LocalServerAddress(port: 8080, sockets: [socket(.v6, .specific, "fe80::1%en0")]))
        XCTAssertEqual(v6.text, "[fe80::1%en0]:8080")
        XCTAssertNil(v6.url(.https))
        // A loopback bind next to a specific one wins; an odd loopback stays exact.
        let mixed = LocalServerAddress(port: 8080, sockets: [socket(.v4, .specific, "10.0.0.2"), socket(.v4, .loopback, "127.0.0.2")])
        XCTAssertEqual(mixed, LocalServerAddress(host: "127.0.0.2", port: 8080, isLoopback: true))
        XCTAssertNil(LocalServerAddress(port: 8080, sockets: []))
    }

    func testSeparateListenersGetSeparateStableKeys() async throws {
        let ports = LocalServer.servers(in: try await fixture("multi-port-one-process.f"))
        XCTAssertEqual(ports.map(\.port), [5432, 8080, 9000], "one result per port")
        XCTAssertEqual(ports.first?.sockets.count, 2, "5432 keeps its IPv4 wildcard and IPv6 loopback")
        XCTAssertEqual(ports.first?.address?.text, "127.0.0.1:5432")

        // Two processes on one port (SO_REUSEPORT) are two listeners.
        let shared = lsof([(4242, "node", [("IPv4", "127.0.0.1:5173", 20)]), (4243, "node", [("IPv4", "127.0.0.1:5173", 20)])])
        let both = LocalServer.servers(in: try await snapshot(shared))
        XCTAssertEqual(both.map(\.key), ["5173-4242-1000.7", "5173-4243-1000.7"])

        let again = LocalServer.servers(in: try await snapshot(shared))
        XCTAssertEqual(again.map(\.key), both.map(\.key), "same listing, same keys")
        // A reused pid starts later: a different key, so old rows cannot act on it.
        let reused = LocalServer.servers(in: try await snapshot(shared, inspector: .owning([4242, 4243], startSeconds: 1_500)))
        XCTAssertNotEqual(reused.first?.key, both.first?.key)
    }

    func testUnknownIdentityStaysUnknownInKeyAndCard() async throws {
        let snapshot = try await snapshot(node3000, inspector: FakeProcessInspector())
        let server = try XCTUnwrap(LocalServer.servers(in: snapshot).first)
        XCTAssertEqual(server.key, "3000-4242-unknown")
        let facts = Dictionary(LocalServerText.facts(server, snapshot: snapshot).map { ($0.label, $0.value) }) { first, _ in first }
        XCTAssertEqual(facts["Identity"], "Unknown (macOS did not allow reading it)")
        XCTAssertEqual(facts["Executable"], "Unknown (macOS did not allow reading it)")
        XCTAssertNil(facts["Started"], "no start time is made up")
        XCTAssertEqual(facts["PID"], "4242")
        XCTAssertEqual(facts["Process"], "node")
    }

    func testCardSaysWhatItKnowsAndNothingElse() async throws {
        let snapshot = try await snapshot(node3000)
        let server = try XCTUnwrap(LocalServer.servers(in: snapshot).first)
        let facts = LocalServerText.facts(server, snapshot: snapshot)
        let labels = facts.map(\.label).filter { !$0.isEmpty }
        XCTAssertEqual(labels, ["Port", "Process", "PID", "Address", "Listening on", "Started", "Identity", "Owner", "Executable", "Directory", "Project", "Listed"])
        XCTAssertTrue(facts[0].value.contains("not checked"), "never claims HTTP")
        XCTAssertEqual(facts.filter { $0.value.hasPrefix("All interfaces") }.count, 2)
        XCTAssertFalse(facts.contains { ["Arguments", "Environment", "Working Directory"].contains($0.label) })
        XCTAssertEqual(LocalServerText.abbreviatingHome("/Users/me/dev/bin/node", home: "/Users/me"), "~/dev/bin/node")
        XCTAssertEqual(LocalServerText.abbreviatingHome("/Users/meadow/x", home: "/Users/me"), "/Users/meadow/x")
    }

    func testServerQueries() {
        for query in ["5173", ":5173", "localhost:5173", "127.0.0.1:8080", "port", "port node", "servers", "what's listening"] {
            XCTAssertTrue(LocalServerText.isServerQuery(CommandCenterRanker.terms(query)), query)
        }
        for query in ["", "safari", "node", "0", "70000", "loc", "portside", "1password"] {
            XCTAssertFalse(LocalServerText.isServerQuery(CommandCenterRanker.terms(query)), query)
        }
    }
}

/// The session store: on demand, newest wins, dropped on close or stop.
@MainActor
final class LocalServerStoreTests: XCTestCase {
    func testOffStoreListsNothing() async {
        let source = SwitchableSource(node3000)
        let store = LocalServerStore(service: ListenerService(source: source))
        guard case .failure(let failure) = await store.refresh() else { return XCTFail("listed while off") }
        XCTAssertEqual(failure.reason, "Local Servers is turned off.")
        XCTAssertEqual(source.listings, 0)
        XCTAssertNil(store.snapshot)
    }

    func testRefreshStoresTheListingAndTellsTheObserver() async {
        let source = SwitchableSource(node3000)
        let store = LocalServerStore(service: ListenerService(source: source))
        store.activate()
        var changes = 0
        var sawLoading = false
        store.onChange = {
            changes += 1
            if store.loading > 0 { sawLoading = LocalServerText.status(store).detail == "Looking up listening servers…" }
        }
        _ = await store.refresh()
        XCTAssertTrue(sawLoading)
        XCTAssertEqual(changes, 2, "loading, then loaded")
        XCTAssertEqual(store.servers.map(\.port), [3000])
        XCTAssertEqual(source.listings, 1)
    }

    func testClosingDropsTheListAndAnyListingInFlight() async {
        let source = SwitchableSource(node3000)
        source.set(delay: .milliseconds(200))
        let store = LocalServerStore(service: ListenerService(source: source))
        store.activate()
        let refresh = Task { await store.refresh() }
        try? await Task.sleep(for: .milliseconds(20))
        store.endSession()
        refresh.cancel()
        guard case .failure = await refresh.value else { return XCTFail("a closed session still delivered") }
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.loading, 0)
    }

    func testCanceledRefreshKeepsTheEarlierListAndSaysSo() async {
        let source = SwitchableSource(node3000)
        let store = LocalServerStore(service: ListenerService(source: source))
        store.activate()
        _ = await store.refresh()
        source.set(lsof([]), delay: .milliseconds(500))
        let refresh = Task { await store.refresh() }
        try? await Task.sleep(for: .milliseconds(20))
        refresh.cancel()
        guard case .failure(let failure) = await refresh.value else { return XCTFail("canceled refresh delivered") }
        XCTAssertEqual(failure.reason, "Refresh was canceled.")
        XCTAssertEqual(store.servers.map(\.port), [3000], "the earlier list stays")
        XCTAssertTrue(store.lastRefreshCanceled)
        XCTAssertTrue(LocalServerText.status(store).detail.hasPrefix("Refresh canceled. 1 server visible to you"))
    }

    func testStatusForEmptyPartialTimedOutAndFailed() async {
        let source = SwitchableSource(lsof([]))
        let store = LocalServerStore(service: ListenerService(source: source))
        XCTAssertEqual(LocalServerText.status(store).detail, "Lists TCP servers your account runs.", "off")
        store.activate()
        XCTAssertEqual(LocalServerText.status(store).detail, "Return to list servers your account runs, or search a port.")

        _ = await store.refresh()
        let empty = LocalServerText.status(store).detail
        XCTAssertTrue(empty.hasPrefix("No listening servers visible to you"), empty)
        XCTAssertTrue(empty.contains("Other users' and system servers are not shown."), "empty never means free")

        source.set(node3000 + lsof([(5001, "ruby", [("IPv4", "127.0.0.1:4000", 3)])]))
        source.cap = node3000.count + 10
        _ = await store.refresh()
        XCTAssertEqual(LocalServerText.status(store).detail, "1 server shown, but some may be missing: the listing was cut short.")
        XCTAssertEqual(store.servers.map(\.port), [3000], "what was read is still shown")
        source.cap = LsofLimits().stdoutCap

        source.set(termination: .timedOut)
        _ = await store.refresh()
        XCTAssertEqual(LocalServerText.status(store).detail, "Listing servers took too long and was stopped. Refresh to try again.")
        XCTAssertTrue(store.servers.isEmpty, "a timed-out listing keeps nothing")

        source.set(termination: .launchFailed("/usr/sbin/lsof does not exist."))
        _ = await store.refresh()
        XCTAssertEqual(LocalServerText.status(store).detail, "Could not run lsof. /usr/sbin/lsof does not exist.")
        XCTAssertNotEqual(LocalServerText.status(store).detail, empty, "a failure is not an empty list")
    }

    func testDeniedIdentityIsAPartialCardNotAFailure() async {
        let source = SwitchableSource(node3000, inspector: FakeProcessInspector())
        let store = LocalServerStore(service: ListenerService(source: source))
        store.activate()
        guard case .success(let snapshot) = await store.refresh() else { return XCTFail("denied identity failed the listing") }
        XCTAssertEqual(snapshot.outcome, .complete)
        XCTAssertEqual(store.servers.first?.process.hasVerifiedIdentity, false)
    }
}

/// The module through the module and command registries, and its rows.
@MainActor
final class LocalServersModuleTests: XCTestCase {
    private var copied: [String] = []
    private var opened: [URL] = []
    private var source = SwitchableSource(node3000)
    private lazy var store = LocalServerStore(service: ListenerService(source: source))
    private lazy var commands = CommandRegistry(permissions: PermissionGate())
    private lazy var modules = ModuleRegistry(commands: commands, permissions: PermissionGate())
    private var center: CommandCenter?

    private func install(enabled: Bool = true) throws {
        let center = CommandCenter(commands: commands, moduleTitle: { _ in nil }, registrar: { _, _ in NSObject() }, report: { _ in })
        self.center = center
        try modules.register(CommandCenterModule(center: center, chords: Just(nil).eraseToAnyPublisher()))
        try modules.register(LocalServersModule(store: store, actions: LocalServerActions(
            copy: { [unowned self] in copied.append($0) },
            openURL: { [unowned self] in opened.append($0); return true }
        )))
        modules.enable(CommandCenterModule.moduleID)
        if enabled { modules.enable(LocalServersModule.moduleID) }
    }

    private func items() -> [CommandCenterItem] {
        CommandCenterCatalog.items(registry: commands, moduleTitle: { _ in "Local Servers" }, sources: CommandCenterSources(servers: store))
    }

    private var statusID: CommandCenterResultID { .command(LocalServersModule.refreshCommand) }

    func testOffByDefaultSensitiveAndDependsOnCommandCenter() throws {
        try install(enabled: false)
        let module = try XCTUnwrap(modules.modules.first { $0.id == LocalServersModule.moduleID })
        XCTAssertTrue(module.isSensitive)
        XCTAssertEqual(module.dependencies, [.module(CommandCenterModule.moduleID)])
        var saved = ModuleSettings()
        saved.setEnabled(true, for: LocalServersModule.moduleID)
        modules.enableSaved(saved, restricted: true)
        XCTAssertEqual(modules.state(of: LocalServersModule.moduleID), .disabled, "the restricted preset holds it off")
        modules.disable(CommandCenterModule.moduleID)
        modules.enable(LocalServersModule.moduleID)
        XCTAssertEqual(modules.state(of: LocalServersModule.moduleID), .waiting("Command Center is not running."))
    }

    func testOffModuleListsNothingAndItsRowSaysWhy() async throws {
        try install(enabled: false)
        let result = await commands.execute(LocalServersModule.refreshCommand)
        XCTAssertEqual(result, .unavailable("Local Servers is turned off."))
        XCTAssertEqual(source.listings, 0)
        let rows = items().filter { $0.subtitle == "Local Servers" }
        XCTAssertEqual(rows.map(\.id), [statusID], "status row only, no server rows")
        XCTAssertEqual(rows.first?.unavailableReason, "Local Servers is turned off.")
        XCTAssertFalse(CommandCenter.shouldListServers("5173", store: store, alreadyRequested: false), "a server query lists nothing while off")
    }

    func testListingIsOnDemandOncePerSession() async throws {
        try install()
        XCTAssertFalse(CommandCenter.shouldListServers("safari", store: store, alreadyRequested: false))
        XCTAssertTrue(CommandCenter.shouldListServers("5173", store: store, alreadyRequested: false))
        XCTAssertFalse(CommandCenter.shouldListServers("5173", store: store, alreadyRequested: true), "once per session")
        _ = await commands.execute(LocalServersModule.refreshCommand)
        XCTAssertFalse(CommandCenter.shouldListServers("port", store: store, alreadyRequested: false), "a list exists: Refresh only")
        XCTAssertEqual(source.listings, 1)
        store.endSession()
        XCTAssertTrue(CommandCenter.shouldListServers("port", store: store, alreadyRequested: false), "a new session lists again")
    }

    func testRowsActionsAndCommandsGoThroughTheRegistry() async throws {
        try install()
        let result = await commands.execute(LocalServersModule.refreshCommand)
        XCTAssertEqual(result, .success("1 server visible to you."))
        let rows = items()
        let server = try XCTUnwrap(rows.first { $0.kind == .server })
        XCTAssertEqual(server.id, .server("3000-4242-1000.7"))
        XCTAssertEqual(server.title, "Port 3000 · node")
        XCTAssertEqual(server.detail, "PID 4242 · all interfaces · IPv4 and IPv6")
        XCTAssertEqual(server.invocation, CommandInvocation(command: LocalServersModule.copyAddressCommand, input: .string("3000-4242-1000.7")),
                       "Return copies; it never opens an unverified service")
        XCTAssertEqual(server.primaryTitle, "Copy 127.0.0.1:3000")
        XCTAssertEqual(server.moreActions.map(\.title), ["Copy Port 3000", "Open http://127.0.0.1:3000", "Open https://127.0.0.1:3000", "Stop Server…", "Refresh Servers"])
        XCTAssertEqual(rows.first { $0.id == statusID }?.primaryTitle, "Refresh Servers")

        for action in [server.invocation] + server.moreActions.map(\.invocation) where action.command != LocalServersModule.refreshCommand && action.command != LocalServersModule.stopCommand {
            let outcome = await commands.execute(action.command, input: action.input)
            guard case .success = outcome else { return XCTFail("\(action.command) failed: \(outcome)") }
        }
        XCTAssertEqual(copied, ["127.0.0.1:3000", "3000"])
        XCTAssertEqual(opened.map(\.absoluteString), ["http://127.0.0.1:3000/", "https://127.0.0.1:3000/"])
    }

    func testStaleAndUnknownServersAreRefused() async throws {
        try install()
        let key = CommandInput.string("3000-4242-1000.7")
        let before = await commands.execute(LocalServersModule.copyAddressCommand, input: key)
        XCTAssertEqual(before, .failed("List servers first."))
        _ = await commands.execute(LocalServersModule.refreshCommand)
        source.set(lsof([]))
        _ = await commands.execute(LocalServersModule.refreshCommand)
        XCTAssertFalse(items().contains { $0.kind == .server }, "the stopped server's row is gone")
        for command in [LocalServersModule.copyAddressCommand, LocalServersModule.copyPortCommand, LocalServersModule.openHTTPCommand] {
            let outcome = await commands.execute(command, input: key)
            XCTAssertEqual(outcome, .failed("That server is no longer listed. Refresh to check again."))
        }
        XCTAssertTrue(copied.isEmpty)
        XCTAssertTrue(opened.isEmpty)
        let tooLong = await commands.execute(LocalServersModule.openHTTPCommand, input: .string(String(repeating: "9", count: 65)))
        guard case .invalidInput = tooLong else { return XCTFail("unbounded input accepted") }
    }

    func testNonLoopbackServerHasNoOpenAndOpenIsRefused() async throws {
        source.set(lsof([(4242, "nginx", [("IPv4", "192.168.1.20:8080", 3)])]))
        try install()
        _ = await commands.execute(LocalServersModule.refreshCommand)
        let server = try XCTUnwrap(items().first { $0.kind == .server })
        XCTAssertEqual(server.moreActions.map(\.title), ["Copy Port 8080", "Stop Server…", "Refresh Servers"])
        let outcome = await commands.execute(LocalServersModule.openHTTPCommand, input: .string(LocalServer.servers(in: store.snapshot!)[0].key))
        XCTAssertEqual(outcome, .failed("Port 8080 is not on a loopback address, so Portside does not open it."))
        XCTAssertTrue(opened.isEmpty)
    }

    func testMultipleListenersAreSeparateRows() async throws {
        source.set(lsof([
            (4242, "node", [("IPv4", "127.0.0.1:5173", 20)]),
            (4243, "node", [("IPv4", "127.0.0.1:5173", 20), ("IPv6", "[::1]:24678", 21)]),
        ]))
        try install()
        _ = await commands.execute(LocalServersModule.refreshCommand)
        let rows = items().filter { $0.kind == .server }
        XCTAssertEqual(rows.map(\.id.rawValue), ["server:5173-4242-1000.7", "server:5173-4243-1000.7", "server:24678-4243-1000.7"],
                       "by port, then pid")
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        let ranked = CommandCenterRanker.rank(items(), query: "5173")!
        XCTAssertEqual(Array(ranked.prefix(3)), [.server("5173-4242-1000.7"), .server("5173-4243-1000.7"), statusID],
                       "matching servers, then the status row")
        let byName = CommandCenterRanker.rank(items(), query: "port node")!
        XCTAssertEqual(Set(byName.prefix(3)), Set(rows.map(\.id)))
    }

    func testDisablingDropsTheListAndCancelsAListing() async throws {
        try install()
        _ = await commands.execute(LocalServersModule.refreshCommand)
        source.set(delay: .milliseconds(500))
        let refresh = Task { await commands.execute(LocalServersModule.refreshCommand) }
        try await Task.sleep(for: .milliseconds(20))
        modules.disable(LocalServersModule.moduleID)
        let outcome = await refresh.value
        guard case .failed = outcome else { return XCTFail("a stopped module still delivered: \(outcome)") }
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(modules.resourceCount(of: LocalServersModule.moduleID), 0)
        XCTAssertFalse(items().contains { $0.kind == .server })
    }

    // MARK: Live lsof against listeners this test owns

    func testLiveListingFindsOwnedListenersAndForgetsClosedOnes() async throws {
        let store = LocalServerStore()
        let module = LocalServersModule(store: store, actions: LocalServerActions(copy: { [unowned self] in copied.append($0) }, openURL: { _ in false }))
        let center = CommandCenter(commands: commands, moduleTitle: { _ in nil }, registrar: { _, _ in NSObject() }, report: { _ in })
        self.center = center
        try modules.register(CommandCenterModule(center: center, chords: Just(nil).eraseToAnyPublisher()))
        try modules.register(module)
        modules.enable(CommandCenterModule.moduleID)
        modules.enable(LocalServersModule.moduleID)

        let first = try OwnedListeners([(AF_INET, "127.0.0.1"), (AF_INET6, "::")])
        let second = try OwnedListeners([(AF_INET6, "::1")])
        _ = await commands.execute(LocalServersModule.refreshCommand)
        let mine = store.servers.filter { $0.process.pid == getpid() }
        XCTAssertEqual(Set(mine.map(\.port)), [first.port, second.port], "two owned listeners, two results")
        let a = try XCTUnwrap(mine.first { $0.port == first.port })
        XCTAssertEqual(a.sockets.count, 2)
        XCTAssertEqual(a.address?.text, "127.0.0.1:\(first.port)")
        XCTAssertTrue(a.process.hasVerifiedIdentity)
        XCTAssertFalse(a.key.hasSuffix("unknown"))
        XCTAssertEqual(mine.first { $0.port == second.port }?.address?.text, "[::1]:\(second.port)")

        _ = await commands.execute(LocalServersModule.copyPortCommand, input: .string(a.key))
        XCTAssertEqual(copied, [String(first.port)])
        first.close()
        _ = await commands.execute(LocalServersModule.refreshCommand)
        XCTAssertNil(store.server(a.key), "a closed listener is gone after Refresh")
        let stale = await commands.execute(LocalServersModule.copyAddressCommand, input: .string(a.key))
        XCTAssertEqual(stale, .failed("That server is no longer listed. Refresh to check again."))
        second.close()
    }
}

/// Command Center state for server rows: extra actions and a refresh that stays open.
final class LocalServerStateTests: XCTestCase {
    private var status: CommandCenterItem {
        var item = CommandCenterItem(
            id: .command(LocalServersModule.refreshCommand), kind: .command, title: "Local Servers",
            invocation: CommandInvocation(command: LocalServersModule.refreshCommand, staysOpen: true),
            primaryTitle: "List Servers", copyValue: "localServers.refresh", copyTitle: "Copy Command ID"
        )
        item.matchesServerQueries = true
        return item
    }

    private var server: CommandCenterItem {
        var item = CommandCenterItem(
            id: .server("3000-4242-1000.7"), kind: .server, title: "Port 3000 · node", keywords: ["node", "port"],
            invocation: CommandInvocation(command: LocalServersModule.copyAddressCommand, input: .string("3000-4242-1000.7")),
            primaryTitle: "Copy 127.0.0.1:3000", copyValue: "127.0.0.1:3000", copyTitle: "Copy Address"
        )
        item.moreActions = [
            CommandCenterItemAction(title: "Open http://127.0.0.1:3000", symbolName: "safari",
                                    invocation: CommandInvocation(command: LocalServersModule.openHTTPCommand, input: .string("3000-4242-1000.7"))),
            CommandCenterItemAction(title: "Refresh Servers", symbolName: "arrow.clockwise",
                                    invocation: CommandInvocation(command: LocalServersModule.refreshCommand, staysOpen: true)),
        ]
        return item
    }

    func testRefreshSuccessStaysOpenWithANotice() {
        var state = CommandCenterState()
        _ = state.send(.open([status]))
        XCTAssertEqual(state.send(.key(.return)).effects, [.run(status.id)])
        let done = state.send(.finished(status.id, .success("2 servers visible to you.")))
        XCTAssertTrue(state.isVisible, "a refresh never closes the panel")
        XCTAssertEqual(state.notice, CommandCenterNotice(kind: .succeeded, message: "2 servers visible to you."))
        XCTAssertEqual(done.effects, [.recordUsage(status.id), .announce("2 servers visible to you.")])
    }

    func testServerActionsRunTheirOwnCommandAndSkipHistory() {
        var state = CommandCenterState()
        _ = state.send(.open([server, status]))
        _ = state.send(.key(.down))
        XCTAssertEqual(state.selection, server.id, "after Local Servers, by title")
        _ = state.send(.key(.commandK))
        XCTAssertEqual(state.visibleActions.map(\.kind), [.run, .showDetails, .more(0), .more(1)], "no direct pasteboard copy")
        XCTAssertEqual(state.visibleActions.first?.title, "Copy 127.0.0.1:3000")
        XCTAssertEqual(state.send(.performAction(.more(0))).effects, [.runAction(server.id, 0)])
        XCTAssertEqual(state.mode, .running)
        let opened = state.send(.finished(server.id, .success(nil)))
        XCTAssertEqual(opened.effects, [.dismiss(restoreFocus: false)], "server rows are never written to history")

        _ = state.send(.open([server, status]))
        _ = state.send(.key(.down))
        _ = state.send(.key(.commandK))
        XCTAssertEqual(state.send(.performAction(.more(1))).effects, [.runAction(server.id, 1)])
        _ = state.send(.finished(server.id, .success("1 server visible to you.")))
        XCTAssertTrue(state.isVisible, "Refresh from a server row stays open")
    }

    func testArrivingServersTakeTheSelectionFromTheStatusRow() {
        var state = CommandCenterState()
        _ = state.send(.open([status]))
        for case .search(let request) in state.send(.query("3000")).effects {
            _ = state.send(.results(request, CommandCenterRanker.rank(state.items, query: request.query)!))
        }
        XCTAssertEqual(state.selection, status.id, "only the status row while listing")
        for case .search(let request) in state.send(.catalog([status, server])).effects {
            _ = state.send(.results(request, CommandCenterRanker.rank(state.items, query: request.query)!))
        }
        XCTAssertEqual(state.results.map(\.id), [server.id, status.id])
        XCTAssertEqual(state.selection, server.id)
        _ = state.send(.key(.down))
        for case .search(let request) in state.send(.catalog([status, server])).effects {
            _ = state.send(.results(request, CommandCenterRanker.rank(state.items, query: request.query)!))
        }
        XCTAssertEqual(state.selection, status.id, "a row the person picked stays picked")
    }

    func testStatusRowAnswersEveryServerQuery() {
        let items = [server, status]
        XCTAssertEqual(CommandCenterRanker.rank(items, query: "3000"), [server.id, status.id])
        XCTAssertEqual(CommandCenterRanker.rank(items, query: "8080"), [status.id], "no match still shows the state")
        XCTAssertEqual(CommandCenterRanker.rank(items, query: "localhost:8080"), [status.id])
        XCTAssertEqual(CommandCenterRanker.rank(items, query: "safari"), [])
    }
}
