import AppKit
import ApplicationServices
import OSLog

/// A menu bar item with where it sits now (P2-MENU-04). `minX`/`maxX` are
/// Accessibility frame edges in screen points; `reachable` means a hit test
/// at the item's center returns exactly this item (clipped, hidden and covered
/// items fail it, spike O9).
struct MenuBarSlot: Equatable, Identifiable, Sendable {
    let item: MenuBarItem
    let minX: Double
    let maxX: Double
    let midY: Double
    let reachable: Bool

    var id: String { item.id }
}

enum MenuBarMoveSupport: Equatable, Sendable {
    case movable
    /// Not moved, with the reason shown next to the item.
    case unsupported(String)

    var isMovable: Bool { self == .movable }
}

enum MenuBarDropSide: Equatable, Sendable { case before, after }

/// Pure rules: which items may move, and the minimal drags that reach an order.
enum MenuBarLayoutRules {
    /// Lowest macOS major version a move is offered on. The spike ran on 27;
    /// 26 is the other supported release and is untested, so it is offered
    /// but the hand gate for it is open (CHECKLIST).
    static let minimumOSMajor = 26

    static func support(for slot: MenuBarSlot, osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion, failed: Set<String> = []) -> MenuBarMoveSupport {
        if osMajor < minimumOSMajor { return .unsupported("Moving needs macOS \(minimumOSMajor) or later.") }
        guard let bundle = slot.item.ownerBundleID else { return .unsupported("Its app has no bundle identifier, so it cannot be told apart after a restart.") }
        if bundle.lowercased().hasPrefix("com.apple.") { return .unsupported("macOS owns the order of its own items.") }
        if osMajor >= 27, !slot.item.canPress { return .unsupported("It does not offer an open action, so it is not a validated item.") }
        if failed.contains(slot.id) { return .unsupported("It did not move when tried, so Portside leaves it alone until you refresh.") }
        if !slot.reachable { return .unsupported("It is hidden, clipped by the notch or covered. Show it in the menu bar first.") }
        return .movable
    }

    /// Items left to right.
    static func ordered(_ slots: [MenuBarSlot]) -> [MenuBarSlot] {
        slots.sorted { ($0.minX, $0.id) < ($1.minX, $1.id) }
    }

    /// Drags that turn `current` into `desired` for the ids in both. Items
    /// not in `desired` keep their places. Each step puts `id` just before
    /// `before`; there are never more than `current.count - 1` steps.
    static func plan(current: [String], desired: [String]) -> [(id: String, before: String)] {
        let known = Set(current).intersection(desired)
        var queue = desired.filter { known.contains($0) }
        var order = current
        var target = current
        for index in target.indices where known.contains(target[index]) { target[index] = queue.removeFirst() }
        var steps: [(id: String, before: String)] = []
        for index in order.indices where order[index] != target[index] {
            let id = target[index]
            steps.append((id, order[index]))
            order.removeAll { $0 == id }
            order.insert(id, at: index)
        }
        return steps
    }
}

/// Reads item positions and performs one drag. The live one uses Accessibility
/// and `CGEvent`; tests inject a fixture. Both calls block, so callers run them
/// off the main actor.
protocol MenuBarMover: Sendable {
    /// Every listed item with its position, or nil if Accessibility is denied.
    func slots() -> [MenuBarSlot]?
    /// One Cmd-drag of `slot` onto the given side of `target`. False if it was
    /// not performed (denied, a mouse button already down).
    func drag(_ slot: MenuBarSlot, onto target: MenuBarSlot, side: MenuBarDropSide) -> Bool
}

/// Accessibility positions plus a public `CGEvent` Cmd-drag, the route proven
/// in the hide/recovery spike (O8). No attribute is set (`AXPosition` is not
/// settable) and nothing private is loaded.
struct AXMenuBarMover: MenuBarMover {
    let source: AXMenuBarItemSource

    static let live = AXMenuBarMover(source: .live)

    func slots() -> [MenuBarSlot]? {
        guard source.isTrusted() else { return nil }
        let deadline = Date().addingTimeInterval(AXMenuBarItemSource.sweepDeadline)
        var result: [MenuBarSlot] = []
        for app in source.running() {
            if Date() >= deadline { break }
            guard case .found(let elements) = AXMenuBarItemSource.elements(pid: app.pid) else { continue }
            for (ordinal, element) in elements.enumerated() {
                guard let item = AXMenuBarItemSource.read(element, pid: app.pid, bundleID: app.bundleID, name: app.name, ordinal: ordinal),
                      let frame = Self.frame(of: element) else { continue }
                result.append(MenuBarSlot(
                    item: item, minX: frame.minX, maxX: frame.maxX, midY: frame.midY,
                    reachable: AXMenuBarItemSource.hitTestedCenter(of: element) != nil
                ))
            }
        }
        return result
    }

    func drag(_ slot: MenuBarSlot, onto target: MenuBarSlot, side: MenuBarDropSide) -> Bool {
        guard source.isTrusted(), !CGEventSource.buttonState(.combinedSessionState, button: .left) else { return false }
        let from = CGPoint(x: (slot.minX + slot.maxX) / 2, y: slot.midY)
        let to = CGPoint(x: side == .before ? target.minX + 2 : target.maxX - 2, y: target.midY)
        let origin = CGEvent(source: nil)?.location
        let events = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, at point: CGPoint) {
            let event = CGEvent(mouseEventSource: events, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, at: from)
        usleep(80_000)
        post(.leftMouseDown, at: from)
        usleep(60_000)
        let steps = 24
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            post(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            usleep(8_000)
        }
        usleep(60_000)
        post(.leftMouseUp, at: to)
        usleep(60_000)
        if let origin { CGWarpMouseCursorPosition(origin) }
        return true
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        var position = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size), size.width > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
}

/// What the Settings section shows and does. Moves are one at a time, each
/// re-reads positions first (an item that changed is refused as stale) and
/// confirms the result after (a drag that did not land is reported, counted and
/// not retried). The order before the first move is saved in Portside's own
/// defaults, so "Restore" works after a crash or relaunch; a saved item that is
/// no longer present is listed, never guessed.
@MainActor
final class MenuBarReorderService: ObservableObject {
    struct Row: Identifiable, Equatable {
        let slot: MenuBarSlot
        let support: MenuBarMoveSupport
        var id: String { slot.id }
    }

    enum Direction { case left, right }

    enum Message {
        static let off = "Menu bar reordering is turned off."
        static let denied = "Accessibility permission is denied or was revoked."
        static let busy = "A move is already running."
        static let stale = "That item moved or its app quit. The list was refreshed."
        static let noNeighbor = "There is no movable item on that side."
        static let notApplied = "The item did not move. Portside left it alone."
        static let mouse = "A mouse button is down. Release it and try again."
        static let noMarker = "The shelf separators are not in place. Turn the Menu Bar Shelf on and show its items first."
        static let nothingSaved = "No original order is saved. Nothing to restore."
    }

    static let baselineKey = "menuBarReorder.baselineOrder"
    nonisolated static let settleDelay: Duration = .milliseconds(350)

    @Published private(set) var rows: [Row] = []
    @Published private(set) var status: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isActive = false
    @Published private(set) var accessDenied = false
    @Published private(set) var attempts = 0
    @Published private(set) var successes = 0
    @Published private(set) var baseline: [String]

    private var failed: Set<String> = []
    private let mover: MenuBarMover
    private let defaults: UserDefaults
    private let settle: Duration
    private let osMajor: Int
    private let log = Logger(subsystem: "com.james.portside", category: "menubar-reorder")

    init(
        mover: MenuBarMover = AXMenuBarMover.live,
        defaults: UserDefaults = .standard,
        settle: Duration = MenuBarReorderService.settleDelay,
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) {
        self.mover = mover
        self.defaults = defaults
        self.settle = settle
        self.osMajor = osMajor
        baseline = defaults.stringArray(forKey: Self.baselineKey) ?? []
    }

    var hasBaseline: Bool { !baseline.isEmpty }
    var unavailableReason: String? { isActive ? nil : Message.off }

    func activate() { isActive = true }

    func deactivate() {
        isActive = false
        rows = []
        status = nil
        accessDenied = false
        failed = []
    }

    func refresh() async {
        guard isActive else { return }
        await reload(clearFailures: true)
    }

    func canMove(_ id: String, _ direction: Direction) -> Bool {
        neighbor(of: id, direction) != nil
    }

    /// Swaps `id` past the nearest movable item on one side.
    @discardableResult
    func move(_ id: String, _ direction: Direction) async -> Result<Void, CommandFailure> {
        if let reason = guardIdle() { return .failure(CommandFailure(reason: reason)) }
        isBusy = true
        defer { isBusy = false }
        await reload()
        guard accessDenied == false else { return fail(Message.denied) }
        guard let slot = rows.first(where: { $0.id == id && $0.support.isMovable })?.slot,
              let target = neighbor(of: id, direction)?.slot else { return fail(rows.contains { $0.id == id } ? Message.noNeighbor : Message.stale) }
        saveBaselineIfNeeded()
        let outcome = await perform(slot, onto: target, side: direction == .left ? .before : .after)
        if let outcome { return fail(outcome) }
        status = "Moved \(slot.item.displayTitle)."
        return .success(())
    }

    struct RestoreReport: Equatable {
        var moved = 0
        var missing: [String] = []
        var failure: String?
    }

    /// Replays drags until the saved original order is back, as far as the
    /// items present allow. Stops at the first drag that does not land.
    @discardableResult
    func restore() async -> Result<RestoreReport, CommandFailure> {
        if let reason = guardIdle() { return .failure(CommandFailure(reason: reason)) }
        guard hasBaseline else { return fail(Message.nothingSaved) }
        isBusy = true
        defer { isBusy = false }
        await reload()
        guard accessDenied == false else { return fail(Message.denied) }
        var report = RestoreReport()
        let present = Set(rows.map(\.id))
        report.missing = baseline.filter { !present.contains($0) }
        let movable = rows.filter(\.support.isMovable).map(\.id)
        let steps = MenuBarLayoutRules.plan(current: movable, desired: baseline)
        for step in steps {
            guard let slot = rows.first(where: { $0.id == step.id })?.slot,
                  let target = rows.first(where: { $0.id == step.before })?.slot else { report.failure = Message.stale; break }
            if let reason = await perform(slot, onto: target, side: .before) { report.failure = reason; break }
            report.moved += 1
        }
        if report.failure == nil {
            // Only a clean pass clears the saved order. Items listed as missing
            // keep it, so they are put back when their app returns.
            if report.missing.isEmpty { clearBaseline() }
            status = report.missing.isEmpty ? "Original order restored." : "Restored what is present. Not found: \(report.missing.joined(separator: ", "))."
        } else {
            status = report.failure
        }
        return .success(report)
    }

    func discardBaseline() {
        clearBaseline()
        status = "Forgot the saved original order."
    }

    // MARK: Internals

    private func guardIdle() -> String? {
        if !isActive { return Message.off }
        if isBusy { return Message.busy }
        return nil
    }

    private func fail<T>(_ reason: String) -> Result<T, CommandFailure> {
        status = reason
        return .failure(CommandFailure(reason: reason))
    }

    /// Returns a failure reason, nil on a confirmed move.
    private func perform(_ slot: MenuBarSlot, onto target: MenuBarSlot, side: MenuBarDropSide) async -> String? {
        let mover = mover
        // Positions read at list time may be old: the drag runs only if both
        // items are still where they were listed.
        guard let before = await Task.detached(priority: .userInitiated, operation: { mover.slots() }).value else { return Message.denied }
        guard Self.same(before, slot), Self.same(before, target) else {
            await reload()
            return Message.stale
        }
        attempts += 1
        let dragged = await Task.detached(priority: .userInitiated, operation: { mover.drag(slot, onto: target, side: side) }).value
        guard dragged else { return Message.mouse }
        try? await Task.sleep(for: settle)
        await reload()
        guard Self.landed(slot.id, target.id, side, in: rows.map(\.slot)) else {
            failed.insert(slot.id)
            rebuildRows(slots: rows.map(\.slot))
            log.error("menu bar move did not land for \(slot.id, privacy: .public)")
            return Message.notApplied
        }
        successes += 1
        return nil
    }

    /// One verified drag of `id` to just left of another item, for a drop in
    /// the layout editor. Positions must be fresh. Returns a failure reason.
    func place(_ id: String, before targetID: String) async -> String? {
        guard let slot = rows.first(where: { $0.id == id && $0.support.isMovable })?.slot,
              let target = rows.first(where: { $0.id == targetID })?.slot else { return Message.stale }
        saveBaselineIfNeeded()
        return await perform(slot, onto: target, side: .before)
    }

    /// One drag of `slot` onto a side of a fixed marker, a Portside separator
    /// that is not in the Accessibility list (P2-MENU-05). Same checks as a
    /// neighbor move: the item and the marker must still sit where they were
    /// read, and the item must be on the intended side afterwards, or it is
    /// locked for the session and nothing is retried. Returns a failure reason.
    func place(_ slot: MenuBarSlot, side: MenuBarDropSide, marker: () -> ClosedRange<Double>?) async -> String? {
        guard let span = marker() else { return Message.noMarker }
        saveBaselineIfNeeded()
        let mover = mover
        guard let before = await Task.detached(priority: .userInitiated, operation: { mover.slots() }).value else { return Message.denied }
        guard Self.same(before, slot) else {
            await reload()
            return Message.stale
        }
        guard let fresh = marker(), abs(fresh.lowerBound - span.lowerBound) < 1, abs(fresh.upperBound - span.upperBound) < 1 else { return Message.noMarker }
        let target = Self.markerSlot(span, midY: slot.midY)
        attempts += 1
        let dragged = await Task.detached(priority: .userInitiated, operation: { mover.drag(slot, onto: target, side: side) }).value
        guard dragged else { return Message.mouse }
        try? await Task.sleep(for: settle)
        await reload()
        if let now = marker(), let moved = rows.first(where: { $0.id == slot.id })?.slot, Self.sits(moved, side, of: now) {
            successes += 1
            return nil
        }
        failed.insert(slot.id)
        rebuildRows(slots: rows.map(\.slot))
        log.error("menu bar placement did not land for \(slot.id, privacy: .public)")
        return Message.notApplied
    }

    /// A stand-in for a separator, so the same drag code can aim at it.
    nonisolated static func markerSlot(_ span: ClosedRange<Double>, midY: Double) -> MenuBarSlot {
        MenuBarSlot(
            item: MenuBarItem(pid: getpid(), ownerBundleID: "com.james.portside", ownerName: "Portside", ordinal: 0, identifier: "separator", title: "Separator", canPress: false),
            minX: span.lowerBound, maxX: span.upperBound, midY: midY, reachable: true
        )
    }

    /// The item is wholly on `side` of the marker, and reachable.
    nonisolated static func sits(_ slot: MenuBarSlot, _ side: MenuBarDropSide, of marker: ClosedRange<Double>) -> Bool {
        guard slot.reachable else { return false }
        return side == .before ? slot.maxX <= marker.lowerBound + 1 : slot.minX >= marker.upperBound - 1
    }

    private static func same(_ slots: [MenuBarSlot], _ slot: MenuBarSlot) -> Bool {
        slots.first { $0.id == slot.id }.map { $0.reachable && abs($0.minX - slot.minX) < 1 && abs($0.maxX - slot.maxX) < 1 } ?? false
    }

    /// The moved item now sits on the intended side of the target, reachable.
    static func landed(_ id: String, _ targetID: String, _ side: MenuBarDropSide, in slots: [MenuBarSlot]) -> Bool {
        let order = MenuBarLayoutRules.ordered(slots.filter(\.reachable)).map(\.id)
        guard let moved = order.firstIndex(of: id), let target = order.firstIndex(of: targetID) else { return false }
        return side == .before ? moved < target : moved > target
    }

    private func neighbor(of id: String, _ direction: Direction) -> Row? {
        let movable = rows.filter(\.support.isMovable)
        guard let index = movable.firstIndex(where: { $0.id == id }) else { return nil }
        let next = direction == .left ? index - 1 : index + 1
        return movable.indices.contains(next) ? movable[next] : nil
    }

    func reload(clearFailures: Bool = false) async {
        let mover = mover
        let slots = await Task.detached(priority: .userInitiated) { mover.slots() }.value
        guard isActive else { return }
        if clearFailures { failed = [] }
        guard let slots else {
            accessDenied = true
            rows = []
            return
        }
        accessDenied = false
        rebuildRows(slots: slots)
    }

    private func rebuildRows(slots: [MenuBarSlot]) {
        rows = MenuBarLayoutRules.ordered(slots).map {
            Row(slot: $0, support: MenuBarLayoutRules.support(for: $0, osMajor: osMajor, failed: failed))
        }
    }

    /// Before the first move since the last restore: the order of the items
    /// that can move, left to right.
    func saveBaselineIfNeeded() {
        guard !hasBaseline else { return }
        baseline = rows.filter(\.support.isMovable).map(\.id)
        defaults.set(baseline, forKey: Self.baselineKey)
    }

    private func clearBaseline() {
        baseline = []
        defaults.removeObject(forKey: Self.baselineKey)
    }
}

/// The optional `menuBarReorder` module (P2-MENU-04). Off by default, held off
/// by restricted mode, needs Accessibility. It never changes the Menu Bar Shelf
/// or its recovery: a hidden or clipped item is simply not movable.
@MainActor
final class MenuBarReorderModule: PortsideModule {
    static let moduleID = ModuleID("menuBarReorder")!
    static let restoreCommand = CommandID("menuBarReorder.restore")!

    let id = MenuBarReorderModule.moduleID
    let title = "Menu Bar Reorder (experimental)"
    let summary = "Moves third-party menu bar items one slot left or right from Settings, and puts them back in their original order. A move is a real Command-drag, so the pointer moves for a moment and the item must be on screen. System items, hidden or notch-clipped items and items that do not move are left alone, with the reason shown. The order before your first move is saved so Restore works after a relaunch. Needs Accessibility."
    let fallback = "Your menu bar stays as macOS ordered it. You can still Command-drag items yourself."
    let dependencies: [ModuleDependency] = [.permission(.accessibility)]

    let service: MenuBarReorderService

    init(service: MenuBarReorderService) {
        self.service = service
    }

    func commands() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.restoreCommand,
                title: "Restore Menu Bar Order",
                keywords: ["status", "menu extra", "reorder", "original"],
                symbolName: "arrow.uturn.backward",
                unavailableReason: { [service] in service.unavailableReason },
                requiredPermissions: [.accessibility],
                handler: { [service] _ in
                    switch await service.restore() {
                    case .success: return .success(service.status)
                    case .failure(let failure): return .failure(failure)
                    }
                }
            ),
        ]
    }

    func start(_ context: ModuleContext) throws {
        service.activate()
        context.onStop { [service] in
            MainActor.assumeIsolated { service.deactivate() }
        }
    }
}
