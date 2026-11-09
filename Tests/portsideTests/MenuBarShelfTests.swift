import XCTest
@testable import portside

@MainActor
final class MenuBarShelfTests: XCTestCase {
    final class FakeSurface: MenuBarShelfSurface {
        var installed = false
        var hidden = false
        var onScreen = true
        var applied: [Bool] = []
        func install() { installed = true }
        func apply(hidden: Bool) { self.hidden = hidden; applied.append(hidden) }
        func controlIsOnScreen() -> Bool { onScreen }
        func remove() { installed = false }
        var alwaysHiddenInstalled = false
        var alwaysHiddenClipped = false
        var frames: MenuBarBars?
        func installAlwaysHidden() { alwaysHiddenInstalled = true }
        func applyAlwaysHidden(hidden: Bool) { alwaysHiddenClipped = hidden }
        func removeAlwaysHidden() { alwaysHiddenInstalled = false; alwaysHiddenClipped = false }
        func barFrames() -> MenuBarBars? { frames }
    }

    private func make(delay: Duration = .milliseconds(10)) -> (MenuBarShelf, FakeSurface) {
        let surface = FakeSurface()
        return (MenuBarShelf(surface: surface, verifyDelay: delay), surface)
    }

    private func makeModule(_ shelf: MenuBarShelf) -> MenuBarShelfModule {
        let triggers = MenuBarTriggerService(
            shelf: shelf,
            environment: MenuBarTriggersTests.FakeEnvironment(),
            probe: MenuBarTriggersTests.FakeProbe()
        )
        return MenuBarShelfModule(shelf: shelf, triggers: triggers)
    }

    func testStartsRevealedAndInstalls() {
        let (shelf, surface) = make()
        shelf.start()
        XCTAssertTrue(surface.installed)
        XCTAssertEqual(shelf.mode, .revealed)
        XCTAssertFalse(surface.hidden)
    }

    func testToggleHidesThenReveals() {
        let (shelf, surface) = make()
        shelf.start()
        shelf.toggle()
        XCTAssertEqual(shelf.mode, .hidden)
        XCTAssertTrue(surface.hidden)
        shelf.toggle()
        XCTAssertEqual(shelf.mode, .revealed)
        XCTAssertFalse(surface.hidden)
    }

    func testStopRevealsAndRemoves() {
        let (shelf, surface) = make()
        shelf.start()
        shelf.hide()
        shelf.stop()
        XCTAssertFalse(surface.hidden)
        XCTAssertFalse(surface.installed)
        XCTAssertEqual(shelf.mode, .revealed)
    }

    func testHideBeforeStartDoesNothing() {
        let (shelf, surface) = make()
        shelf.hide()
        XCTAssertEqual(shelf.mode, .revealed)
        XCTAssertTrue(surface.applied.isEmpty)
    }

    func testFailOpenRevealsAndRecordsReason() {
        let (shelf, surface) = make()
        shelf.start()
        shelf.hide()
        shelf.failOpen("the displays changed")
        XCTAssertEqual(shelf.mode, .revealed)
        XCTAssertFalse(surface.hidden)
        XCTAssertEqual(shelf.lastFailOpen, "the displays changed")
    }

    func testFailOpenWhileRevealedIsQuiet() {
        let (shelf, surface) = make()
        shelf.start()
        let before = surface.applied.count
        shelf.failOpen("the Mac woke")
        XCTAssertEqual(surface.applied.count, before)
        XCTAssertNil(shelf.lastFailOpen)
    }

    func testControlPushedOffScreenRevealsAfterVerify() async throws {
        let (shelf, surface) = make()
        shelf.start()
        surface.onScreen = false
        shelf.hide()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(shelf.mode, .revealed)
        XCTAssertFalse(surface.hidden)
        XCTAssertNotNil(shelf.lastFailOpen)
    }

    func testControlOnScreenStaysHidden() async throws {
        let (shelf, _) = make()
        shelf.start()
        shelf.hide()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(shelf.mode, .hidden)
    }

    func testRevealCancelsPendingVerify() async throws {
        let (shelf, surface) = make()
        shelf.start()
        surface.onScreen = false
        shelf.hide()
        shelf.reveal()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(shelf.lastFailOpen)
    }

    func testRepeatedToggleDoesNotDrift() {
        let (shelf, surface) = make()
        shelf.start()
        for _ in 0..<20 { shelf.toggle() }
        XCTAssertEqual(shelf.mode, .revealed)
        XCTAssertFalse(surface.hidden)
    }

    func testModuleStopRevealsAndRemoves() throws {
        let (shelf, surface) = make()
        let gate = PermissionGate()
        let registry = ModuleRegistry(commands: CommandRegistry(permissions: gate), permissions: gate)
        try registry.register(makeModule(shelf))
        registry.enable(MenuBarShelfModule.moduleID)
        XCTAssertTrue(surface.installed)
        shelf.hide()
        XCTAssertTrue(surface.hidden)
        registry.disable(MenuBarShelfModule.moduleID)
        XCTAssertFalse(surface.installed)
        XCTAssertFalse(surface.hidden)
    }

    func testModuleIsSensitiveOptionalAndNeedsNoPermission() {
        let module = makeModule(MenuBarShelf(surface: FakeSurface()))
        XCTAssertFalse(module.isRequired)
        XCTAssertTrue(module.isSensitive)
        XCTAssertTrue(module.dependencies.isEmpty)
        XCTAssertEqual(module.commands().first?.id, MenuBarShelfModule.toggleCommand)
    }

    func testHidingWidthReachesTheScreenEdgeNotAFixedFew() {
        XCTAssertEqual(StatusItemShelfSurface.widthToClear(rightEdge: 1500, screenMinX: 0), 1540, "pushes every item on its left off screen")
        XCTAssertEqual(StatusItemShelfSurface.widthToClear(rightEdge: 1500, screenMinX: -1920), 3460, "a display left of the primary")
        XCTAssertEqual(StatusItemShelfSurface.widthToClear(rightEdge: 40, screenMinX: 0), StatusItemShelfSurface.hiddenLength, "never under the old width")
        XCTAssertEqual(StatusItemShelfSurface.widthToClear(rightEdge: 90_000, screenMinX: 0), StatusItemShelfSurface.maxHiddenLength)
        XCTAssertEqual(StatusItemShelfSurface.widthToClear(rightEdge: nil, screenMinX: nil), 3000, "no reading still clears any display")
    }

    func testSeedPositionsDoesNotOverwriteUserChoice() {
        let defaults = UserDefaults(suiteName: "portside.shelf.\(UUID().uuidString)")!
        let key = "NSStatusItem Preferred Position \(StatusItemShelfSurface.controlName)"
        defaults.set(333.0, forKey: key)
        StatusItemShelfSurface.seedPositions(defaults)
        XCTAssertEqual(defaults.double(forKey: key), 333.0)
        XCTAssertNotNil(defaults.object(forKey: "NSStatusItem Preferred Position \(StatusItemShelfSurface.separatorName)"))
    }
}
