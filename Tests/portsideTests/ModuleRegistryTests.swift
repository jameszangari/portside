import XCTest
@testable import portside

/// Stand-in for an OS event feed: counts live subscriptions.
@MainActor
private final class EventSource {
    private var handlers: [Int: () -> Void] = [:]
    private var next = 0
    var subscribers: Int { handlers.count }

    func subscribe(_ handler: @escaping () -> Void) -> Int {
        next += 1
        handlers[next] = handler
        return next
    }

    func unsubscribe(_ token: Int) { handlers[token] = nil }
    func emit() { handlers.values.forEach { $0() } }
}

private struct StartFailure: LocalizedError {
    var errorDescription: String? { "fixture refused" }
}

/// Fixture 1: subscribes to events, runs one long task, provides one command
/// whose handler waits until released.
@MainActor
private final class FeedModule: PortsideModule {
    let id: ModuleID
    let title: String
    let dependencies: [ModuleDependency]
    let source: EventSource
    var starts = 0
    var stops = 0
    var events = 0
    var failNextStart = false
    var longTaskCanceled = false
    var handlerGate: CheckedContinuation<Void, Never>?

    init(_ raw: String, source: EventSource, dependencies: [ModuleDependency] = []) {
        id = ModuleID(raw)!
        title = raw.capitalized
        self.source = source
        self.dependencies = dependencies
    }

    func commands() -> [CommandDescriptor] {
        [
            CommandDescriptor(id: CommandID("\(id).ping")!, title: "Ping") { _ in .success("pong") },
            CommandDescriptor(id: CommandID("\(id).slow")!, title: "Slow") { [weak self] _ in
                await withCheckedContinuation { self?.handlerGate = $0 }
                return .success("late")
            },
        ]
    }

    func start(_ context: ModuleContext) throws {
        starts += 1
        let token = source.subscribe { [weak self] in self?.events += 1 }
        context.onStop { [source] in source.unsubscribe(token) }
        context.task { [weak self] in
            while !Task.isCancelled { await Task.yield() }
            self?.longTaskCanceled = true
        }
        if failNextStart {
            failNextStart = false
            throw StartFailure()
        }
    }

    func stop() { stops += 1 }
}

/// Fixture 2: no resources or commands; records the order it stops in.
@MainActor
private final class LeafModule: PortsideModule {
    let id: ModuleID
    let title = "Leaf"
    let dependencies: [ModuleDependency]
    var log: (String) -> Void = { _ in }
    var starts = 0

    init(_ raw: String, dependencies: [ModuleDependency]) {
        id = ModuleID(raw)!
        self.dependencies = dependencies
    }

    func start(_ context: ModuleContext) throws { starts += 1 }
    func stop() { log("stop \(id)") }
}

@MainActor
final class ModuleRegistryTests: XCTestCase {
    private var gate: PermissionGate!
    private var commands: CommandRegistry!
    private var registry: ModuleRegistry!
    private var source: EventSource!
    private var grant = PermissionState.granted

    override func setUp() async throws {
        gate = PermissionGate()
        gate.register(AppPermissionAdapter(name: "files", state: { [unowned self] in self.grant }))
        commands = CommandRegistry(permissions: gate)
        registry = ModuleRegistry(commands: commands, permissions: gate)
        source = EventSource()
    }

    private func cmd(_ raw: String) -> CommandID { CommandID(raw)! }

    /// Lets enqueued main-actor tasks run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testModuleIDRules() {
        XCTAssertNotNil(ModuleID("feed"))
        for bad in ["", "Feed", "a.b", "1a", "a b"] { XCTAssertNil(ModuleID(bad), bad) }
    }

    func testRegisteringStartsNothing() throws {
        let feed = FeedModule("feed", source: source)
        try registry.register(feed)
        XCTAssertEqual(registry.state(of: feed.id), .disabled)
        XCTAssertEqual(feed.starts, 0)
        XCTAssertEqual(source.subscribers, 0)
        XCTAssertEqual(commands.descriptors.map(\.id.rawValue), ["feed.ping", "feed.slow"])
    }

    func testRepeatedEnableDisableLeavesOneSubscriptionThenZero() async throws {
        let feed = FeedModule("feed", source: source)
        try registry.register(feed)
        for _ in 0..<3 {
            registry.enable(feed.id)
            registry.enable(feed.id)
            XCTAssertEqual(registry.state(of: feed.id), .running)
            XCTAssertEqual(source.subscribers, 1)
            XCTAssertEqual(registry.resourceCount(of: feed.id), 2)
            source.emit()
            registry.disable(feed.id)
            registry.disable(feed.id)
            XCTAssertEqual(source.subscribers, 0)
            XCTAssertEqual(registry.resourceCount(of: feed.id), 0)
            source.emit()
        }
        XCTAssertEqual(feed.starts, 3)
        XCTAssertEqual(feed.stops, 3)
        XCTAssertEqual(feed.events, 3)
        await settle()
        XCTAssertTrue(feed.longTaskCanceled)
    }

    func testDisabledModuleCommandsCannotRun() async throws {
        let feed = FeedModule("feed", source: source)
        try registry.register(feed)
        let off = await commands.execute(cmd("feed.ping"))
        XCTAssertEqual(off, .unavailable("Feed is turned off."))
        registry.enable(feed.id)
        let on = await commands.execute(cmd("feed.ping"))
        XCTAssertEqual(on, .success("pong"))
        registry.disable(feed.id)
        let again = await commands.execute(cmd("feed.ping"))
        XCTAssertEqual(again, .unavailable("Feed is turned off."))
    }

    func testDisablingCancelsInFlightCommand() async throws {
        let feed = FeedModule("feed", source: source)
        try registry.register(feed)
        registry.enable(feed.id)
        let pending = Task { await self.commands.execute(self.cmd("feed.slow")) }
        await settle()
        XCTAssertNotNil(feed.handlerGate)
        XCTAssertEqual(registry.resourceCount(of: feed.id), 3)
        registry.disable(feed.id)
        feed.handlerGate?.resume()
        let result = await pending.value
        XCTAssertEqual(result, .failed("Feed stopped before the command finished."))
        XCTAssertEqual(registry.resourceCount(of: feed.id), 0)
    }

    func testCallerCancelReachesHandlerAndModuleKeepsRunning() async throws {
        let feed = FeedModule("feed", source: source)
        try registry.register(feed)
        registry.enable(feed.id)
        let pending = Task { await self.commands.execute(self.cmd("feed.slow")) }
        await settle()
        pending.cancel()
        feed.handlerGate?.resume()
        let result = await pending.value
        XCTAssertEqual(result, .canceled)
        await settle()
        XCTAssertEqual(registry.state(of: feed.id), .running)
        XCTAssertEqual(registry.resourceCount(of: feed.id), 2)
    }

    func testFailedStartReleasesResourcesAndIsIsolated() async throws {
        let healthy = FeedModule("healthy", source: source)
        let broken = FeedModule("broken", source: source)
        broken.failNextStart = true
        try registry.register(healthy)
        try registry.register(broken)
        registry.enable(healthy.id)
        registry.enable(broken.id)

        XCTAssertEqual(registry.state(of: broken.id), .failed("Broken could not start: fixture refused"))
        XCTAssertEqual(registry.state(of: healthy.id), .running)
        XCTAssertEqual(source.subscribers, 1)
        XCTAssertEqual(broken.stops, 0)
        let blocked = await commands.execute(cmd("broken.ping"))
        XCTAssertEqual(blocked, .unavailable("Broken could not start: fixture refused"))
        let fine = await commands.execute(cmd("healthy.ping"))
        XCTAssertEqual(fine, .success("pong"))

        // Failed stays failed; enabling again is a no-op until disabled.
        registry.enable(broken.id)
        XCTAssertEqual(broken.starts, 1)
        registry.disable(broken.id)
        XCTAssertEqual(registry.state(of: broken.id), .disabled)
        registry.enable(broken.id)
        XCTAssertEqual(registry.state(of: broken.id), .running)
        XCTAssertEqual(source.subscribers, 2)
        await settle()
        XCTAssertTrue(broken.longTaskCanceled)
    }

    func testPermissionDependencyWaitsAndRefreshStartsAndStops() throws {
        grant = .notRequested
        let feed = FeedModule("feed", source: source, dependencies: [.permission(.app("files"))])
        try registry.register(feed)
        registry.enable(feed.id)
        XCTAssertEqual(registry.state(of: feed.id), .waiting("files permission has not been requested yet."))
        XCTAssertEqual(feed.starts, 0)

        grant = .granted
        XCTAssertEqual(registry.state(of: feed.id), .waiting("files permission has not been requested yet."))
        registry.refresh()
        XCTAssertEqual(registry.state(of: feed.id), .running)

        grant = .denied
        registry.refresh()
        XCTAssertEqual(registry.state(of: feed.id), .waiting("files permission is denied or was revoked."))
        XCTAssertEqual(source.subscribers, 0)
        XCTAssertEqual(feed.stops, 1)
        XCTAssertTrue(registry.isEnabled(feed.id))
    }

    func testModuleDependencyStartsAfterAndStopsBefore() throws {
        var log: [String] = []
        let leaf = LeafModule("leaf", dependencies: [.module(ModuleID("feed")!)])
        leaf.log = { log.append($0) }
        let feed = FeedModule("feed", source: source)
        // Dependent registered first: start order must still follow the dependency.
        try registry.register(leaf)
        try registry.register(feed)

        registry.enable(leaf.id)
        XCTAssertEqual(registry.state(of: leaf.id), .waiting("Feed is not running."))
        registry.enable(feed.id)
        XCTAssertEqual(registry.state(of: leaf.id), .running)

        registry.disable(feed.id)
        XCTAssertEqual(registry.state(of: leaf.id), .waiting("Feed is not running."))
        XCTAssertEqual(log, ["stop leaf"])
        XCTAssertEqual(feed.stops, 1)

        registry.enable(feed.id)
        XCTAssertEqual(registry.state(of: leaf.id), .running)
        XCTAssertEqual(leaf.starts, 2)
    }

    func testMissingAndCyclicDependenciesWait() throws {
        let orphan = LeafModule("orphan", dependencies: [.module(ModuleID("ghost")!)])
        let a = LeafModule("a", dependencies: [.module(ModuleID("b")!)])
        let b = LeafModule("b", dependencies: [.module(ModuleID("a")!)])
        for module in [orphan, a, b] { try registry.register(module); registry.enable(module.id) }
        XCTAssertEqual(registry.state(of: orphan.id), .waiting("ghost is not installed."))
        XCTAssertEqual(registry.state(of: a.id), .waiting("Leaf is not running."))
        XCTAssertEqual(registry.state(of: b.id), .waiting("Leaf is not running."))
        XCTAssertEqual(a.starts + b.starts + orphan.starts, 0)
    }

    func testRegistrationRejectsDuplicatesAndForeignCommandsAtomically() throws {
        try registry.register(FeedModule("feed", source: source))
        XCTAssertThrowsError(try registry.register(FeedModule("feed", source: source))) {
            XCTAssertEqual($0 as? ModuleRegistryError, .duplicateModule(ModuleID("feed")!))
        }
        try commands.register(CommandDescriptor(id: cmd("other.ping"), title: "Taken") { _ in .success(nil) })
        XCTAssertThrowsError(try registry.register(FeedModule("other", source: source))) {
            XCTAssertEqual($0 as? ModuleRegistryError, .duplicateCommand(cmd("other.ping")))
        }
        XCTAssertNil(registry.state(of: ModuleID("other")!))
        XCTAssertNil(commands.descriptor(for: cmd("other.slow")))
    }

    func testStopAllReleasesEverything() async throws {
        let feed = FeedModule("feed", source: source)
        let leaf = LeafModule("leaf", dependencies: [.module(feed.id)])
        try registry.register(feed)
        try registry.register(leaf)
        registry.enable(feed.id)
        registry.enable(leaf.id)
        registry.stopAll()
        XCTAssertNotEqual(registry.state(of: feed.id), .running)
        XCTAssertNotEqual(registry.state(of: leaf.id), .running)
        XCTAssertEqual(source.subscribers, 0)
        XCTAssertEqual(feed.stops, 1)
        await settle()
        XCTAssertTrue(feed.longTaskCanceled)
    }

    func testCoreModuleProvidesOpenSettings() async throws {
        var starting = true
        var opened = 0
        let core = PortsideCoreModule(isStarting: { starting }, openSettings: { opened += 1 })
        try registry.register(core)
        let off = await commands.execute(PortsideCoreModule.openSettingsCommand)
        XCTAssertEqual(off, .unavailable("Portside is turned off."))
        registry.enable(core.id)
        let early = await commands.execute(PortsideCoreModule.openSettingsCommand)
        XCTAssertEqual(early, .unavailable("Portside is still starting."))
        starting = false
        let ok = await commands.execute(PortsideCoreModule.openSettingsCommand)
        XCTAssertEqual(ok, .success(nil))
        XCTAssertEqual(opened, 1)
    }
}
