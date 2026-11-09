import XCTest
@testable import portside

/// P2-MENU-02: search and press only what Accessibility exposes, refuse a
/// stale or unlisted item, keep denied distinct from empty, and never touch
/// the registry path for rows made from a query.
@MainActor
final class MenuBarItemsTests: XCTestCase {
    private nonisolated static func item(_ ordinal: Int = 0, bundle: String? = "com.example.app", name: String = "Example", title: String = "Example", identifier: String? = nil, canPress: Bool = true, pid: pid_t = 100) -> MenuBarItem {
        MenuBarItem(pid: pid, ownerBundleID: bundle, ownerName: name, ordinal: ordinal, identifier: identifier, title: title, canPress: canPress)
    }

    private final class Fake: MenuBarItemSource, @unchecked Sendable {
        private let lock = NSLock()
        private var snap: MenuBarSnapshot
        private var out: MenuBarPressOutcome
        private var sweepsRun = 0
        private var pressed: [MenuBarItem] = []
        var reachable = true
        init(_ snapshot: MenuBarSnapshot, press: MenuBarPressOutcome = .pressed) { snap = snapshot; out = press }
        var sweeps: Int { lock.withLock { sweepsRun } }
        var presses: [MenuBarItem] { lock.withLock { pressed } }
        func set(_ snapshot: MenuBarSnapshot) { lock.withLock { snap = snapshot } }
        func snapshot() -> MenuBarSnapshot { lock.withLock { sweepsRun += 1; return snap } }
        func press(_ item: MenuBarItem) -> MenuBarPressOutcome { lock.withLock { pressed.append(item); return out } }
        func isReachable(_ item: MenuBarItem) -> Bool { lock.withLock { reachable } }
    }

    private var reports: [String] = []

    private func service(_ source: Fake, active: Bool = true, delay: Duration = .milliseconds(10)) -> MenuBarItemsService {
        let service = MenuBarItemsService(source: source, pressDelay: delay, report: { [weak self] in self?.reports.append($0) })
        if active { service.activate() }
        return service
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(80)) }

    private func listed(_ service: MenuBarItemsService) async {
        service.refresh {}
        await settle()
    }

    // MARK: Item model

    func testIDUsesIdentifierThenOrdinalAndLowercasesBundle() {
        XCTAssertEqual(Self.item(2, bundle: "Com.Example.App").id, "com.example.app:#2")
        XCTAssertEqual(Self.item(2, identifier: "GoldenGateBar").id, "com.example.app:id=GoldenGateBar")
        XCTAssertEqual(Self.item(0, bundle: nil, pid: 7).id, "pid7:#0")
    }

    func testEmptyTitleFallsBackToOwnerName() {
        XCTAssertEqual(Self.item(title: "").displayTitle, "Example")
        XCTAssertEqual(Self.item(title: "Battery").displayTitle, "Battery")
    }

    // MARK: Service

    func testRowsListOnlyPressableItems() async {
        let source = Fake(MenuBarSnapshot(access: .ready, items: [Self.item(0), Self.item(1, canPress: false)]))
        let service = service(source)
        await listed(service)
        XCTAssertEqual(service.rows.map(\.ordinal), [0])
    }

    func testOffServiceListsNothingAndDoesNotSweep() async {
        let source = Fake(MenuBarSnapshot(access: .ready, items: [Self.item()]))
        let service = service(source, active: false)
        await listed(service)
        XCTAssertEqual(source.sweeps, 0)
        XCTAssertTrue(service.rows.isEmpty)
        XCTAssertEqual(service.unavailableReason, MenuBarItemsService.Message.off)
    }

    func testDeniedIsDistinctFromEmptyAndListsNothing() async {
        let source = Fake(.denied)
        let service = service(source)
        await listed(service)
        XCTAssertTrue(service.accessDenied)
        XCTAssertTrue(service.rows.isEmpty)
        source.set(MenuBarSnapshot(access: .ready, items: []))
        service.deactivate(); service.activate()
        await listed(service)
        XCTAssertFalse(service.accessDenied)
    }

    func testRefreshIsRateLimitedAndChangeIsReportedOnce() async {
        let source = Fake(MenuBarSnapshot(access: .ready, items: [Self.item()]))
        let service = service(source)
        var changes = 0
        let now = Date()
        service.refresh(now: now) { changes += 1 }
        await settle()
        service.refresh(now: now.addingTimeInterval(1)) { changes += 1 }
        await settle()
        XCTAssertEqual(source.sweeps, 1)
        service.refresh(now: now.addingTimeInterval(11)) { changes += 1 }
        await settle()
        XCTAssertEqual(source.sweeps, 2)
        XCTAssertEqual(changes, 1, "same list reports no change")
    }

    func testDeactivateDropsListAndLateSweepResult() async {
        let source = Fake(MenuBarSnapshot(access: .ready, items: [Self.item()]))
        let service = service(source)
        service.refresh {}
        service.deactivate()
        await settle()
        XCTAssertTrue(service.items.isEmpty)
    }

    // MARK: Press

    func testPressRunsOnlyAListedKeyAndOnlyAfterTheDelay() async {
        let item = Self.item(identifier: "x")
        let source = Fake(MenuBarSnapshot(access: .ready, items: [item]))
        let service = service(source, delay: .milliseconds(150))
        await listed(service)
        let ok = await service.press(item.id)
        if case .failure = ok { XCTFail("expected success") }
        XCTAssertTrue(source.presses.isEmpty, "the panel must be gone before the press")
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(source.presses, [item])
        let unknown = await service.press("com.other:#9")
        XCTAssertEqual(unknown, .failure(CommandFailure(reason: MenuBarItemsService.Message.gone)))
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(source.presses.count, 1)
        XCTAssertTrue(reports.isEmpty)
    }

    func testUnpressableItemIsRefusedWithoutAPress() async {
        let item = Self.item(canPress: false)
        let source = Fake(MenuBarSnapshot(access: .ready, items: [item]))
        let service = service(source)
        await listed(service)
        let result = await service.press(item.id)
        XCTAssertEqual(result, .failure(CommandFailure(reason: MenuBarItemsService.Message.unsupported)))
        await settle()
        XCTAssertTrue(source.presses.isEmpty)
    }

    func testFailedPressReportsAfterThePanelIsGone() async {
        let item = Self.item()
        let cases: [(MenuBarPressOutcome, String)] = [
            (.stale, MenuBarItemsService.Message.stale),
            (.unsupported, MenuBarItemsService.Message.unsupported),
            (.denied, MenuBarItemsService.Message.denied),
            (.hidden, MenuBarItemsService.Message.hidden),
            (.failed(-25204), "Example did not respond (Accessibility error -25204)."),
        ]
        for (outcome, reason) in cases {
            reports = []
            let source = Fake(MenuBarSnapshot(access: .ready, items: [item]), press: outcome)
            let service = service(source)
            await listed(service)
            _ = await service.press(item.id)
            await settle()
            XCTAssertEqual(reports, [reason])
        }
    }

    func testStalePressForcesNextSweep() async {
        let item = Self.item()
        let source = Fake(MenuBarSnapshot(access: .ready, items: [item]), press: .stale)
        let service = service(source)
        let now = Date()
        service.refresh(now: now) {}
        await settle()
        _ = await service.press(item.id)
        await settle()
        service.refresh(now: now.addingTimeInterval(1)) {}
        await settle()
        XCTAssertEqual(source.sweeps, 2)
    }

    func testHiddenItemIsRefusedInThePanelWithoutAPress() async {
        let item = Self.item()
        let source = Fake(MenuBarSnapshot(access: .ready, items: [item]))
        source.reachable = false
        let service = service(source)
        await listed(service)
        let result = await service.press(item.id)
        XCTAssertEqual(result, .failure(CommandFailure(reason: MenuBarItemsService.Message.hidden)))
        await settle()
        XCTAssertTrue(source.presses.isEmpty)
        XCTAssertTrue(reports.isEmpty, "the refusal is returned, not beeped")
    }

    // MARK: Catalog and module

    func testCatalogRowsRunTheRegistryCommandAndNeedAQuery() throws {
        let item = Self.item(identifier: "x")
        let rows = CommandCenterCatalog.menuBarItems([item], press: nil)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id.rawValue, "menubar:com.example.app:id=x")
        XCTAssertEqual(row.invocation.command, MenuBarModule.pressCommand)
        XCTAssertEqual(row.invocation.input, .string(item.id))
        XCTAssertTrue(row.kind.requiresQuery, "an empty query cannot open someone's menu")
        XCTAssertNotNil(row.unavailableReason, "no registered command means unavailable")
        XCTAssertNil(CommandCenterResultID(rawValue: row.id.rawValue), "never read back from history")
    }

    func testModuleDeclaresAccessibilityAndCommandRequiresIt() throws {
        let module = MenuBarModule(service: MenuBarItemsService(source: Fake(.denied)))
        XCTAssertTrue(module.dependencies.contains(.permission(.accessibility)))
        XCTAssertTrue(module.dependencies.contains(.module(CommandCenterModule.moduleID)))
        XCTAssertTrue(module.isSensitive, "held off by restricted mode")
        let descriptor = try XCTUnwrap(module.commands().first)
        XCTAssertEqual(descriptor.requiredPermissions, [.accessibility])
        XCTAssertEqual(descriptor.unavailableReason(), MenuBarItemsService.Message.off)
    }

    private struct FakeAccessibility: PermissionAdapter {
        let scope = PermissionScope.accessibility
        let granted: Bool
        func currentState() -> PermissionState { granted ? .granted : .denied }
    }

    func testModuleStartActivatesTheService() throws {
        let service = MenuBarItemsService(source: Fake(.denied))
        try MenuBarModule(service: service).start(ModuleContext())
        XCTAssertTrue(service.isActive)
    }

    func testDeniedAccessibilityNeverReachesThePress() async throws {
        let item = Self.item()
        let source = Fake(MenuBarSnapshot(access: .ready, items: [item]))
        let service = service(source)
        await listed(service)
        let gate = PermissionGate()
        gate.register(FakeAccessibility(granted: false))
        let registry = CommandRegistry(permissions: gate)
        for command in MenuBarModule(service: service).commands() { try registry.register(command) }
        let result = await registry.execute(MenuBarModule.pressCommand, input: .string(item.id))
        XCTAssertTrue(source.presses.isEmpty, "handler must not run without Accessibility")
        if case .success = result { XCTFail("expected a denial") }
        gate.register(FakeAccessibility(granted: true))
        _ = await registry.execute(MenuBarModule.pressCommand, input: .string(item.id))
        await settle()
        XCTAssertEqual(source.presses, [item])
    }
}
