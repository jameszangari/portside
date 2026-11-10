import AppKit
import OSLog

/// Where an item belongs (P2-MENU-05). Visible sits right of the shelf
/// separator, Hidden between the Always Hidden separator and the shelf
/// separator, Always Hidden left of the Always Hidden separator.
enum MenuBarSection: String, CaseIterable, Identifiable, Sendable, Codable {
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

    func replaceAll(_ assignments: [String: MenuBarSection]) {
        defaults.set(assignments.mapValues(\.rawValue), forKey: Self.key)
    }

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
        section(centerX: (slot.minX + slot.maxX) / 2, bars: bars)
    }

    static func section(centerX x: Double, bars: MenuBarBars) -> MenuBarSection? {
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

/// A block a menu row can run; the row retains it.
final class MenuBarMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// Which profile a display set calls for. Pure.
enum MenuBarProfilePlan {
    static func match(profiles: [MenuBarProfile], displays: String, active: UUID?) -> UUID? {
        guard let found = profiles.first(where: { $0.displayKey == displays }), found.id != active else { return nil }
        return found.id
    }
}

/// Which item a Command-drag holds and where it ended up. Pure.
enum MenuBarDragRules {
    static func owner(atX x: CGFloat, items: [MenuBarDrawnOwners.Item]) -> pid_t? {
        items.first { $0.frame.width > 0 && x >= $0.frame.minX && x <= $0.frame.maxX }?.pid
    }

    /// An app's items land together or split. On a split the section that is
    /// not the saved one is where the dragged item went.
    static func landingSection(frames: [CGRect], bars: MenuBarBars, saved: MenuBarSection) -> MenuBarSection? {
        let sections = Set(frames.compactMap { MenuBarLayoutPlanner.section(centerX: $0.midX, bars: bars) })
        if sections.count == 1 { return sections.first }
        return sections.first { $0 != saved }
    }
}

/// What the layout needs from the shelf. The live one is `MenuBarShelf`.
@MainActor
protocol MenuBarLayoutBars: AnyObject {
    var isRunning: Bool { get }
    var alwaysHiddenEnabled: Bool { get }
    var mode: MenuBarShelf.Mode { get }
    var onFailOpen: (@MainActor () -> Void)? { get set }
    func barFrames() -> MenuBarBars?
    func setAlwaysHidden(_ on: Bool)
    func openForLayout()
    func closeAfterLayout()
    func hide()
    func reveal()
    func showAlwaysHidden()
    var alwaysHiddenShown: Bool { get }
    var hidesByMembership: Bool { get }
    func membershipDidChange()
}

extension MenuBarLayoutBars {
    var hidesByMembership: Bool { false }
    func membershipDidChange() {}
    func reveal() {}
    func showAlwaysHidden() {}
    var alwaysHiddenShown: Bool { false }
}

extension MenuBarShelf: MenuBarLayoutBars {}

/// What the Menu Bar Layout editor shows and does. Movement is MENU-04's:
/// every placement is one verified Cmd-drag from `MenuBarReorderService`, aimed
/// at a Portside separator, run one at a time. The shelf supplies the
/// separators and keeps its own recovery; this adds only the saved choices and
/// the order of drags. A drop in the editor moves its one item right away.
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
        /// Hiding follows the saved section, so position does not matter.
        var byMembership = false

        var id: String { slot.id }
        var canAssign: Bool { structural == nil }
        /// Shown in a section strip.
        var isListed: Bool { byMembership || slot.reachable }
        /// Where the editor draws it: where it really is, so a strip is
        /// never a promise. The saved choice only fills in when it straddles
        /// a separator.
        var section: MenuBarSection { current ?? saved ?? .visible }
        /// Off screen now, but would be movable if it were on screen.
        var isOffScreen: Bool { !isListed && structural == nil }
        var canDrag: Bool { canAssign && (byMembership || support.isMovable) }
        /// Why it cannot be dragged, nil if it can.
        var blockedReason: String? {
            if let structural { return structural }
            if !byMembership, case .unsupported(let reason) = support { return reason }
            return nil
        }
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
    var hidesByMembership: Bool { shelf.hidesByMembership }

    func menuBarOnlyNote(for row: Row) -> String? {
        guard hidesByMembership, row.section != .visible, arrangement.opensOnlyFromMenuBar(Self.bundle(of: row.id)) else { return nil }
        return "\(row.slot.item.displayTitle) opens only from the menu bar. Keep it in Visible to use it."
    }
    /// Why this copy of Portside cannot hide anything at all.
    var hidingBlockedReason: String? {
        hidesByMembership ? MenuBarAssertionPlan.locationProblem(bundlePath: Bundle.main.bundlePath) : nil
    }
    /// Accessibility is denied or was revoked, so no items can be listed.
    @Published private(set) var accessDenied = false
    @Published private(set) var pendingCount = 0
    /// Items you placed that are no longer where you put them.
    @Published private(set) var driftCount = 0
    /// Title of the item a drop is moving right now.
    @Published private(set) var movingTitle: String?
    /// The editor is on screen, so everything stays shown and rehide waits.
    private(set) var isEditing = false
    /// The shelf was closed when editing began, so it closes again after.
    private var hideWhenDone = false
    /// Saves the Always Hidden switch.
    var persistAlwaysHidden: ((Bool) -> Void)?
    /// Automatic puts saved order back before each reveal. Manual never moves
    /// anything on its own; a drop in the editor still moves what it names.
    var movesRealItems: () -> Bool = { true }
    /// MenuBarAgent's table once the file is granted, else order uses drags.
    var positionTable: MenuBarPositionStoring?
    /// Group icons follow this.
    var onGroupsChanged: () -> Void = {}
    var currentBundle = Bundle.main.bundleIdentifier ?? "com.james.portside"
    private let arrangement: MenuBarArrangementStore
    @Published private(set) var groups: [MenuBarGroup] = []
    @Published private(set) var profiles: [MenuBarProfile] = []
    @Published private(set) var activeProfileID: UUID?
    private var dragRestore: Task<Void, Never>?
    private var tableReload: Task<Void, Never>?
    var reloadDelay: Duration = .milliseconds(800)
    private var profileHotKeys: [HotKey] = []
    private var dragMonitor: Any?
    private var pressedBundle: String?
    private var dragRevealed = false
    private var adoptTask: Task<Void, Never>?
    private var hideAfterDrag = false

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
        self.arrangement = MenuBarArrangementStore(defaults: defaults)
        groups = arrangement.groups
        profiles = arrangement.profiles
        activeProfileID = arrangement.activeProfileID
        self.settle = settle
        self.osMajor = osMajor
    }

    var unavailableReason: String? { isActive ? nil : Message.off }
    var exportedLayout: String { store.exportJSON() }

    func activate() {
        isActive = true
        shelf.onFailOpen = { [weak self] in self?.syncShelfState() }
        if shelf.hidesByMembership { watchCommandDrags() }
        registerProfileHotKeys()
    }

    /// Always Hidden goes back to collapsed so nothing stays clipped by a
    /// module that is off. Saved choices stay.
    func deactivate() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        adoptTask?.cancel()
        dragRestore?.cancel()
        tableReload?.cancel()
        profileHotKeys = []
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
        driftCount = 0
        isEditing = false
        hideWhenDone = false
    }

    /// The editor appeared. Shows every item and keeps them shown, because a
    /// clipped item has no position to list or drag from.
    func beginEditing() async {
        guard isActive else { return }
        if !isEditing {
            isEditing = true
            hideWhenDone = shelf.mode == .hidden
        }
        await refresh()
    }

    /// The editor went away. Puts the shelf back how editing found it, after
    /// any drag still running.
    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        if !isBusy { finishEditing() }
    }

    private func finishEditing() {
        shelf.closeAfterLayout()
        if hideWhenDone {
            hideWhenDone = false
            shelf.hide()
        }
    }

    /// Lists every item the menu bar reports. Items the shelf is clipping
    /// have no usable position, so the shelf is shown first (a fail-open
    /// direction), like a move does. Hiding by membership lists them anyway,
    /// and looking at the editor must not open anything.
    func refresh() async {
        guard isActive, !isBusy, !reorder.isBusy else { return }
        if shelf.isRunning, !shelf.hidesByMembership {
            shelf.openForLayout()
            try? await Task.sleep(for: settle)
        }
        await reorder.refresh()
        rebuild()
    }

    func setAlwaysHidden(_ on: Bool) {
        guard isActive, shelf.isRunning else { return }
        shelf.setAlwaysHidden(on)
        persistAlwaysHidden?(on)
        syncShelfState()
        status = on ? "Always Hidden is on until Portside quits." : "Always Hidden is off. Its items moved to Hidden."
        rebuild()
        // Switching it on clips its side; the open editor still needs to see it.
        if on, isEditing { Task { await refresh() } }
    }

    /// Saves the choice without moving anything. The editor uses `drop`.
    func assign(_ id: String, to section: MenuBarSection) {
        guard isActive, let row = rows.first(where: { $0.id == id }) else { return }
        if let reason = row.structural {
            status = reason
            return
        }
        store.set(section, for: id)
        rebuild()
        status = "Saved."
    }

    func forget(_ id: String) {
        store.forget(id)
        rebuild()
    }

    /// A drop in the editor: one verified drag, right now. Lands just left of
    /// `beforeID`, or at the separator edge of `section` when there is none.
    /// The choice is saved only after the item is confirmed there, so a failed
    /// drag leaves the strip showing the truth. Dropping into Always Hidden
    /// turns that section on for this session.
    @discardableResult
    func drop(_ id: String, into section: MenuBarSection, before beforeID: String? = nil) async -> Result<Void, CommandFailure> {
        if let reason = guardIdle() { return fail(reason) }
        guard beforeID != id, let row = rows.first(where: { $0.id == id }) else { return .success(()) }
        if let reason = row.blockedReason { return fail(reason) }
        if shelf.hidesByMembership { return await dropByMembership(row, into: section, before: beforeID) }
        if beforeID == nil, row.current == section { return .success(()) }
        isBusy = true
        movingTitle = row.slot.item.displayTitle
        defer {
            isBusy = false
            movingTitle = nil
            if !isEditing { finishEditing() }
            rebuild()
        }
        if section == .alwaysHidden, !shelf.alwaysHiddenEnabled {
            shelf.setAlwaysHidden(true)
            syncShelfState()
        }
        shelf.openForLayout()
        // The bar needs a moment to lay out after the separators collapse.
        try? await Task.sleep(for: settle)
        await reorder.reload()
        if reorder.accessDenied { return fail(Message.denied) }
        guard let slot = reorder.rows.first(where: { $0.id == id && $0.support.isMovable })?.slot else {
            return fail(MenuBarReorderService.Message.stale)
        }
        let failure: String?
        if let beforeID {
            failure = await reorder.place(id, before: beforeID)
        } else {
            guard shelf.barFrames() != nil else { return fail(Message.noBars) }
            let move = MenuBarLayoutPlanner.move(to: section, id: id)
            failure = await reorder.place(slot, side: move.side, marker: marker(move.marker))
        }
        if let failure { return fail(failure) }
        store.set(section, for: id)
        status = "Moved \(slot.item.displayTitle) to \(section.title)."
        return .success(())
    }

    /// macOS hides by app, so an app's items always move together. No drag is
    /// needed to change section. A drop on an icon also moves the real item
    /// next to it, in Automatic only.
    private func dropByMembership(_ row: Row, into section: MenuBarSection, before beforeID: String?) async -> Result<Void, CommandFailure> {
        assignApp(of: row.id, to: section)
        if section == .alwaysHidden, !shelf.alwaysHiddenEnabled {
            shelf.setAlwaysHidden(true)
            persistAlwaysHidden?(true)
            syncShelfState()
        }
        let bundle = Self.bundle(of: row.id)
        recordOrder(bundle, in: section, before: beforeID.map(Self.bundle(of:)))
        shelf.membershipDidChange()
        rebuild()
        status = "Moved \(row.slot.item.displayTitle) to \(section.title)."
        guard !bundle.hasPrefix("apple.") else { return .success(()) }
        if writeOrderToTable() != nil { return .success(()) }
        guard let beforeID, !Self.bundle(of: beforeID).hasPrefix("apple."), !isBusy, !reorder.isBusy else { return .success(()) }
        isBusy = true
        movingTitle = row.slot.item.displayTitle
        defer {
            isBusy = false
            movingTitle = nil
            if !isEditing { finishEditing() }
            rebuild()
        }
        await reorder.reload()
        if let failure = await reorder.place(row.id, before: beforeID) { return fail(failure) }
        return .success(())
    }

    // MARK: Saved order

    /// Bundles left to right, per section.
    private func recordOrder(_ bundle: String, in section: MenuBarSection, before: String?) {
        var order = arrangement.order
        for key in MenuBarSection.allCases { order[key]?.removeAll { $0 == bundle } }
        var list = order[section] ?? members(of: section).filter { $0 != bundle }
        if let before, let index = list.firstIndex(of: before) {
            list.insert(bundle, at: index)
        } else if section == .visible {
            list.insert(bundle, at: 0)
        } else {
            list.append(bundle)
        }
        order[section] = list
        arrangement.order = order
    }

    /// Everything in a section, by saved assignment. Unassigned apps are Visible.
    private func members(of section: MenuBarSection) -> [String] {
        var bySection: [String: MenuBarSection] = [:]
        for row in rows where !Self.bundle(of: row.id).hasPrefix("apple.") { bySection[Self.bundle(of: row.id)] = row.saved ?? .visible }
        for (id, value) in store.assignments where !Self.bundle(of: id).hasPrefix("apple.") { bySection[Self.bundle(of: id)] = value }
        for bundle in arrangement.order[.visible] ?? [] where bySection[bundle] == nil { bySection[bundle] = .visible }
        return bySection.filter { $0.value == section && $0.key != currentBundle.lowercased() }.keys.sorted()
    }

    /// The whole bar left to right: Always Hidden, its divider, Hidden, the
    /// divider, Visible. Saved order first, the rest as they stand.
    func desiredOrder(table: [String: Int]) -> [String] {
        let saved = arrangement.order
        func ordered(_ section: MenuBarSection) -> [String] {
            let members = Set(self.members(of: section))
            let chosen = (saved[section] ?? []).filter { members.contains($0) }
            let rest = MenuBarOrderPlanner.observedOrder(table: table, members: members.subtracting(chosen))
            return chosen + rest
        }
        let prefix = "\(MenuBarOrderPlanner.prefix)\(currentBundle)::"
        var out = ordered(.alwaysHidden)
        if shelf.alwaysHiddenEnabled { out.append(prefix + StatusItemShelfSurface.alwaysHiddenName) }
        out += ordered(.hidden)
        out.append(prefix + StatusItemShelfSurface.separatorName)
        out += ordered(.visible)
        return out
    }

    /// Nil when there is no table to write. Otherwise whether it changed.
    @discardableResult
    private func writeOrderToTable() -> Bool? {
        guard let positionTable, let table = positionTable.read() else { return nil }
        let changes = MenuBarOrderPlanner.changes(table: table, desired: desiredOrder(table: table))
        guard !changes.isEmpty else { return false }
        guard positionTable.write(changes) else { return nil }
        scheduleTableReload()
        return true
    }

    /// Several edits in a row relaunch MenuBarAgent once.
    private func scheduleTableReload() {
        tableReload?.cancel()
        tableReload = Task { [weak self, reloadDelay] in
            try? await Task.sleep(for: reloadDelay)
            guard !Task.isCancelled else { return }
            self?.positionTable?.reload()
        }
    }

    /// Just before a reveal, so items appear in order. Cursor-free through the
    /// table. Without it, a Command-drag per drifted item once they are drawn.
    func restoreOrderBeforeReveal() {
        guard isActive, shelf.hidesByMembership, movesRealItems(), !isBusy, !reorder.isBusy, pressedBundle == nil else { return }
        if writeOrderToTable() != nil { return }
        guard !arrangement.order.isEmpty else { return }
        dragRestore?.cancel()
        dragRestore = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.restoreOrderByDragging()
        }
    }

    private func restoreOrderByDragging() async {
        guard !isBusy, !reorder.isBusy, pressedBundle == nil else { return }
        isBusy = true
        defer { isBusy = false }
        await reorder.reload()
        let movable = reorder.rows.filter(\.support.isMovable)
        let current = movable.map(\.id)
        var byBundle: [String: [String]] = [:]
        for id in current { byBundle[Self.bundle(of: id), default: []].append(id) }
        let bundles = desiredOrder(table: [:]).filter { !$0.hasPrefix(MenuBarOrderPlanner.prefix) }
        let steps = MenuBarLayoutRules.plan(current: current, desired: bundles.flatMap { byBundle[$0] ?? [] })
        // A big drift is not fixed by taking the pointer for this long.
        guard steps.count <= Self.maxOrderDrags else {
            status = "\(steps.count) items are out of order. Grant Layout Access to restore them without moving the pointer."
            return
        }
        for step in steps {
            await reorder.reload()
            if let failure = await reorder.place(step.id, before: step.before) {
                status = failure
                return
            }
        }
    }

    nonisolated static let maxOrderDrags = 8

    /// After a Command-drag: what the bar shows becomes the saved order.
    private func recordObservedOrder() {
        guard let table = positionTable?.read() else { return }
        var order = arrangement.order
        for section in MenuBarSection.allCases {
            order[section] = MenuBarOrderPlanner.observedOrder(table: table, members: Set(members(of: section)))
        }
        arrangement.order = order
    }

    // MARK: Groups

    private func saveGroups(_ next: [MenuBarGroup]) {
        arrangement.groups = next
        groups = next
        onGroupsChanged()
    }

    func addGroup(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveGroups(groups + [MenuBarGroup(name: trimmed)])
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveGroups(groups.map { var group = $0; if group.id == id { group.name = trimmed }; return group })
    }

    func removeGroup(_ id: UUID) { saveGroups(groups.filter { $0.id != id }) }

    func setGroupIcon(_ id: UUID, shown: Bool) {
        saveGroups(groups.map { var group = $0; if group.id == id { group.showsIcon = shown }; return group })
    }

    /// An app belongs to at most one group, so the bar lists it once.
    func setGroup(_ id: UUID?, forItem itemID: String) {
        let bundle = Self.bundle(of: itemID)
        saveGroups(groups.map { group in
            var next = group
            next.bundles.removeAll { $0 == bundle }
            if group.id == id { next.bundles.append(bundle) }
            return next
        })
    }

    func groupID(forItem itemID: String) -> UUID? {
        let bundle = Self.bundle(of: itemID)
        return groups.first { $0.bundles.contains(bundle) }?.id
    }

    // MARK: Profiles

    private func saveProfiles(_ next: [MenuBarProfile]) {
        arrangement.profiles = next
        profiles = next
        registerProfileHotKeys()
    }

    private func snapshot(into profile: inout MenuBarProfile) {
        profile.assignments = store.assignments.mapValues(\.rawValue)
        profile.order = Dictionary(uniqueKeysWithValues: arrangement.order.map { ($0.key.rawValue, $0.value) })
        profile.groups = groups
        profile.alwaysHidden = shelf.alwaysHiddenEnabled
    }

    @discardableResult
    func saveNewProfile(named name: String) -> MenuBarProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var profile = MenuBarProfile(name: trimmed)
        snapshot(into: &profile)
        saveProfiles(profiles + [profile])
        arrangement.activeProfileID = profile.id
        activeProfileID = profile.id
        return profile
    }

    func updateActiveProfile() {
        guard let activeProfileID else { return }
        saveProfiles(profiles.map { profile in
            guard profile.id == activeProfileID else { return profile }
            var next = profile
            snapshot(into: &next)
            return next
        })
        status = "Profile saved."
    }

    func deleteProfile(_ id: UUID) {
        saveProfiles(profiles.filter { $0.id != id })
        if activeProfileID == id {
            activeProfileID = nil
            arrangement.activeProfileID = nil
        }
    }

    func setProfileHotkey(_ id: UUID, chord: HotkeyChord?) {
        saveProfiles(profiles.map { var profile = $0; if profile.id == id { profile.hotkey = chord }; return profile })
    }

    /// Follows the displays connected right now.
    func setProfileMatchesDisplays(_ id: UUID, matches: Bool) {
        let key = matches ? MenuBarDisplaySet.current : nil
        saveProfiles(profiles.map { profile in
            var next = profile
            if profile.id == id { next.displayKey = key } else if matches, profile.displayKey == key { next.displayKey = nil }
            return next
        })
    }

    func applyProfile(_ id: UUID) {
        guard isActive, let profile = profiles.first(where: { $0.id == id }) else { return }
        store.replaceAll(profile.assignments.compactMapValues(MenuBarSection.init(rawValue:)))
        var order: [MenuBarSection: [String]] = [:]
        for (key, value) in profile.order { if let section = MenuBarSection(rawValue: key) { order[section] = value } }
        arrangement.order = order
        arrangement.activeProfileID = id
        activeProfileID = id
        saveGroups(profile.groups)
        if shelf.alwaysHiddenEnabled != profile.alwaysHidden {
            shelf.setAlwaysHidden(profile.alwaysHidden)
            persistAlwaysHidden?(profile.alwaysHidden)
            syncShelfState()
        }
        shelf.membershipDidChange()
        writeOrderToTable()
        rebuild()
        status = "Using profile \(profile.name)."
    }

    /// A display was attached or removed.
    func displaysChanged() {
        let current = MenuBarDisplaySet.current
        guard let match = MenuBarProfilePlan.match(profiles: profiles, displays: current, active: activeProfileID) else { return }
        applyProfile(match)
    }

    private func registerProfileHotKeys() {
        guard isActive else { return }
        profileHotKeys = profiles.compactMap { profile in
            guard let chord = profile.hotkey else { return nil }
            return HotKey(chord: chord, name: "Menu bar profile \(chord.displayString)") { [weak self, id = profile.id] in
                MainActor.assumeIsolated { self?.applyProfile(id) }
            }
        }
    }

    /// Rows for the control's menu.
    func profileMenuItems() -> [NSMenuItem] {
        guard !profiles.isEmpty else { return [] }
        let parent = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for profile in profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(MenuBarMenuAction.run), keyEquivalent: "")
            let action = MenuBarMenuAction { [weak self, id = profile.id] in self?.applyProfile(id) }
            item.target = action
            item.representedObject = action
            item.state = profile.id == activeProfileID ? .on : .off
            menu.addItem(item)
        }
        parent.submenu = menu
        return [parent]
    }

    /// Every listed item of the same app, and at least the one given.
    private func assignApp(of id: String, to section: MenuBarSection) {
        let bundle = Self.bundle(of: id)
        var ids = Set(rows.filter { Self.bundle(of: $0.id) == bundle }.map(\.id))
        ids.formUnion(store.assignments.keys.filter { Self.bundle(of: $0) == bundle })
        ids.insert(id)
        for one in ids { store.set(section, for: one) }
    }

    nonisolated static func bundle(of id: String) -> String {
        id.split(separator: ":", maxSplits: 1).first.map { String($0).lowercased() } ?? id
    }

    /// Saves a section for a bundle that has no listed row yet.
    func assignBundle(_ bundle: String, to section: MenuBarSection) {
        store.set(section, for: "\(bundle):#0")
        if isActive { rebuild() }
    }

    // MARK: Command-drag on the menu bar

    /// How long macOS takes to settle positions after a drop.
    nonisolated static let dragSettle: Duration = .milliseconds(1500)

    private func watchCommandDrags() {
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type
            let command = event.modifierFlags.contains(.command)
            MainActor.assumeIsolated {
                switch type {
                case .leftMouseDown: self?.commandPress(command: command)
                case .leftMouseDragged: self?.commandDragged()
                default: self?.commandRelease()
                }
            }
        }
    }

    /// A Command-press on another app's item. The owner comes from the bar's
    /// own list, because a hit test can answer with MenuBarAgent.
    private func commandPress(command: Bool) {
        pressedBundle = nil
        dragRevealed = false
        dragRestore?.cancel()
        guard command, !isBusy, !reorder.isBusy else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }), point.y >= screen.visibleFrame.maxY else { return }
        guard let items = MenuBarDrawnOwners.items(), let owner = MenuBarDragRules.owner(atX: point.x, items: items),
              owner != getpid(),
              let bundle = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier?.lowercased(),
              !bundle.hasPrefix("com.apple.") else { return }
        pressedBundle = bundle
    }

    /// Opens every section once the item really moves, so it can be dropped into any of them.
    private func commandDragged() {
        guard pressedBundle != nil, !dragRevealed else { return }
        dragRevealed = true
        hideAfterDrag = shelf.mode == .hidden
        if shelf.alwaysHiddenEnabled {
            shelf.showAlwaysHidden()
        } else if shelf.mode == .hidden {
            shelf.reveal()
        }
    }

    private func commandRelease() {
        guard let bundle = pressedBundle else { return }
        pressedBundle = nil
        guard dragRevealed else { return }
        dragRevealed = false
        adoptTask?.cancel()
        adoptTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dragSettle)
            guard !Task.isCancelled else { return }
            await self?.adoptDrag(of: bundle)
        }
    }

    /// Reads where the item landed against the dividers and adopts that
    /// section. Moves nothing.
    private func adoptDrag(of bundle: String) async {
        defer {
            if shelf.alwaysHiddenShown, !isEditing { shelf.closeAfterLayout() }
            if hideAfterDrag, !isEditing {
                hideAfterDrag = false
                shelf.hide()
            }
        }
        guard let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier?.lowercased() == bundle })?.processIdentifier,
              let bars = shelf.barFrames() else { return }
        let items = await Task.detached(priority: .utility) { MenuBarDrawnOwners.items() }.value
        let frames = items?.filter { $0.pid == pid }.map(\.frame) ?? []
        let saved = store.assignments.first { Self.bundle(of: $0.key) == bundle }?.value ?? .visible
        guard let section = MenuBarDragRules.landingSection(frames: frames, bars: bars, saved: saved), section != saved else {
            recordObservedOrder()
            return
        }
        let ids = rows.filter { Self.bundle(of: $0.id) == bundle }.map(\.id)
        let storedIDs = store.assignments.keys.filter { Self.bundle(of: $0) == bundle }
        for id in Set(ids).union(storedIDs) { store.set(section, for: id) }
        if ids.isEmpty && storedIDs.isEmpty { store.set(section, for: "\(bundle):#0") }
        recordObservedOrder()
        shelf.membershipDidChange()
        if isActive { rebuild() }
    }

    private func marker(_ marker: MenuBarLayoutPlanner.Marker) -> () -> ClosedRange<Double>? {
        let shelf = shelf
        return {
            guard let now = shelf.barFrames() else { return nil }
            return marker == .separator ? now.separator : now.alwaysHiddenSeparator
        }
    }

    /// Moves movable items into their sections, one verified drag at a time.
    /// Shows everything first (a fail-open direction) and leaves it shown.
    /// `onlySaved` leaves alone items you never placed.
    @discardableResult
    func apply(onlySaved: Bool = false) async -> Result<ApplyReport, CommandFailure> {
        if let reason = guardIdle() { return .failure(CommandFailure(reason: reason)) }
        if shelf.hidesByMembership {
            shelf.membershipDidChange()
            return .success(ApplyReport())
        }
        isBusy = true
        defer { isBusy = false }
        let report = await applyLocked(onlySaved: onlySaved)
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
        arrangement.order = [:]
        if shelf.hidesByMembership, positionTable?.restoreBackup() == true { scheduleTableReload() }
        shelf.setAlwaysHidden(false)
        persistAlwaysHidden?(false)
        syncShelfState()
        shelf.membershipDidChange()
        var report = shelf.hidesByMembership ? ApplyReport() : await applyLocked()
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

    private func applyLocked(onlySaved: Bool = false) async -> ApplyReport {
        var report = ApplyReport()
        shelf.openForLayout()
        defer {
            if !isEditing { finishEditing() }
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
            let saved = store.assignments
            let entries = reorder.rows
                .filter { !onlySaved || saved[$0.id] != nil }
                .map { (slot: $0.slot, movable: $0.support.isMovable) }
            let moves = MenuBarLayoutPlanner.pending(slots: entries, bars: bars, saved: saved)
            guard let next = moves.first, let slot = reorder.rows.first(where: { $0.id == next.id })?.slot else {
                report.stranded = strandedReasons(bars: bars)
                break
            }
            if let reason = await reorder.place(slot, side: next.side, marker: marker(next.marker)) {
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
        groups = arrangement.groups
        rows = reorder.rows.map { row in
            let probe = MenuBarSlot(item: row.slot.item, minX: row.slot.minX, maxX: row.slot.maxX, midY: row.slot.midY, reachable: true)
            var structural: String?
            if case .unsupported(let reason) = MenuBarLayoutRules.support(for: probe, osMajor: osMajor) { structural = reason }
            if shelf.hidesByMembership {
                return Row(slot: row.slot, support: row.support, structural: structural, saved: saved[row.id], current: saved[row.id], byMembership: true)
            }
            return Row(
                slot: row.slot, support: row.support, structural: structural, saved: saved[row.id],
                current: bars.flatMap { MenuBarLayoutPlanner.section(of: row.slot, bars: $0) }
            )
        }
        if shelf.hidesByMembership {
            for apple in MenuBarAssertionPlan.appleItems {
                let item = MenuBarItem(pid: 0, ownerBundleID: apple.bundle, ownerName: apple.title, ordinal: 0, identifier: nil, title: apple.title, canPress: false)
                let slot = MenuBarSlot(item: item, minX: 0, maxX: 0, midY: 0, reachable: true)
                rows.append(Row(slot: slot, support: .movable, structural: nil, saved: saved[slot.id], current: saved[slot.id], byMembership: true))
            }
        }
        let present = Set(rows.map(\.id))
        missing = saved.keys.filter { !present.contains($0) }.sorted()
        if let bars, !shelf.hidesByMembership {
            let entries = reorder.rows.map { (slot: $0.slot, movable: $0.support.isMovable) }
            pendingCount = MenuBarLayoutPlanner.pending(slots: entries, bars: bars, saved: saved).count
            driftCount = MenuBarLayoutPlanner.pending(slots: entries.filter { saved[$0.slot.id] != nil }, bars: bars, saved: saved).count
        } else {
            pendingCount = 0
            driftCount = 0
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
    let summary = "Sorts menu bar items into Visible, Hidden and Always Hidden from Settings, using the Menu Bar Shelf's separators and Menu Bar Reorder's verified Command-drags. Drag an item in Settings and it moves right away; the pointer moves for a moment. Items that cannot be moved reliably (system items, hidden or notch-clipped items) stay put, with the reason shown. Reset to Native undoes it. Needs Accessibility, the Menu Bar Shelf and Menu Bar Reorder."
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
        let screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [service] _ in
            MainActor.assumeIsolated { service.displaysChanged() }
        }
        context.onStop { [service] in
            NotificationCenter.default.removeObserver(screens)
            MainActor.assumeIsolated { service.deactivate() }
        }
    }
}
