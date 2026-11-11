import XCTest
@testable import portside

/// P2-MENU-04: only validated items move, each move is re-checked before and
/// after, the original order is saved once and restored, and nothing moves
/// when the module is off or Accessibility is gone.
@MainActor
final class MenuBarReorderTests: XCTestCase {
    private nonisolated static func item(_ name: String, bundle: String? = nil, canPress: Bool = true) -> MenuBarItem {
        MenuBarItem(pid: 1, ownerBundleID: bundle ?? "com.example.\(name)", ownerName: name, ordinal: 0, identifier: nil, title: name, canPress: canPress)
    }

    private nonisolated static func slot(_ item: MenuBarItem, at index: Int, reachable: Bool = true) -> MenuBarSlot {
        MenuBarSlot(item: item, minX: Double(index * 30), maxX: Double(index * 30 + 24), midY: 10, reachable: reachable)
    }

    /// Items laid out left to right. `drag` rearranges them like the menu bar
    /// does unless `works` is false.
    private final class Fake: MenuBarMover, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [MenuBarItem]
        private var hidden: Set<String> = []
        private var denied = false
        private var works = true
        private var drags = 0
        init(_ items: [MenuBarItem]) { self.items = items }
        var order: [String] { lock.withLock { items.map(\.id) } }
        var dragCount: Int { lock.withLock { drags } }
        func set(works: Bool? = nil, denied: Bool? = nil, hidden: Set<String>? = nil) {
            lock.withLock {
                if let works { self.works = works }
                if let denied { self.denied = denied }
                if let hidden { self.hidden = hidden }
            }
        }
        func shuffle(_ ids: [String]) { lock.withLock { items = ids.compactMap { id in items.first { $0.id == id } } } }
        func remove(_ id: String) { lock.withLock { items.removeAll { $0.id == id } } }
        func slots() -> [MenuBarSlot]? {
            lock.withLock {
                denied ? nil : items.enumerated().map { MenuBarReorderTests.slot($1, at: $0, reachable: !hidden.contains($1.id)) }
            }
        }
        func drag(_ slot: MenuBarSlot, onto target: MenuBarSlot, side: MenuBarDropSide) -> Bool {
            lock.withLock {
                drags += 1
                guard works, let from = items.firstIndex(where: { $0.id == slot.id }) else { return true }
                let moved = items.remove(at: from)
                guard let to = items.firstIndex(where: { $0.id == target.id }) else { return true }
                items.insert(moved, at: side == .before ? to : to + 1)
                return true
            }
        }
    }

    private let a = item("A"), b = item("B"), c = item("C")
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "portside.reorder.\(UUID().uuidString)")
    }

    private func make(_ fake: Fake, active: Bool = true, os: Int = 27) -> MenuBarReorderService {
        let service = MenuBarReorderService(mover: fake, defaults: defaults, settle: .milliseconds(1), osMajor: os)
        if active { service.activate() }
        return service
    }

    // MARK: Rules

    func testSupportReasons() {
        let ok = Self.slot(a, at: 0)
        XCTAssertEqual(MenuBarLayoutRules.support(for: ok, osMajor: 27), .movable)
        XCTAssertTrue(MenuBarLayoutRules.support(for: Self.slot(Self.item("N", canPress: false), at: 0), osMajor: 26).isMovable)
        XCTAssertFalse(MenuBarLayoutRules.support(for: ok, osMajor: 25).isMovable)
        XCTAssertFalse(MenuBarLayoutRules.support(for: Self.slot(Self.item("S", bundle: "com.apple.controlcenter"), at: 0), osMajor: 27).isMovable)
        XCTAssertFalse(MenuBarLayoutRules.support(for: Self.slot(a, at: 0, reachable: false), osMajor: 27).isMovable)
        XCTAssertFalse(MenuBarLayoutRules.support(for: Self.slot(Self.item("N", canPress: false), at: 0), osMajor: 27).isMovable)
        XCTAssertFalse(MenuBarLayoutRules.support(for: ok, osMajor: 27, failed: [a.id]).isMovable)
        let noBundle = MenuBarItem(pid: 1, ownerBundleID: nil, ownerName: "X", ordinal: 0, identifier: nil, title: "X", canPress: true)
        XCTAssertFalse(MenuBarLayoutRules.support(for: Self.slot(noBundle, at: 0), osMajor: 27).isMovable)
    }

    func testPlanReachesDesiredOrderWithinBound() {
        let current = ["a", "b", "c", "d"]
        for desired in [["d", "c", "b", "a"], ["b", "a", "c", "d"], ["c", "a"], ["x", "d", "a"]] {
            var order = current
            let steps = MenuBarLayoutRules.plan(current: current, desired: desired)
            XCTAssertLessThan(steps.count, current.count)
            for step in steps {
                order.removeAll { $0 == step.id }
                order.insert(step.id, at: order.firstIndex(of: step.before)!)
            }
            let known = desired.filter(current.contains)
            XCTAssertEqual(order.filter(known.contains), known)
        }
        XCTAssertTrue(MenuBarLayoutRules.plan(current: ["a", "b"], desired: ["a", "b"]).isEmpty)
    }

    // MARK: Moves

    func testMoveRightSwapsAndSavesBaselineOnce() async {
        let fake = Fake([a, b, c]); let service = make(fake)
        await service.refresh()
        let result = await service.move(a.id, .right)
        XCTAssertNotNil(try? result.get())
        XCTAssertEqual(fake.order, [b.id, a.id, c.id])
        XCTAssertEqual(service.baseline, [a.id, b.id, c.id])
        _ = await service.move(a.id, .right)
        XCTAssertEqual(service.baseline, [a.id, b.id, c.id], "baseline is the order before the first move only")
        XCTAssertEqual(service.attempts, 2)
        XCTAssertEqual(service.successes, 2)
        XCTAssertEqual(defaults.stringArray(forKey: MenuBarReorderService.baselineKey), [a.id, b.id, c.id])
    }

    func testNoNeighborAtEdge() async {
        let fake = Fake([a, b]); let service = make(fake)
        await service.refresh()
        XCTAssertFalse(service.canMove(a.id, .left))
        let result = await service.move(a.id, .left)
        XCTAssertNil(try? result.get())
        XCTAssertEqual(fake.dragCount, 0)
        XCTAssertFalse(service.hasBaseline)
    }

    func testDragThatDoesNotLandIsReportedAndItemIsLeftAlone() async {
        let fake = Fake([a, b, c]); fake.set(works: false)
        let service = make(fake)
        await service.refresh()
        let result = await service.move(a.id, .right)
        guard case .failure(let failure) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.reason, MenuBarReorderService.Message.notApplied)
        XCTAssertEqual(service.attempts, 1)
        XCTAssertEqual(service.successes, 0)
        XCTAssertFalse(service.rows.first { $0.id == a.id }!.support.isMovable)
        await service.refresh()
        XCTAssertTrue(service.rows.first { $0.id == a.id }!.support.isMovable, "refresh clears the session failure")
    }

    func testHiddenOrSystemItemsAreSkippedAsNeighbors() async {
        let sys = Self.item("Sys", bundle: "com.apple.controlcenter")
        let fake = Fake([a, sys, b]); fake.set(hidden: [])
        let service = make(fake)
        await service.refresh()
        XCTAssertTrue(service.canMove(a.id, .right))
        _ = await service.move(a.id, .right)
        XCTAssertEqual(fake.order.last, a.id, "dropped past the system item, onto the next movable one")
        XCTAssertFalse(service.canMove(sys.id, .left))
    }

    func testHiddenItemRefused() async {
        let fake = Fake([a, b]); fake.set(hidden: [b.id])
        let service = make(fake)
        await service.refresh()
        XCTAssertFalse(service.canMove(a.id, .right))
        let result = await service.move(b.id, .left)
        XCTAssertNil(try? result.get())
        XCTAssertEqual(fake.dragCount, 0)
    }

    func testStaleWhenItemMovedAfterListing() async {
        let fake = Fake([a, b, c]); let service = make(fake)
        await service.refresh()
        fake.shuffle([c.id, a.id, b.id])
        // move() reloads first, so a change before the call is simply used; a change
        // between its own read and the drag is the stale path, covered by the unknown id.
        let result = await service.move("com.example.gone:#0", .left)
        XCTAssertNil(try? result.get())
        XCTAssertEqual(service.status, MenuBarReorderService.Message.stale)
        XCTAssertEqual(fake.dragCount, 0)
    }

    func testOffAndDeniedDoNothing() async {
        let fake = Fake([a, b]); let off = make(fake, active: false)
        _ = await off.move(a.id, .right)
        XCTAssertEqual(fake.dragCount, 0)
        XCTAssertEqual(off.unavailableReason, MenuBarReorderService.Message.off)
        let service = make(fake)
        fake.set(denied: true)
        await service.refresh()
        XCTAssertTrue(service.accessDenied)
        _ = await service.move(a.id, .right)
        XCTAssertEqual(fake.dragCount, 0)
    }

    func testOldOSOffersNoMove() async {
        let fake = Fake([a, b]); let service = make(fake, os: 25)
        await service.refresh()
        XCTAssertTrue(service.rows.allSatisfy { !$0.support.isMovable })
    }

    // MARK: Restore

    func testRestoreBringsBackOriginalOrderAndClearsBaseline() async {
        let fake = Fake([a, b, c]); let service = make(fake)
        await service.refresh()
        _ = await service.move(a.id, .right)
        _ = await service.move(c.id, .left)
        XCTAssertNotEqual(fake.order, [a.id, b.id, c.id])
        let result = await service.restore()
        guard case .success(let report) = result else { return XCTFail("restore failed") }
        XCTAssertNil(report.failure)
        XCTAssertEqual(fake.order, [a.id, b.id, c.id])
        XCTAssertFalse(service.hasBaseline)
        XCTAssertNil(defaults.stringArray(forKey: MenuBarReorderService.baselineKey))
    }

    func testRestoreWorksAfterRelaunchFromSavedBaseline() async {
        let fake = Fake([a, b, c]); let first = make(fake)
        await first.refresh()
        _ = await first.move(a.id, .right)
        let second = make(fake)
        XCTAssertTrue(second.hasBaseline)
        await second.refresh()
        _ = await second.restore()
        XCTAssertEqual(fake.order, [a.id, b.id, c.id])
    }

    func testRestoreListsMissingItemsAndKeepsBaseline() async {
        let fake = Fake([a, b, c]); let service = make(fake)
        await service.refresh()
        _ = await service.move(a.id, .right)
        fake.remove(b.id)
        guard case .success(let report) = await service.restore() else { return XCTFail() }
        XCTAssertEqual(report.missing, [b.id])
        XCTAssertEqual(fake.order, [a.id, c.id])
        XCTAssertTrue(service.hasBaseline, "kept so the missing item is placed when its app returns")
    }

    func testRestoreStopsAtFirstDragThatDoesNotLand() async {
        let fake = Fake([a, b, c]); let service = make(fake)
        await service.refresh()
        _ = await service.move(a.id, .right)
        fake.set(works: false)
        guard case .success(let report) = await service.restore() else { return XCTFail() }
        XCTAssertEqual(report.failure, MenuBarReorderService.Message.notApplied)
        XCTAssertEqual(report.moved, 0)
        XCTAssertTrue(service.hasBaseline)
    }

    func testRestoreWithoutBaselineRefuses() async {
        let service = make(Fake([a, b]))
        await service.refresh()
        guard case .failure(let failure) = await service.restore() else { return XCTFail() }
        XCTAssertEqual(failure.reason, MenuBarReorderService.Message.nothingSaved)
    }

    func testDeactivateClearsRowsButKeepsSavedBaseline() async {
        let fake = Fake([a, b]); let service = make(fake)
        await service.refresh()
        _ = await service.move(a.id, .right)
        service.deactivate()
        XCTAssertTrue(service.rows.isEmpty)
        XCTAssertTrue(service.hasBaseline)
    }

    func testModuleIsOptionalSensitiveAndNeedsAccessibility() {
        let module = MenuBarReorderModule(service: make(Fake([])))
        XCTAssertFalse(module.isRequired)
        XCTAssertTrue(module.isSensitive)
        XCTAssertEqual(module.dependencies, [.permission(.accessibility)])
        XCTAssertEqual(module.commands().map(\.id), [MenuBarReorderModule.restoreCommand])
    }

    func testLandedChecksSideAndReachability() {
        let slots = [Self.slot(a, at: 0), Self.slot(b, at: 1), Self.slot(c, at: 2, reachable: false)]
        XCTAssertTrue(MenuBarReorderService.landed(a.id, b.id, .before, in: slots))
        XCTAssertFalse(MenuBarReorderService.landed(a.id, b.id, .after, in: slots))
        XCTAssertFalse(MenuBarReorderService.landed(c.id, b.id, .after, in: slots), "an unreachable item is not a landed move")
    }
}
