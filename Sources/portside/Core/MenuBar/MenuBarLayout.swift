import AppKit
import OSLog

/// Where an item belongs (P2-MENU-05). Visible sits right of the shelf
/// separator, Hidden between the Always Hidden separator and the shelf
/// separator, Always Hidden left of the Always Hidden separator.
enum MenuBarSection: String, CaseIterable, Identifiable, Sendable {
    case visible, hidden, alwaysHidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visible: "Visible"
        case .hidden: "Hidden"
        case .alwaysHidden: "Always Hidden"
        }
    }

    var symbolName: String {
        switch self {
        case .visible: "eye"
        case .hidden: "eye.slash"
        case .alwaysHidden: "eye.trianglebadge.exclamationmark"
        }
    }
}

/// The horizontal extents of Portside's own separators, in screen points,
/// while both are collapsed.
struct MenuBarBars: Equatable, Sendable {
    var separator: ClosedRange<Double>
    /// Nil while Always Hidden is off.
    var alwaysHiddenSeparator: ClosedRange<Double>?
}

/// Saved item assignments, in Portside's own defaults. An item with no entry
/// has no saved choice and is treated as Visible. Entries survive turning the
/// module off and an owner restart (the key is bundle ID plus item key).
struct MenuBarLayoutStore {
    static let key = "menuBarLayout.assignments"
    /// Caps what a damaged defaults entry can cost.
    static let limit = 500

    let defaults: UserDefaults

    var assignments: [String: MenuBarSection] {
        guard let raw = defaults.dictionary(forKey: Self.key) as? [String: String] else { return [:] }
        var result: [String: MenuBarSection] = [:]
        for (id, value) in raw.prefix(Self.limit) {
            if let section = MenuBarSection(rawValue: value) { result[id] = section }
        }
        return result
    }

    func set(_ section: MenuBarSection, for id: String) {
        var raw = (defaults.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
        guard raw[id] != nil || raw.count < Self.limit else { return }
        raw[id] = section.rawValue
        defaults.set(raw, forKey: Self.key)
    }

    func forget(_ id: String) {
        var raw = (defaults.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
        raw[id] = nil
        defaults.set(raw, forKey: Self.key)
    }

    func reset() { defaults.removeObject(forKey: Self.key) }

    /// Item IDs and sections only; no titles, paths or app data.
    func exportJSON() -> String {
        let object: [String: Any] = ["version": 1, "assignments": assignments.mapValues(\.rawValue)]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Pure rules for sections and the moves between them.
enum MenuBarLayoutPlanner {
    enum Marker: Equatable, Sendable { case separator, alwaysHiddenSeparator }

    struct Move: Equatable, Sendable {
        let id: String
        let target: MenuBarSection
        let marker: Marker
        let side: MenuBarDropSide
    }

    /// The section an item sits in now, or nil if it overlaps a separator.
    static func section(of slot: MenuBarSlot, bars: MenuBarBars) -> MenuBarSection? {
        let x = (slot.minX + slot.maxX) / 2
        let first = bars.separator
        if x > first.upperBound { return .visible }
        if x >= first.lowerBound { return nil }
        guard let second = bars.alwaysHiddenSeparator else { return .hidden }
        if x > second.upperBound { return .hidden }
        if x >= second.lowerBound { return nil }
        return .alwaysHidden
    }

    /// With Always Hidden off, those items are held in Hidden. The saved
    /// choice is kept, so switching it on again moves them back.
    static func effective(_ saved: MenuBarSection?, alwaysHiddenOn: Bool) -> MenuBarSection {
        let section = saved ?? .visible
        return section == .alwaysHidden && !alwaysHiddenOn ? .hidden : section
    }

    static func move(to section: MenuBarSection, id: String) -> Move {
        switch section {
        case .visible: Move(id: id, target: section, marker: .separator, side: .after)
        case .hidden: Move(id: id, target: section, marker: .separator, side: .before)
        case .alwaysHidden: Move(id: id, target: section, marker: .alwaysHiddenSeparator, side: .before)
        }
    }

    /// Movable items that are not in the section they belong to, left to
    /// right. Items that cannot move are never listed.
    static func pending(slots: [(slot: MenuBarSlot, movable: Bool)], bars: MenuBarBars, saved: [String: MenuBarSection]) -> [Move] {
        let alwaysHiddenOn = bars.alwaysHiddenSeparator != nil
        return slots.compactMap { entry in
            guard entry.movable else { return nil }
            let want = effective(saved[entry.slot.id], alwaysHiddenOn: alwaysHiddenOn)
            guard let now = section(of: entry.slot, bars: bars), now != want else { return nil }
            return move(to: want, id: entry.slot.id)
        }
    }
}

/// What the layout needs from the shelf. The live one is `MenuBarShelf`.
@MainActor
protocol MenuBarLayoutBars: AnyObject {
    var isRunning: Bool { get }
    var alwaysHiddenEnabled: Bool { get }
    var onFailOpen: (@MainActor () -> Void)? { get set }
    func barFrames() -> MenuBarBars?
    func setAlwaysHidden(_ on: Bool)
    func openForLayout()
    func closeAfterLayout()
}

extension MenuBarShelf: MenuBarLayoutBars {}

/// What the Menu Bar Layout editor shows and does. Movement is MENU-04's:
/// every placement is one verified Cmd-drag from `MenuBarReorderService`, aimed
/// at a Portside separator, run one at a time. The shelf supplies the
/// separators and keeps its own recovery; this adds only the saved choices and
/// the order of drags. Nothing moves until Apply Layout or Reset to Native.
@MainActor
final class MenuBarLayoutService: ObservableObject {
    struct Row: Identifiable, Equatable {
        let slot: MenuBarSlot
        /// Whether Portside may move it at all, and why not.
        let support: MenuBarMoveSupport
        /// Why it can never be assigned (system item, no open action), nil if only
        /// its current position is the problem.
        let structural: String?
        let saved: MenuBarSection?
        /// Where it sits now, nil if unknown (no separators, or on a separator).
        let current: MenuBarSection?

        var id: String { slot.id }
        var canAssign: Bool { structural == nil }
        /// The section the editor lists it under.
        var section: MenuBarSection { saved ?? current ?? .visible }
    }

    enum Message {
        static let off = "Menu Bar Layout is turned off."
        static let busy = "A layout change is already running."
        static let denied = MenuBarReorderService.Message.denied
        static let noShelf = "Turn the Menu Bar Shelf on first. Sections need its separators."
        static let noBars = "The shelf separators are not visible or are out of order. Turn the shelf off and on to reset them, then try again."
    }

    struct ApplyReport: Equatable {
        var moved = 0
        var failure: String?
        /// Items still out of place that Portside will not move, with why.
        var stranded: [String] = []
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var missing: [String] = []
    @Published private(set) var status: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isActive = false
    @Published private(set) var alwaysHiddenOn = false
    @Published private(set) var barsReady = false
    /// Accessibility is denied or was revoked, so no items can be listed.
    @Published private(set) var accessDenied = false
    @Published private(set) var pendingCount = 0

    private let reorder: MenuBarReorderService
    private let shelf: MenuBarLayoutBars
    private let store: MenuBarLayoutStore
    private let settle: Duration
    private let osMajor: Int
    private let log = Logger(subsystem: "com.james.portside", category: "menubar-layout")

    init(
        reorder: MenuBarReorderService,
        shelf: MenuBarLayoutBars,
        defaults: UserDefaults = .standard,
        settle: Duration = MenuBarReorderService.settleDelay,
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) {
        self.reorder = reorder
        self.shelf = shelf
        self.store = MenuBarLayoutStore(defaults: defaults)
        self.settle = settle
        self.osMajor = osMajor
    }

    var unavailableReason: String? { isActive ? nil : Message.off }
    var exportedLayout: String { store.exportJSON() }

    func activate() {
        isActive = true
        shelf.onFailOpen = { [weak self] in self?.syncShelfState() }
    }

    /// Always Hidden goes back to collapsed so nothing stays clipped by a
    /// module that is off. Saved choices stay.
    func deactivate() {
        shelf.setAlwaysHidden(false)
        shelf.onFailOpen = nil
        isActive = false
        rows = []
        missing = []
        status = nil
        alwaysHiddenOn = false
        barsReady = false
        accessDenied = false
        pendingCount = 0
    }

    /// Lists every item the menu bar reports. Items the shelf is clipping
    /// have no usable position, so the shelf is shown first (a fail-open
    /// direction), like Apply Layout does.
    func refresh() async {
        guard isActive, !isBusy, !reorder.isBusy else { return }
        if shelf.isRunning {
            shelf.openForLayout()
            try? await Task.sleep(for: settle)
        }
        await reorder.refresh()
        rebuild()
    }

    func setAlwaysHidden(_ on: Bool) {
        guard isActive, shelf.isRunning else { return }
        shelf.setAlwaysHidden(on)
        syncShelfState()
        status = on ? "Always Hidden is on for this session. Apply Layout to move items into it." : "Always Hidden is off. Its items are held in Hidden."
        rebuild()
    }

    /// Saves the choice. Nothing moves until Apply Layout.
    func assign(_ id: String, to section: MenuBarSection) {
        guard isActive, let row = rows.first(where: { $0.id == id }) else { return }
        if let reason = row.structural {
            status = reason
            return
        }
        store.set(section, for: id)
        rebuild()
        status = pendingCount == 0 ? "Saved." : "Saved. Apply Layout to move \(pendingCount) item\(pendingCount == 1 ? "" : "s")."
    }

    func forget(_ id: String) {
        store.forget(id)
        rebuild()
    }

    /// Moves every movable item into its section, one verified drag at a time.
    /// Shows everything first (a fail-open direction) and leaves it shown.
    @discardableResult
    func apply() async -> Result<ApplyReport, CommandFailure> {
        if let reason = guardIdle() { return .failure(CommandFailure(reason: reason)) }
        isBusy = true
        defer { isBusy = false }
        let report = await applyLocked()
        if let reason = report.failure, report.moved == 0 { return fail(reason) }
        return .success(report)
    }

    /// Clears every saved choice and Always Hidden, brings each movable item
    /// right of the separator, then puts the MENU-04 saved order back. The
    /// shelf and Reorder stay on; turn the shelf off to remove its separators.
    @discardableResult
    func resetToNative() async -> Result<ApplyReport, CommandFailure> {
        if let reason = guardIdle() { return .failure(CommandFailure(reason: reason)) }
        isBusy = true
        defer { isBusy = false }
        store.reset()
        shelf.setAlwaysHidden(false)
        syncShelfState()
        var report = await applyLocked()
        if report.failure == nil, reorder.hasBaseline {
            switch await reorder.restore() {
            case .success(let restored): report.failure = restored.failure
            case .failure(let failure): report.failure = failure.reason
            }
        }
        if let reason = report.failure {
            status = "Reset stopped: \(reason)"
            if report.moved == 0 { return .failure(CommandFailure(reason: reason)) }
        } else {
            status = report.stranded.isEmpty ? "Menu bar layout reset." : "Reset. Not moved: \(report.stranded.joined(separator: " "))"
        }
        return .success(report)
    }

    // MARK: Internals

    private func guardIdle() -> String? {
        if !isActive { return Message.off }
        if isBusy || reorder.isBusy { return Message.busy }
        if !shelf.isRunning { return Message.noShelf }
        if !reorder.isActive { return MenuBarReorderService.Message.off }
        return nil
    }

    private func fail<T>(_ reason: String) -> Result<T, CommandFailure> {
        status = reason
        return .failure(CommandFailure(reason: reason))
    }

    private func syncShelfState() {
        alwaysHiddenOn = shelf.alwaysHiddenEnabled
        if isActive { rebuild() }
    }

    private func applyLocked() async -> ApplyReport {
        var report = ApplyReport()
        shelf.openForLayout()
        defer {
            shelf.closeAfterLayout()
            rebuild()
        }
        // The bar needs a moment to lay out after the separators collapse.
        try? await Task.sleep(for: settle)
        var budget = max(reorder.rows.count, 1) + 1
        while budget > 0 {
            budget -= 1
            await reorder.reload()
            guard !reorder.accessDenied else { report.failure = Message.denied; break }
            guard let bars = shelf.barFrames() else { report.failure = Message.noBars; break }
            let entries = reorder.rows.map { (slot: $0.slot, movable: $0.support.isMovable) }
            let moves = MenuBarLayoutPlanner.pending(slots: entries, bars: bars, saved: store.assignments)
            guard let next = moves.first, let slot = reorder.rows.first(where: { $0.id == next.id })?.slot else {
                report.stranded = strandedReasons(bars: bars)
                break
            }
            let shelf = shelf
            let marker: () -> ClosedRange<Double>? = {
                guard let now = shelf.barFrames() else { return nil }
                return next.marker == .separator ? now.separator : now.alwaysHiddenSeparator
            }
            if let reason = await reorder.place(slot, side: next.side, marker: marker) {
                report.failure = reason
                break
            }
            report.moved += 1
        }
        if report.failure == nil, budget == 0 { report.failure = "Stopped after the most moves it should need. Some items may be out of place." }
        status = describe(report)
        return report
    }

    private func describe(_ report: ApplyReport) -> String {
        if let reason = report.failure { return report.moved == 0 ? reason : "Stopped after \(report.moved) move\(report.moved == 1 ? "" : "s"): \(reason)" }
        var text = report.moved == 0 ? "Everything is already in its section." : "Moved \(report.moved) item\(report.moved == 1 ? "" : "s")."
        if !report.stranded.isEmpty { text += " Not moved: \(report.stranded.joined(separator: " "))" }
        return text
    }

    /// Items outside their section that Portside left alone, each with why.
    private func strandedReasons(bars: MenuBarBars) -> [String] {
        let saved = store.assignments
        let alwaysHiddenOn = bars.alwaysHiddenSeparator != nil
        return reorder.rows.compactMap { row in
            guard !row.support.isMovable, case .unsupported(let reason) = row.support,
                  let now = MenuBarLayoutPlanner.section(of: row.slot, bars: bars),
                  now != MenuBarLayoutPlanner.effective(saved[row.id], alwaysHiddenOn: alwaysHiddenOn) else { return nil }
            return "\(row.slot.item.displayTitle) (\(reason))"
        }
    }

    private func rebuild() {
        alwaysHiddenOn = shelf.alwaysHiddenEnabled
        accessDenied = reorder.accessDenied
        let bars = shelf.barFrames()
        barsReady = bars != nil
        let saved = store.assignments
        rows = reorder.rows.map { row in
            let probe = MenuBarSlot(item: row.slot.item, minX: row.slot.minX, maxX: row.slot.maxX, midY: row.slot.midY, reachable: true)
            var structural: String?
            if case .unsupported(let reason) = MenuBarLayoutRules.support(for: probe, osMajor: osMajor) { structural = reason }
            return Row(
                slot: row.slot, support: row.support, structural: structural, saved: saved[row.id],
                current: bars.flatMap { MenuBarLayoutPlanner.section(of: row.slot, bars: $0) }
            )
        }
        let present = Set(rows.map(\.id))
        missing = saved.keys.filter { !present.contains($0) }.sorted()
        if let bars {
            let entries = reorder.rows.map { (slot: $0.slot, movable: $0.support.isMovable) }
            pendingCount = MenuBarLayoutPlanner.pending(slots: entries, bars: bars, saved: saved).count
        } else {
            pendingCount = 0
        }
    }
}

/// The optional `menuBarLayout` module (P2-MENU-05). Off by default, held off
/// by restricted mode, needs Accessibility, and runs only while the Menu Bar
/// Shelf and Menu Bar Reorder are on, because it uses their separators and
/// their verified moves. Turning it off collapses Always Hidden.
@MainActor
final class MenuBarLayoutModule: PortsideModule {
    static let moduleID = ModuleID("menuBarLayout")!
    static let applyCommand = CommandID("menuBarLayout.apply")!
    static let resetCommand = CommandID("menuBarLayout.reset")!

    let id = MenuBarLayoutModule.moduleID
    let title = "Menu Bar Layout (experimental)"
    let summary = "Sorts menu bar items into Visible, Hidden and Always Hidden from Settings, using the Menu Bar Shelf's separators and Menu Bar Reorder's verified Command-drags. Your choice is remembered per item and applied when you press Apply Layout; the pointer moves for a moment. Items that cannot be moved reliably (system items, hidden or notch-clipped items) stay put, with the reason shown. Reset to Native undoes it. Needs Accessibility, the Menu Bar Shelf and Menu Bar Reorder."
    let fallback = "Your menu bar stays as it is. The shelf still hides everything left of its separator."
    let dependencies: [ModuleDependency] = [
        .permission(.accessibility), .module(MenuBarShelfModule.moduleID), .module(MenuBarReorderModule.moduleID),
    ]

    let service: MenuBarLayoutService

    init(service: MenuBarLayoutService) {
        self.service = service
    }

    func commands() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.applyCommand,
                title: "Apply Menu Bar Layout",
                keywords: ["sections", "hidden", "visible", "menu extra", "bartender"],
                symbolName: "rectangle.3.group",
                unavailableReason: { [service] in service.unavailableReason },
                requiredPermissions: [.accessibility],
                handler: { [service] _ in
                    switch await service.apply() {
                    case .success: return .success(service.status)
                    case .failure(let failure): return .failure(failure)
                    }
                }
            ),
            CommandDescriptor(
                id: Self.resetCommand,
                title: "Reset Menu Bar to Native",
                keywords: ["sections", "original", "restore", "menu extra"],
                symbolName: "arrow.uturn.backward.circle",
                unavailableReason: { [service] in service.unavailableReason },
                requiredPermissions: [.accessibility],
                handler: { [service] _ in
                    switch await service.resetToNative() {
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
