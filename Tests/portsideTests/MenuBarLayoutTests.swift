import XCTest
@testable import portside

/// P2-MENU-05: saved per-item sections, the pure rules that turn them into
/// moves, and the apply and reset flows over a fake bar that has separators.
@MainActor
final class MenuBarLayoutTests: XCTestCase {
    private nonisolated static func item(_ name: String, bundle: String? = nil) -> MenuBarItem {
        MenuBarItem(pid: 1, ownerBundleID: bundle ?? "com.example.\(name)", ownerName: name, ordinal: 0, identifier: nil, title: name, canPress: true)
    }

    private nonisolated static func id(_ name: String) -> String { item(name).id }

    /// A bar laid out left to right: item names, `|1` (shelf separator) and
    /// `|2` (Always Hidden separator). A drag moves a token like the menu bar does.
    private final class World: MenuBarMover, @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String]
        private var works = true
        private var drags = 0
        private var systemItems: Set<String> = []
        init(_ tokens: [String]) { self.tokens = tokens }

        var order: [String] { lock.withLock { tokens } }
        var dragCount: Int { lock.withLock { drags } }
        func set(works: Bool) { lock.withLock { self.works = works } }
        func markSystem(_ name: String) { lock.withLock { _ = systemItems.insert(name) } }

        func slots() -> [MenuBarSlot]? {
            lock.withLock {
                tokens.enumerated().compactMap { index, token in
                    guard !token.hasPrefix("|") else { return nil }
                    let item = MenuBarLayoutTests.item(token, bundle: systemItems.contains(token) ? "com.apple.\(token)" : nil)
                    return MenuBarSlot(item: item, minX: Double(index * 30), maxX: Double(index * 30 + 24), midY: 10, reachable: true)
                }
            }
        }

        func drag(_ slot: MenuBarSlot, onto target: MenuBarSlot, side: MenuBarDropSide) -> Bool {
            lock.withLock {
                drags += 1
                guard works, let from = tokens.firstIndex(of: slot.item.ownerName), tokens.indices.contains(Int(target.minX / 30)) else { return true }
                let targetToken = tokens[Int(target.minX / 30)]
                let moved = tokens.remove(at: from)
                let to = tokens.firstIndex(of: targetToken)!
                tokens.insert(moved, at: side == .before ? to : to + 1)
                return true
            }
        }

        func barFrames() -> MenuBarBars? {
            lock.withLock {
                guard let one = tokens.firstIndex(of: "|1").map({ Double($0 * 30) }) else { return nil }
                return MenuBarBars(separator: one...(one + 14), alwaysHiddenSeparator: tokens.firstIndex(of: "|2").map { Double($0 * 30) }.map { $0...($0 + 14) })
            }
        }

        var hasAlwaysHidden: Bool { lock.withLock { tokens.contains("|2") } }

        func setAlwaysHidden(_ on: Bool) {
            lock.withLock {
                if on, !tokens.contains("|2") { tokens.insert("|2", at: 0) }
                if !on { tokens.removeAll { $0 == "|2" } }
            }
        }
    }

    @MainActor
    private final class FakeShelf: MenuBarLayoutBars {
        let world: World
        var isRunning = true
        var onFailOpen: (@MainActor () -> Void)?
        var opened = 0
        var closed = 0
        init(_ world: World) { self.world = world }
        var alwaysHiddenEnabled: Bool { world.hasAlwaysHidden }
        func barFrames() -> MenuBarBars? { world.barFrames() }
        func setAlwaysHidden(_ on: Bool) { world.setAlwaysHidden(on) }
        func openForLayout() { opened += 1 }
        func closeAfterLayout() { closed += 1 }
        var mode = MenuBarShelf.Mode.revealed
        var hides = 0
        func hide() { hides += 1; mode = .hidden }
    }

    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "portside.layout.\(UUID().uuidString)")
    }

    private func make(_ world: World, active: Bool = true) -> (MenuBarLayoutService, MenuBarReorderService, FakeShelf) {
        let reorder = MenuBarReorderService(mover: world, defaults: defaults, settle: .milliseconds(1), osMajor: 27)
        reorder.activate()
        let shelf = FakeShelf(world)
        let layout = MenuBarLayoutService(reorder: reorder, shelf: shelf, defaults: defaults, settle: .milliseconds(1), osMajor: 27)
        if active { layout.activate() }
        return (layout, reorder, shelf)
    }

    // MARK: Store and rules

    func testStoreRoundTripDropsUnknownAndExports() {
        let store = MenuBarLayoutStore(defaults: defaults)
        store.set(.hidden, for: "a")
        store.set(.alwaysHidden, for: "b")
        defaults.set(["a": "hidden", "b": "alwaysHidden", "c": "bogus"], forKey: MenuBarLayoutStore.key)
        XCTAssertEqual(store.assignments, ["a": .hidden, "b": .alwaysHidden])
        XCTAssertTrue(store.exportJSON().contains("\"a\" : \"hidden\""))
        store.forget("a")
        XCTAssertEqual(store.assignments.keys.sorted(), ["b"])
        store.reset()
        XCTAssertTrue(store.assignments.isEmpty)
        defaults.set("not a dictionary", forKey: MenuBarLayoutStore.key)
        XCTAssertTrue(store.assignments.isEmpty)
    }

    func testSectionOfSlot() {
        func slot(_ x: Double) -> MenuBarSlot { MenuBarReorderService.markerSlot(x...(x + 10), midY: 0) }
        let one = MenuBarBars(separator: 100...114, alwaysHiddenSeparator: nil)
        XCTAssertEqual(MenuBarLayoutPlanner.section(of: slot(130), bars: one), .visible)
        XCTAssertEqual(MenuBarLayoutPlanner.section(of: slot(50), bars: one), .hidden)
        XCTAssertNil(MenuBarLayoutPlanner.section(of: slot(100), bars: one))
        let two = MenuBarBars(separator: 100...114, alwaysHiddenSeparator: 40...54)
        XCTAssertEqual(MenuBarLayoutPlanner.section(of: slot(70), bars: two), .hidden)
        XCTAssertEqual(MenuBarLayoutPlanner.section(of: slot(0), bars: two), .alwaysHidden)
    }

    func testAlwaysHiddenOffHoldsItemsInHiddenButKeepsChoice() {
        XCTAssertEqual(MenuBarLayoutPlanner.effective(.alwaysHidden, alwaysHiddenOn: false), .hidden)
        XCTAssertEqual(MenuBarLayoutPlanner.effective(.alwaysHidden, alwaysHiddenOn: true), .alwaysHidden)
        XCTAssertEqual(MenuBarLayoutPlanner.effective(nil, alwaysHiddenOn: true), .visible, "a new item lands Visible")
    }

    func testPlannerSkipsImmovableItems() {
        let bars = MenuBarBars(separator: 100...114, alwaysHiddenSeparator: nil)
        let hiddenSlot = MenuBarReorderService.markerSlot(10...20, midY: 0)
        let moves = MenuBarLayoutPlanner.pending(slots: [(hiddenSlot, true)], bars: bars, saved: [:])
        XCTAssertEqual(moves, [MenuBarLayoutPlanner.Move(id: hiddenSlot.id, target: .visible, marker: .separator, side: .after)])
        XCTAssertTrue(MenuBarLayoutPlanner.pending(slots: [(hiddenSlot, false)], bars: bars, saved: [:]).isEmpty)
        XCTAssertTrue(MenuBarLayoutPlanner.pending(slots: [(hiddenSlot, true)], bars: bars, saved: [hiddenSlot.id: .hidden]).isEmpty)
    }

    // MARK: Apply

    func testApplyMovesAssignedItemIntoHiddenAndKeepsOthers() async {
        let world = World(["A", "|1", "B", "C"])
        let (layout, _, shelf) = make(world)
        await layout.refresh()
        layout.assign(Self.id("A"), to: .hidden)
        layout.assign(Self.id("B"), to: .hidden)
        let result = await layout.apply()
        XCTAssertEqual(try? result.get().moved, 1)
        XCTAssertEqual(world.order, ["A", "B", "|1", "C"])
        XCTAssertEqual(shelf.opened, 2, "one for the refresh listing, one for Apply")
        XCTAssertEqual(shelf.closed, 1)
    }

    // MARK: Drop

    func testDropMovesRightAwayAndSavesOnlyAfterItLands() async {
        let world = World(["A", "|1", "B", "C"])
        let (layout, _, _) = make(world)
        await layout.beginEditing()
        let result = await layout.drop(Self.id("C"), into: .hidden)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(world.order, ["A", "C", "|1", "B"])
        XCTAssertEqual(layout.rows.first { $0.id == Self.id("C") }?.section, .hidden)
        XCTAssertEqual(layout.driftCount, 0)
        XCTAssertEqual(layout.pendingCount, 1, "A was never placed, and the drop did not touch it")
    }

    func testDropBeforeAnItemReordersAndCanCrossSections() async {
        let world = World(["A", "|1", "B", "C"])
        let (layout, _, _) = make(world)
        await layout.beginEditing()
        _ = await layout.drop(Self.id("C"), into: .visible, before: Self.id("B"))
        XCTAssertEqual(world.order, ["A", "|1", "C", "B"])
        _ = await layout.drop(Self.id("B"), into: .hidden, before: Self.id("A"))
        XCTAssertEqual(world.order, ["B", "A", "|1", "C"])
    }

    func testDropThatDoesNotLandIsNotSavedAndStaysWhereItIs() async {
        let world = World(["A", "|1", "B"])
        let (layout, _, _) = make(world)
        await layout.beginEditing()
        world.set(works: false)
        let result = await layout.drop(Self.id("B"), into: .hidden)
        guard case .failure = result else { return XCTFail("expected a failure") }
        XCTAssertEqual(layout.rows.first { $0.id == Self.id("B") }?.saved, nil)
        XCTAssertEqual(layout.rows.first { $0.id == Self.id("B") }?.section, .visible)
        XCTAssertEqual(layout.status, MenuBarReorderService.Message.notApplied)
        XCTAssertFalse(layout.isBusy)
    }

    func testDropOnItselfAndIntoItsOwnSectionDoNothing() async {
        let world = World(["A", "|1", "B"])
        let (layout, _, _) = make(world)
        await layout.beginEditing()
        _ = await layout.drop(Self.id("B"), into: .visible, before: Self.id("B"))
        _ = await layout.drop(Self.id("B"), into: .visible)
        XCTAssertEqual(world.dragCount, 0)
    }

    func testDropIntoAlwaysHiddenTurnsItOn() async {
        let world = World(["A", "|1", "B"])
        let (layout, _, _) = make(world)
        await layout.beginEditing()
        _ = await layout.drop(Self.id("B"), into: .alwaysHidden)
        XCTAssertTrue(layout.alwaysHiddenOn)
        XCTAssertEqual(world.order, ["B", "|2", "A", "|1"])
    }

    func testSystemItemCannotBeDropped() async {
        let world = World(["S", "|1", "B"])
        world.markSystem("S")
        let (layout, _, _) = make(world)
        await layout.beginEditing()
        let row = layout.rows.first { $0.slot.item.ownerName == "S" }!
        XCTAssertFalse(row.canDrag)
        _ = await layout.drop(row.id, into: .visible)
        XCTAssertEqual(world.dragCount, 0)
        XCTAssertTrue(layout.status?.contains("macOS owns") ?? false)
    }

    func testPutBackLeavesItemsYouNeverPlacedAlone() async {
        let world = World(["A", "|1", "B"])
        let (layout, _, _) = make(world)
        await layout.beginEditing()
        _ = await layout.drop(Self.id("B"), into: .hidden)
        XCTAssertEqual(world.order, ["A", "B", "|1"])
        layout.assign(Self.id("B"), to: .visible)
        XCTAssertEqual(layout.driftCount, 1)
        _ = await layout.apply(onlySaved: true)
        XCTAssertEqual(world.order, ["A", "|1", "B"], "A stays Hidden: it was never placed")
    }

    // MARK: Editing session

    func testEditingKeepsItemsShownThenRestoresTheShelf() async {
        let world = World(["A", "|1", "B"])
        let (layout, _, shelf) = make(world)
        shelf.mode = .hidden
        await layout.beginEditing()
        XCTAssertTrue(layout.isEditing)
        _ = await layout.drop(Self.id("B"), into: .hidden)
        XCTAssertEqual(shelf.closed, 0, "stays open while the editor is up")
        XCTAssertEqual(shelf.hides, 0)
        layout.endEditing()
        XCTAssertFalse(layout.isEditing)
        XCTAssertEqual(shelf.closed, 1)
        XCTAssertEqual(shelf.hides, 1, "it was closed when editing began")
    }

    func testEndEditingDoesNotHideAShelfThatWasOpen() async {
        let world = World(["A", "|1", "B"])
        let (layout, _, shelf) = make(world)
        await layout.beginEditing()
        layout.endEditing()
        XCTAssertEqual(shelf.hides, 0)
    }

    func testRefreshShowsTheShelfSoEveryItemIsListed() async {
        let world = World(["A", "|1", "B", "C"])
        let (layout, _, shelf) = make(world)
        await layout.refresh()
        XCTAssertEqual(shelf.opened, 1)
        XCTAssertEqual(layout.rows.count, 3)
        XCTAssertFalse(layout.accessDenied)
    }

    func testUnassignedItemLeftOfSeparatorLandsVisible() async {
        let world = World(["A", "|1", "B"])
        let (layout, _, _) = make(world)
        await layout.refresh()
        _ = await layout.apply()
        XCTAssertEqual(world.order, ["|1", "A", "B"])
    }

    func testAlwaysHiddenNeedsSwitchAndMovesLeftOfItsSeparator() async {
        let world = World(["A", "|1", "B"])
        let (layout, _, _) = make(world)
        await layout.refresh()
        layout.assign(Self.id("B"), to: .alwaysHidden)
        _ = await layout.apply()
        XCTAssertEqual(world.order, ["B", "|1", "A"], "off: Always Hidden is held in Hidden, unassigned A comes out")
        let world2 = World(["A", "B", "|1", "C"])
        let (layout2, _, _) = make(world2)
        layout2.setAlwaysHidden(true)
        await layout2.refresh()
        layout2.assign(Self.id("C"), to: .alwaysHidden)
        layout2.assign(Self.id("A"), to: .hidden)
        layout2.assign(Self.id("B"), to: .hidden)
        _ = await layout2.apply()
        XCTAssertEqual(world2.order, ["C", "|2", "A", "B", "|1"])
        XCTAssertTrue(layout2.alwaysHiddenOn)
    }

    func testSystemItemIsNotMovedAndIsExplained() async {
        let world = World(["S", "|1", "A"])
        world.markSystem("S")
        let (layout, _, _) = make(world)
        await layout.refresh()
        let row = layout.rows.first { $0.slot.item.ownerName == "S" }
        XCTAssertNotNil(row?.structural)
        XCTAssertFalse(row?.canAssign ?? true)
        layout.assign(row!.id, to: .visible)
        XCTAssertTrue(MenuBarLayoutStore(defaults: defaults).assignments.isEmpty, "an unsupported item is never saved")
        let result = await layout.apply()
        XCTAssertEqual(world.order, ["S", "|1", "A"])
        XCTAssertEqual(world.dragCount, 0)
        XCTAssertEqual(try? result.get().stranded.count, 1)
        XCTAssertTrue(layout.status?.contains("macOS owns") ?? false)
    }

    func testDragThatDoesNotLandStopsAndLocksTheItem() async {
        let world = World(["A", "|1", "B"])
        world.set(works: false)
        let (layout, _, shelf) = make(world)
        await layout.refresh()
        let result = await layout.apply()
        XCTAssertNil(try? result.get())
        XCTAssertEqual(world.dragCount, 1, "no retry")
        XCTAssertEqual(layout.status, MenuBarReorderService.Message.notApplied)
        XCTAssertEqual(shelf.closed, 1, "the shelf is put back even after a failure")
    }

    func testOffServiceAndMissingShelfDoNothing() async {
        let world = World(["A", "|1"])
        let (off, _, shelf0) = make(world, active: false)
        let result = await off.apply()
        XCTAssertNil(try? result.get())
        XCTAssertEqual(world.dragCount, 0)
        XCTAssertEqual(shelf0.opened, 0)
        let (layout, _, shelf) = make(world)
        shelf.isRunning = false
        let second = await layout.apply()
        guard case .failure(let failure) = second else { return XCTFail("expected a refusal") }
        XCTAssertEqual(failure.reason, MenuBarLayoutService.Message.noShelf)
        XCTAssertEqual(world.dragCount, 0)
    }

    func testMissingSeparatorsReportAndMoveNothing() async {
        let world = World(["A", "B"])
        let (layout, _, _) = make(world)
        await layout.refresh()
        XCTAssertFalse(layout.barsReady)
        let result = await layout.apply()
        XCTAssertNil(try? result.get())
        XCTAssertEqual(layout.status, MenuBarLayoutService.Message.noBars)
        XCTAssertEqual(world.dragCount, 0)
    }

    func testSavedChoiceForAppThatQuitIsListedAndKept() async {
        let world = World(["|1", "A"])
        let (layout, _, _) = make(world)
        layout.assign("com.gone:#0", to: .hidden)
        MenuBarLayoutStore(defaults: defaults).set(.hidden, for: "com.gone:#0")
        await layout.refresh()
        XCTAssertEqual(layout.missing, ["com.gone:#0"])
        layout.forget("com.gone:#0")
        XCTAssertTrue(layout.missing.isEmpty)
    }

    // MARK: Reset

    func testResetClearsChoicesTurnsAlwaysHiddenOffAndRestoresOrder() async {
        let world = World(["A", "B", "|1", "C"])
        let (layout, reorder, shelf) = make(world)
        layout.setAlwaysHidden(true)
        await layout.refresh()
        layout.assign(Self.id("C"), to: .alwaysHidden)
        layout.assign(Self.id("A"), to: .hidden)
        _ = await layout.apply()
        XCTAssertTrue(reorder.hasBaseline)
        let result = await layout.resetToNative()
        XCTAssertNotNil(try? result.get())
        XCTAssertTrue(MenuBarLayoutStore(defaults: defaults).assignments.isEmpty)
        XCTAssertFalse(world.hasAlwaysHidden)
        let order = world.order
        XCTAssertTrue(order.firstIndex(of: "|1")! < order.firstIndex(of: "A")!)
        XCTAssertTrue(order.firstIndex(of: "|1")! < order.firstIndex(of: "B")!)
        XCTAssertTrue(order.firstIndex(of: "|1")! < order.firstIndex(of: "C")!)
        XCTAssertEqual(order.filter { $0 != "|1" }, ["A", "B", "C"], "original order is back")
        XCTAssertEqual(layout.status, "Menu bar layout reset.")
    }

    func testDeactivateCollapsesAlwaysHiddenAndKeepsChoices() async {
        let world = World(["|1", "A"])
        let (layout, _, _) = make(world)
        layout.setAlwaysHidden(true)
        layout.assign("x", to: .hidden)
        MenuBarLayoutStore(defaults: defaults).set(.hidden, for: Self.id("A"))
        layout.deactivate()
        XCTAssertFalse(world.hasAlwaysHidden)
        XCTAssertEqual(MenuBarLayoutStore(defaults: defaults).assignments[Self.id("A")], .hidden)
    }

    func testShelfFailOpenAlsoSwitchesAlwaysHiddenOff() {
        let surface = MenuBarShelfTests.FakeSurface()
        let shelf = MenuBarShelf(surface: surface, verifyDelay: .milliseconds(5))
        var told = 0
        shelf.onFailOpen = { told += 1 }
        shelf.setAlwaysHidden(true)
        XCTAssertFalse(shelf.alwaysHiddenEnabled, "not running yet")
        shelf.start()
        shelf.setAlwaysHidden(true)
        XCTAssertTrue(surface.alwaysHiddenInstalled)
        XCTAssertTrue(surface.alwaysHiddenClipped)
        shelf.failOpen("the displays changed")
        XCTAssertFalse(shelf.alwaysHiddenEnabled)
        XCTAssertFalse(surface.alwaysHiddenInstalled)
        XCTAssertEqual(told, 1)
        shelf.setAlwaysHidden(true)
        shelf.stop()
        XCTAssertFalse(surface.alwaysHiddenInstalled)
        XCTAssertFalse(shelf.alwaysHiddenEnabled)
    }
}
