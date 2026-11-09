import AppKit
import OSLog

/// Menu bar items for Command Center (P2-MENU-02, per the REA-03 report):
/// search what other apps expose through Accessibility and press one when a
/// person picks its row, with one click at the item (see `AXMenuBarItemSource`).
/// Read-only otherwise: nothing is moved, hidden or reordered, no position
/// is shown, and no preference of another app is touched. Listing happens when Command Center opens (at most every 10 s);
/// a press re-reads the owner and refuses an element that changed.
@MainActor
final class MenuBarItemsService {
    enum Message {
        static let off = "Menu bar items are turned off."
        static let gone = "That menu bar item is no longer listed."
        static let denied = "Accessibility permission is denied or was revoked."
        static let stale = "That menu bar item changed or its app quit. Search again."
        static let unsupported = "That item cannot be opened from here. Use the menu bar."
        static let hidden = "That item is hidden or covered, so Portside cannot open it. Show it in your menu bar manager, or open it from the menu bar."
    }

    nonisolated static let refreshInterval: TimeInterval = 10
    /// Wait between the command finishing and the press, so Command Center's
    /// panel is gone and focus is back before the menu opens.
    nonisolated static let pressDelay: Duration = .milliseconds(200)

    private(set) var items: [MenuBarItem] = []
    private(set) var isActive = false
    /// Last sweep: apps that did not answer in time, and items listed only as groups.
    private(set) var skippedApps = 0
    private(set) var unsupportedCount = 0
    /// Accessibility was denied at the last sweep. Distinct from an empty list.
    private(set) var accessDenied = false
    private var loading = false
    private var lastRefresh: Date?
    private var generation = 0
    private let source: MenuBarItemSource
    private let pressDelay: Duration
    private let report: @MainActor (String) -> Void
    private let log = Logger(subsystem: "com.james.portside", category: "menubar")

    /// `report` runs when the delayed press fails, after the panel is gone;
    /// the default beeps and logs the reason.
    nonisolated init(
        source: MenuBarItemSource = AXMenuBarItemSource.live,
        pressDelay: Duration = MenuBarItemsService.pressDelay,
        report: @escaping @MainActor (String) -> Void = { _ in NSSound.beep() }
    ) {
        self.source = source
        self.pressDelay = pressDelay
        self.report = report
    }

    var unavailableReason: String? { isActive ? nil : Message.off }

    /// What Command Center lists: only items that can be pressed.
    var rows: [MenuBarItem] { isActive && !accessDenied ? items.filter(\.canPress) : [] }

    func activate() { isActive = true }

    func deactivate() {
        isActive = false
        generation += 1
        items = []
        skippedApps = 0
        unsupportedCount = 0
        accessDenied = false
        lastRefresh = nil
        loading = false
    }

    /// Background sweep; `changed` runs when the list differs. Skipped while
    /// one runs, within the interval, or when off.
    func refresh(now: Date = Date(), changed: @escaping @MainActor () -> Void) {
        guard isActive, !loading else { return }
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.refreshInterval { return }
        loading = true
        generation += 1
        let mine = generation
        let source = source
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) { source.snapshot() }.value
            self?.finish(snapshot, generation: mine, now: now, changed: changed)
        }
    }

    private func finish(_ snapshot: MenuBarSnapshot, generation mine: Int, now: Date, changed: @MainActor () -> Void) {
        guard mine == generation, isActive else { return }
        loading = false
        lastRefresh = now
        skippedApps = snapshot.skippedApps
        unsupportedCount = snapshot.unsupportedCount
        let denied = snapshot.access == .accessibilityDenied
        guard snapshot.items != items || denied != accessDenied else { return }
        items = snapshot.items
        accessDenied = denied
        changed()
    }

    /// Checks one listed item now, then presses it after `pressDelay`, once
    /// the panel that ran this command has gone. The result is "accepted":
    /// the press itself can still find the item changed or the app gone, and
    /// then reports through `report` (the panel is closed by then).
    func press(_ key: String) async -> Result<String?, CommandFailure> {
        if let reason = unavailableReason { return .failure(CommandFailure(reason: reason)) }
        guard let item = items.first(where: { $0.id == key }) else { return .failure(CommandFailure(reason: Message.gone)) }
        guard item.canPress else { return .failure(CommandFailure(reason: Message.unsupported)) }
        // Checked now, while the panel is still up, so a refusal shows in it.
        let probe = source
        guard await Task.detached(priority: .userInitiated, operation: { probe.isReachable(item) }).value else {
            lastRefresh = nil
            return .failure(CommandFailure(reason: Message.hidden))
        }
        let source = source
        Task { [weak self, pressDelay] in
            try? await Task.sleep(for: pressDelay)
            let outcome = await Task.detached(priority: .userInitiated) { source.press(item) }.value
            self?.finishPress(outcome, item: item)
        }
        return .success(nil)
    }

    private func finishPress(_ outcome: MenuBarPressOutcome, item: MenuBarItem) {
        guard let reason = Self.failure(outcome, item: item) else { return }
        if outcome == .stale { lastRefresh = nil }
        log.error("menu bar press failed: \(reason, privacy: .public)")
        report(reason)
    }

    nonisolated static func failure(_ outcome: MenuBarPressOutcome, item: MenuBarItem) -> String? {
        switch outcome {
        case .pressed: return nil
        case .stale: return Message.stale
        case .unsupported: return Message.unsupported
        case .denied: return Message.denied
        case .hidden: return Message.hidden
        case .failed(let code): return "\(item.displayTitle) did not respond (Accessibility error \(code))."
        }
    }
}

/// The optional `menuBar` module. Off by default and held off by restricted
/// mode. It needs Accessibility (Settings > Command Center > Search sources), asked for only by
/// that button, never at launch. Without it Command Center works unchanged.
@MainActor
final class MenuBarModule: PortsideModule {
    static let moduleID = ModuleID("menuBar")!
    static let pressCommand = CommandID("menuBar.press")!

    let id = MenuBarModule.moduleID
    let title = "Menu Bar Items"
    let summary = "Lists the menu bar items other apps expose in Command Center and opens one when you pick it (Return). Opening clicks the item for you, so the pointer moves there and back for a moment. It only searches and opens: it never moves, hides or reorders items, and shows no positions. Items that do not offer an open action stay in the menu bar. Needs Accessibility."
    let fallback = "Command Center and the dock work the same without it; menu bar items open from the menu bar as before."
    let dependencies: [ModuleDependency] = [.module(CommandCenterModule.moduleID), .permission(.accessibility)]

    let service: MenuBarItemsService

    init(service: MenuBarItemsService) {
        self.service = service
    }

    func commands() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                id: Self.pressCommand,
                title: "Open Menu Bar Item",
                keywords: ["status", "menu extra"],
                symbolName: "menubar.rectangle",
                input: .string(maxLength: 300),
                unavailableReason: { [service] in service.unavailableReason },
                requiredPermissions: [.accessibility],
                handler: { [service] input in
                    // The key of a listed item, never typed text.
                    guard case .string(let key) = input else { return .failure(CommandFailure(reason: "No menu bar item given.")) }
                    return await service.press(key)
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
