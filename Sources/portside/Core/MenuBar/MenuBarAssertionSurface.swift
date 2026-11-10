import AppKit
import ApplicationServices
import notify
import OSLog

/// Which bundles to hide and what the allow-list holds. Pure.
enum MenuBarAssertionPlan {
    /// Verified on macOS 27.0.1: 0 battery, 1 bluetooth, 2 clock, 5 sound,
    /// 6 wifi, 8 controlcenter. Other codes (3, 4, 7, 9 and up) exposed
    /// nothing on the test bar. A verified subset, not the full list.
    static let systemItems = [0, 1, 2, 5, 6, 8]
    /// Apple's own items, by the section-map bundle name Layout gives them.
    static let appleItems: [(bundle: String, code: Int, title: String, symbol: String)] = [
        ("apple.battery", 0, "Battery", "battery.100"),
        ("apple.bluetooth", 1, "Bluetooth", "wave.3.right"),
        ("apple.clock", 2, "Clock", "clock"),
        ("apple.sound", 5, "Sound", "speaker.wave.2"),
        ("apple.wifi", 6, "Wi-Fi", "wifi"),
        ("apple.controlcenter", 8, "Control Center", "switch.2"),
    ]
    /// Menu bar managers that hide items themselves. Two holders union their
    /// allow-lists, so neither would hide what it means to.
    static let otherManagers: Set<String> = ["com.stonerl.thaw", "com.jordanbaird.ice", "com.surteesstudios.bartender", "com.dwarvesv.minimalbar"]

    static func conflictingManager(running: [String]) -> String? {
        running.first { otherManagers.contains($0.lowercased()) }
    }

    /// macOS 27 only treats a status item as the app's own when the app is in
    /// /Applications. From anywhere else any hide also takes Portside's icon.
    static func locationProblem(bundlePath: String) -> String? {
        bundlePath.hasPrefix("/Applications/") ? nil
            : "macOS only keeps Portside's own icon while hiding when Portside is in /Applications. Install it there to hide items."
    }

    /// Owners that must stay allowed: Apple's own extras and SystemUIServer.
    static let alwaysAllowed = ["com.apple.MenuBarAgent", "com.apple.systemuiserver"]

    /// Bundles whose every assigned item is in `sections`. macOS hides by app,
    /// so an app with one item left Visible stays visible. Apple's own and
    /// unidentified owners are never hidden.
    static func hiddenBundles(assignments: [String: MenuBarSection], sections: Set<MenuBarSection>) -> Set<String> {
        var byBundle: [String: [MenuBarSection]] = [:]
        for (id, section) in assignments {
            guard let bundle = id.split(separator: ":", maxSplits: 1).first.map({ String($0).lowercased() }),
                  !bundle.hasPrefix("pid"), !bundle.hasPrefix("com.apple.") else { continue }
            byBundle[bundle, default: []].append(section)
        }
        return Set(byBundle.filter { $0.value.allSatisfy(sections.contains) }.keys)
    }

    /// Every running bundle that is not hidden, plus Apple's owners and
    /// Portside itself, in a fixed order so equal inputs compare equal.
    static func config(running: [String], hidden: Set<String>, portside: String) -> MenuBarAssertionConfig {
        var allowed = Set(running.filter { !hidden.contains($0.lowercased()) })
        allowed.formUnion(alwaysAllowed)
        allowed.insert(portside)
        let codes = appleItems.filter { !hidden.contains($0.bundle) }.map(\.code)
        return MenuBarAssertionConfig(systemItems: codes, bundleIdentifiers: allowed.sorted())
    }
}

/// Holds the assertion and moves it toward the latest intent. An assertion
/// cannot be updated in place, so a change replaces it. While hiding, the old
/// one is released only after the new one is confirmed: live assertions union
/// their allow-lists, so nothing hidden flashes back during the swap. A request
/// that arrives while an activation is pending is held and the latest one wins
/// when it lands. Reveal is immediate and cancels everything.
@MainActor
final class MenuBarAssertionController {
    private let bridge: MenuBarAssertionBridge
    private let activationTimeout: Duration
    private let verifyDelay: Duration
    /// Nil when Portside's own icon is confirmed drawn, else why not.
    private let verifyControl: @MainActor () async -> String?
    private var handle: MenuBarAssertionHandle?
    /// The confirmed assertion a pending replacement will take over from.
    private var outgoing: MenuBarAssertionHandle?
    /// What the live or pending assertion carries.
    private(set) var applied: MenuBarAssertionConfig?
    /// The latest intent. Nil means revealed.
    private var wanted: MenuBarAssertionConfig?
    private(set) var isActivating = false
    private var generation = 0
    private var timer: Task<Void, Never>?
    private let log = Logger(subsystem: "com.james.portside", category: "menubar-assertion")
    /// Called after the assertion has been released because hiding failed.
    var onFailure: (@MainActor (String) -> Void)?

    init(
        bridge: MenuBarAssertionBridge,
        activationTimeout: Duration = .seconds(3),
        verifyDelay: Duration = .milliseconds(1500),
        verifyControl: @escaping @MainActor () async -> String?
    ) {
        self.bridge = bridge
        self.activationTimeout = activationTimeout
        self.verifyDelay = verifyDelay
        self.verifyControl = verifyControl
    }

    var isHolding: Bool { handle != nil }

    /// Nil reveals. `force` replaces even an identical assertion, for a
    /// restarted MenuBarAgent that may have dropped it.
    func request(_ config: MenuBarAssertionConfig?, force: Bool = false) {
        wanted = config
        guard let config else {
            release()
            return
        }
        if isActivating { return }
        if !force, applied == config, handle != nil { return }
        start(config)
    }

    /// Releases at once, even while an activation is pending.
    func release() {
        wanted = nil
        generation += 1
        isActivating = false
        timer?.cancel()
        timer = nil
        applied = nil
        let old = handle
        handle = nil
        old?.invalidate()
        let previous = outgoing
        outgoing = nil
        previous?.invalidate()
    }

    private func start(_ config: MenuBarAssertionConfig) {
        if let reason = bridge.unavailableReason {
            fail(reason)
            return
        }
        // Keep the confirmed one until this one lands.
        if let current = handle {
            outgoing?.invalidate()
            outgoing = current
            handle = nil
        }
        generation += 1
        let mine = generation
        isActivating = true
        applied = config
        guard let started = bridge.activate(config, completion: { [weak self] error in self?.completed(mine, error: error) }) else {
            fail("The menu bar assertion could not be created.")
            return
        }
        handle = started
        timer?.cancel()
        timer = Task { [weak self, activationTimeout] in
            try? await Task.sleep(for: activationTimeout)
            guard !Task.isCancelled else { return }
            self?.timedOut(mine)
        }
    }

    private func completed(_ mine: Int, error: String?) {
        guard mine == generation, isActivating else { return }
        isActivating = false
        timer?.cancel()
        timer = nil
        if let error {
            fail("macOS refused the hide: \(error)")
            return
        }
        let previous = outgoing
        outgoing = nil
        previous?.invalidate()
        if let wanted, wanted != applied {
            start(wanted)
            return
        }
        scheduleVerify(mine)
    }

    private func timedOut(_ mine: Int) {
        guard mine == generation, isActivating else { return }
        fail("macOS did not answer the hide request.")
    }

    /// After the bar has settled, confirms Portside's own icon is still drawn.
    /// A miss gets one more look half a delay later, so a bar caught mid-change
    /// does not undo a good hide.
    private func scheduleVerify(_ mine: Int) {
        timer?.cancel()
        timer = Task { [weak self, verifyDelay] in
            try? await Task.sleep(for: verifyDelay)
            guard !Task.isCancelled, let self, self.stillCurrent(mine) else { return }
            let first = await self.verifyControl()
            guard !Task.isCancelled, self.stillCurrent(mine), first != nil else { return }
            try? await Task.sleep(for: verifyDelay / 2)
            guard !Task.isCancelled, self.stillCurrent(mine) else { return }
            let second = await self.verifyControl()
            guard !Task.isCancelled, self.stillCurrent(mine) else { return }
            if let reason = second { self.fail(reason) }
        }
    }

    /// Runs the own-icon check again on the live assertion.
    func reverify() {
        guard handle != nil, !isActivating else { return }
        scheduleVerify(generation)
    }

    private func stillCurrent(_ mine: Int) -> Bool { mine == generation && handle != nil && !isActivating }

    private func fail(_ reason: String) {
        log.error("hide failed: \(reason, privacy: .public)")
        release()
        onFailure?(reason)
    }
}

/// The assertion-backed surface (macOS 27). The control item and dividers are
/// the existing status items; dividers only mark where sections begin. Hiding
/// means holding an assertion that allows every running app except those
/// assigned to Hidden. Membership is read from the saved layout assignments.
@MainActor
final class AssertionShelfSurface: MenuBarShelfSurface {
    /// How long a hidden app stays out after being opened from the panel.
    /// How long a brand-new app gets to put its icon on the bar.
    nonisolated static let newIconWait: Duration = .milliseconds(2500)

    private let base: MenuBarShelfSurface
    private let controller: MenuBarAssertionController
    private let assignments: () -> [String: MenuBarSection]
    private let assign: (String, MenuBarSection) -> Void
    private let newItemsSection: () -> MenuBarSection
    private let runningBundles: () -> [String]
    private let drawnOwners: () async -> Set<pid_t>?
    private let overflowAllowed: () -> Bool
    private let presentation: () -> MenuBarPresentation
    private let barLocation: () -> MenuBarBarLocation
    private let barLook: () -> MenuBarOverflowPanel.Look
    private let emptyClickToggles: () -> Bool
    private let dismissBar: () -> Void
    private let itemSnapshot: () async -> MenuBarSnapshot
    private let portsideBundle: String
    private let bundlePath: String
    private let launchDebounce: Duration
    private var hidden = false
    private var installed = false
    private var alwaysHiddenClipped = false
    private var observers: [NSObjectProtocol] = []
    private var launchTask: Task<Void, Never>?
    private var hookTokens: [Int32] = []
    private let onToggle: () -> Void
    private let turnOff: () -> Void
    private let developerHooks: Bool
    private var explainedLocation = false
    /// The shelf reads as open while its items stay hidden and show in the bar.
    private var barOpen = false
    private var failingOpen = false
    private let panel = MenuBarOverflowPanel()
    private var panelTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var groupItems: [UUID: NSStatusItem] = [:]
    private var groupTargets: [UUID: GroupIconTarget] = [:]
    private let store: MenuBarArrangementStore
    private let method: () -> MenuBarHidingMethod
    private let nativeHider: MenuBarNativeHider?
    private let watchInterval: Duration
    var failureHandler: (@MainActor (String) -> Void)?

    var hidesByMembership: Bool { true }
    var hasHiddenAssignments: Bool {
        MenuBarAssertionPlan.locationProblem(bundlePath: bundlePath) == nil
            && !MenuBarAssertionPlan.hiddenBundles(assignments: assignments(), sections: [.hidden, .alwaysHidden]).isEmpty
    }

    /// A display or wake event: look again that Portside's icon survived.
    func revalidate() { controller.reverify() }

    func membershipDidChange() { refresh() }

    init(
        base: MenuBarShelfSurface,
        bridge: MenuBarAssertionBridge,
        assignments: @escaping () -> [String: MenuBarSection],
        assign: @escaping (String, MenuBarSection) -> Void = { _, _ in },
        newItemsSection: @escaping () -> MenuBarSection = { .visible },
        runningBundles: @escaping () -> [String] = { NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) },
        portsideBundle: String = Bundle.main.bundleIdentifier ?? "com.james.portside",
        bundlePath: String = Bundle.main.bundlePath,
        drawnOwners: @escaping () async -> Set<pid_t>? = { await MenuBarDrawnOwners.read() },
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        overflowAllowed: @escaping () -> Bool = { false },
        presentation: @escaping () -> MenuBarPresentation = { .menuBar },
        barLocation: @escaping () -> MenuBarBarLocation = { .dynamic },
        barLook: @escaping () -> MenuBarOverflowPanel.Look = { MenuBarOverflowPanel.Look() },
        emptyClickToggles: @escaping () -> Bool = { false },
        dismissBar: @escaping () -> Void = {},
        itemSnapshot: @escaping () async -> MenuBarSnapshot = { await Task.detached(priority: .userInitiated) { AXMenuBarItemSource.live.snapshot() }.value },
        store: MenuBarArrangementStore = MenuBarArrangementStore(defaults: .standard),
        method: @escaping () -> MenuBarHidingMethod = { .standard },
        nativeHider: MenuBarNativeHider? = nil,
        watchInterval: Duration = .seconds(5),
        launchDebounce: Duration = .milliseconds(400),
        activationTimeout: Duration = .seconds(3),
        verifyDelay: Duration = .milliseconds(1500),
        developerHooks: Bool = false,
        onToggle: @escaping () -> Void = {},
        turnOff: @escaping () -> Void = {}
    ) {
        self.base = base
        self.assignments = assignments
        self.assign = assign
        self.newItemsSection = newItemsSection
        self.runningBundles = runningBundles
        self.drawnOwners = drawnOwners
        self.overflowAllowed = overflowAllowed
        self.presentation = presentation
        self.barLocation = barLocation
        self.barLook = barLook
        self.emptyClickToggles = emptyClickToggles
        self.dismissBar = dismissBar
        self.itemSnapshot = itemSnapshot
        self.store = store
        self.method = method
        self.nativeHider = nativeHider
        self.watchInterval = watchInterval
        self.portsideBundle = portsideBundle
        self.bundlePath = bundlePath
        self.launchDebounce = launchDebounce
        self.developerHooks = developerHooks
        self.onToggle = onToggle
        self.turnOff = turnOff
        let ownPID = ProcessInfo.processInfo.processIdentifier
        controller = MenuBarAssertionController(
            bridge: bridge,
            activationTimeout: activationTimeout,
            verifyDelay: verifyDelay,
            verifyControl: { [base] in
                guard base.controlIsOnScreen() else { return "Portside's control item is not on screen, so the hide was undone." }
                // The status item window keeps its frame while hidden, so ask the
                // menu bar itself whether Portside still has an item drawn.
                guard let drawn = await drawnOwners() else {
                    // Trusted but unreadable means the bar is not on screen
                    // right now (locked, full screen), not that the icon is gone.
                    return accessibilityTrusted() ? nil : "Portside could not confirm its own menu bar icon because Accessibility is off, so the hide was undone."
                }
                return drawn.contains(ownPID) || (base as? StatusItemShelfSurface)?.icon == .off ? nil : "macOS hid Portside's own menu bar icon along with the others, so the hide was undone. Install Portside in /Applications."
            }
        )
        controller.onFailure = { [weak self] reason in
            self?.noteDiagnostic(lastFailure: reason)
            // After the current call returns, so the shelf can take its state
            // back without running inside its own `hide`.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.failureHandler?(reason) } }
        }
    }

    func install() {
        guard !installed else { return }
        installed = true
        base.install()
        nativeHider?.recover()
        startWatching()
        syncGroupIcons()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier
            let pid = app?.processIdentifier
            MainActor.assumeIsolated { self?.appLaunched(bundle: bundle, pid: pid) }
        })
        if developerHooks {
            installHooks()
            noteDiagnostic(lastFailure: nil)
        }
    }

    func noteFailOpen() { failingOpen = true }

    func applyLook(_ look: MenuBarLook) { base.applyLook(look) }

    func apply(hidden: Bool) {
        let wasHidden = self.hidden
        defer { failingOpen = false }
        let bar = !failingOpen && usesBar()
        let control = base as? StatusItemShelfSurface
        control?.hidesDivider = bar || control?.icon == .off
        if !hidden, wasHidden, bar {
            barOpen = true
            base.apply(hidden: false)
            openBar()
            return
        }
        barOpen = false
        self.hidden = hidden
        base.apply(hidden: hidden)
        refresh()
        if hidden {
            closePanel()
        } else if wasHidden {
            offerPanelIfCrowded()
        }
    }

    func controlIsOnScreen() -> Bool { base.controlIsOnScreen() }

    func remove() {
        installed = false
        launchTask?.cancel()
        launchTask = nil
        watchTask?.cancel()
        watchTask = nil
        closePanel()
        barOpen = false
        removeGroupIcons()
        controller.release()
        nativeHider?.setHidden([])
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
        removeHooks()
        base.remove()
    }

    func installAlwaysHidden() { base.installAlwaysHidden() }

    func applyAlwaysHidden(hidden: Bool) {
        alwaysHiddenClipped = hidden
        base.applyAlwaysHidden(hidden: hidden)
        refresh()
        if barOpen { openBar() }
    }

    func removeAlwaysHidden() {
        alwaysHiddenClipped = false
        base.removeAlwaysHidden()
        refresh()
    }

    func barFrames() -> MenuBarBars? { base.barFrames() }

    /// Releases when nothing should be hidden. Otherwise asks for the
    /// allow-list that hides the assigned apps; no assignment, no hide.
    private func refresh(force: Bool = false) {
        guard installed else { return }
        let sections: Set<MenuBarSection> = hidden ? [.hidden, .alwaysHidden] : (alwaysHiddenClipped ? [.alwaysHidden] : [])
        if method() == .native, let nativeHider, nativeHider.isAvailable {
            controller.release()
            let bundles = MenuBarAssertionPlan.hiddenBundles(assignments: assignments(), sections: sections)
                .filter { !$0.hasPrefix("apple.") }
            if nativeHider.setHidden(bundles) != nil { return }
        }
        nativeHider?.recover()
        guard !sections.isEmpty else {
            controller.request(nil)
            return
        }
        if let problem = MenuBarAssertionPlan.locationProblem(bundlePath: bundlePath) {
            controller.release()
            if hidden {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in
                        self?.failureHandler?(problem)
                        self?.explainLocationOnce(problem)
                    }
                }
            }
            return
        }
        let running = runningBundles()
        if let other = MenuBarAssertionPlan.conflictingManager(running: running) {
            controller.release()
            let reason = "Another menu bar manager is running (\(other)). Quit it to hide items with Portside."
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.failureHandler?(reason) } }
            return
        }
        let hiddenBundles = MenuBarAssertionPlan.hiddenBundles(assignments: assignments(), sections: sections)
        guard !running.isEmpty, !hiddenBundles.isEmpty else {
            controller.release()
            if hidden {
                let reason = "No app is assigned to Hidden, so there is nothing to hide."
                DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.failureHandler?(reason) } }
            }
            return
        }
        controller.request(MenuBarAssertionPlan.config(running: running, hidden: hiddenBundles, portside: portsideBundle), force: force)
    }

    /// Reached only from an explicit hide, so the eye never just does nothing.
    private func explainLocationOnce(_ problem: String) {
        guard !explainedLocation, NSApp != nil else { return }
        explainedLocation = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Portside can't hide items from here"
        alert.informativeText = problem
        alert.runModal()
    }

    /// A new app is not on the allow-list, so its icon would be hidden. Look
    /// again shortly after it launches.
    private func appLaunched(bundle: String?, pid: pid_t?) {
        if bundle == "com.apple.MenuBarAgent" {
            refresh(force: true)
            return
        }
        guard hidden || alwaysHiddenClipped else { return }
        launchTask?.cancel()
        launchTask = Task { [weak self, launchDebounce] in
            try? await Task.sleep(for: launchDebounce)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: New items

    /// An icon can appear long after its app launched, so the bar itself is
    /// watched. An owner never seen before goes to the New Items section.
    private func startWatching() {
        watchTask = Task { [weak self, watchInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: watchInterval)
                guard !Task.isCancelled, let self else { return }
                await self.watchTick()
            }
        }
    }

    private func watchTick() async {
        guard let pids = await drawnOwners() else { return }
        let bundles = Set(pids.compactMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier?.lowercased() })
        let saved = Set(assignments().keys.map(MenuBarLayoutService.bundle(of:)))
        let change = MenuBarNewItems.arrivals(drawn: bundles, known: store.knownOwners, saved: saved, portside: portsideBundle.lowercased())
        guard store.knownOwners != change.known else { return }
        store.knownOwners = change.known
        let section = newItemsSection()
        guard section != .visible, !change.arrivals.isEmpty else { return }
        for bundle in change.arrivals { assign(bundle, section) }
        refresh()
    }

    // MARK: Portside Bar

    /// macOS draws its own "more items" chevron when the bar is full. Some of
    /// the items just revealed are then out of reach, so offer them here.
    private func offerPanelIfCrowded() {
        guard overflowAllowed() else { return }
        panelTask?.cancel()
        panelTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, !self.hidden else { return }
            guard await MenuBarDrawnOwners.barIsOverflowing() else { return }
            let sections: Set<MenuBarSection> = self.alwaysHiddenClipped ? [.hidden] : [.hidden, .alwaysHidden]
            await self.showPanel(only: nil, sections: sections, anchor: (self.base as? StatusItemShelfSurface)?.controlFrame)
        }
    }

    private func usesBar() -> Bool {
        switch presentation() {
        case .menuBar: return false
        case .portsideBar: return true
        case .portsideBarOnNotch:
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            return (screen?.safeAreaInsets.top ?? 0) > 0
        }
    }

    /// Opens the bar for the Hidden section. If it has nothing to list, which
    /// includes Accessibility being off, the items really are revealed.
    private func openBar() {
        let sections: Set<MenuBarSection> = alwaysHiddenClipped ? [.hidden] : [.hidden, .alwaysHidden]
        let anchor = (base as? StatusItemShelfSurface)?.controlFrame
        let pointer = NSEvent.mouseLocation
        let location = barLocation()
        let probe = LiveMenuBarEmptyAreaProbe()
        let placement = MenuBarBarPlacement(location: location, pointer: pointer, pointerOnEmptyBar: location == .dynamic && probe.isClickableBar(pointer))
        panelTask?.cancel()
        panelTask = Task { [weak self] in
            guard let self else { return }
            let shown = await self.showPanel(only: nil, sections: sections, anchor: anchor, placement: placement, bar: true)
            guard !Task.isCancelled, self.barOpen, !shown else { return }
            self.barOpen = false
            self.hidden = false
            self.refresh()
        }
    }

    private func barDismissed() {
        guard barOpen else { return }
        dismissBar()
    }

    /// A click that will toggle the shelf anyway must not also dismiss the bar,
    /// or the toggle would open it again.
    private func clickWillToggle(_ point: NSPoint) -> Bool {
        if let frame = (base as? StatusItemShelfSurface)?.controlFrame, frame.contains(point) { return true }
        return emptyClickToggles() && LiveMenuBarEmptyAreaProbe().isClickableBar(point)
    }

    /// Rows per named group, then the rest. Items never come from a section
    /// that is meant to stay out. False when there was nothing to show.
    @discardableResult
    private func showPanel(only group: UUID?, sections: Set<MenuBarSection>, anchor: NSRect?, placement: MenuBarBarPlacement = MenuBarBarPlacement(), bar: Bool = false) async -> Bool {
        let eligible = MenuBarAssertionPlan.hiddenBundles(assignments: assignments(), sections: sections)
        let groups = store.groups
        let snapshot = await itemSnapshot()
        guard !Task.isCancelled else { return false }
        var byBundle: [String: [MenuBarOverflowPanel.Entry]] = [:]
        for item in snapshot.items {
            guard let bundle = item.ownerBundleID?.lowercased() else { continue }
            let entry = MenuBarOverflowPanel.Entry(
                item: item, bundle: bundle, icon: NSRunningApplication(processIdentifier: item.pid)?.icon,
                menuBarOnly: store.opensOnlyFromMenuBar(bundle)
            )
            byBundle[bundle, default: []].append(entry)
        }
        let rows = MenuBarBarPlan.rows(groups: groups, only: group, eligible: eligible, byBundle: byBundle)
        guard !rows.isEmpty else { return false }
        let ignores: @MainActor (NSPoint) -> Bool = { [weak self] point in bar && (self?.clickWillToggle(point) ?? false) }
        let dismissed: @MainActor () -> Void = { [weak self] in if bar { self?.barDismissed() } }
        panel.show(
            rows, at: placement, look: barLook(), below: anchor, ignoresOutsideClick: ignores, onDismiss: dismissed,
            onSecondary: { [weak self] entry, view in self?.showItemOptions(entry, from: view) },
            onOpen: { [weak self] entry, view in self?.open(entry, from: view) }
        )
        return true
    }

    private func closePanel() {
        panelTask?.cancel()
        panelTask = nil
        panel.close()
    }

    /// Opens an item from the bar without touching the real menu bar: its menu
    /// is read and shown as Portside's own, or its window is opened and moved
    /// under the icon. Nothing is revealed and the pointer stays put.
    private func open(_ entry: MenuBarOverflowPanel.Entry, from view: NSView) {
        guard !store.opensOnlyFromMenuBar(entry.bundle) else { return }
        let item = entry.item
        Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { MenuBarMenuReader.rows(of: item) }.value
            guard let self, self.panel.isShown else { return }
            if rows.isEmpty {
                await self.openWindow(entry, from: view)
            } else {
                self.panel.popUp(MenuBarMirrorMenu.make(rows), from: view)
            }
        }
    }

    private func openWindow(_ entry: MenuBarOverflowPanel.Entry, from view: NSView) async {
        guard let window = view.window, let primary = NSScreen.screens.first, let screen = window.screen else { return }
        let icon = window.convertToScreen(view.convert(view.bounds, to: nil))
        let placement = MenuBarWindowPlacement(iconMidX: icon.midX, top: primary.frame.maxY - window.frame.minY + 6, minX: screen.visibleFrame.minX, maxX: screen.visibleFrame.maxX)
        let item = entry.item
        let outcome = await Task.detached(priority: .userInitiated) { MenuBarWindowOpener.open(item, placement: placement) }.value
        switch outcome {
        case .opened, .unavailable:
            return
        case .stuck:
            // A selection left behind keeps the bar from auto-hiding until this restarts.
            MenuBarSystemProcess.killall("MenuBarAgent")
        case .noEffect:
            break
        }
        store.markMenuBarOnly(entry.bundle)
        panel.markMenuBarOnly(entry.bundle)
    }

    /// Right-click on an icon. Accessibility has only the item's default press,
    /// so this is Portside's own menu.
    private func showItemOptions(_ entry: MenuBarOverflowPanel.Entry, from view: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let app = NSRunningApplication(processIdentifier: entry.item.pid)
        menu.addItem(MenuBarMirrorMenu.item("Open \(entry.item.ownerName)", enabled: app?.bundleURL != nil) {
            guard let url = app?.bundleURL else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        })
        menu.addItem(.separator())
        let current = assignments().first { MenuBarLayoutService.bundle(of: $0.key) == entry.bundle }?.value ?? .visible
        for section in MenuBarSection.allCases {
            let item = MenuBarMirrorMenu.item("Move to \(section.title)") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.assign(entry.bundle, section)
                    self.panel.close()
                    self.barDismissed()
                }
            }
            item.state = section == current ? .on : .off
            menu.addItem(item)
        }
        panel.popUp(menu, from: view)
    }

    // MARK: Group icons

    func groupsDidChange() { syncGroupIcons() }

    private func syncGroupIcons() {
        let wanted = store.groups.filter(\.showsIcon)
        for (id, item) in groupItems where !wanted.contains(where: { $0.id == id }) {
            NSStatusBar.system.removeStatusItem(item)
            groupItems[id] = nil
            groupTargets[id] = nil
        }
        for group in wanted {
            let item = groupItems[group.id] ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "PortsideGroup-\(group.id.uuidString)"
            item.behavior = []
            item.button?.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: group.name)
            item.button?.toolTip = group.name
            let target = groupTargets[group.id] ?? GroupIconTarget { [weak self, id = group.id] in self?.openGroup(id) }
            groupTargets[group.id] = target
            item.button?.target = target
            item.button?.action = #selector(GroupIconTarget.clicked)
            groupItems[group.id] = item
        }
    }

    private func removeGroupIcons() {
        for item in groupItems.values { NSStatusBar.system.removeStatusItem(item) }
        groupItems = [:]
        groupTargets = [:]
    }

    private func openGroup(_ id: UUID) {
        if panel.isShown {
            panel.close()
            return
        }
        let anchor = groupItems[id]?.button?.window?.frame
        panelTask?.cancel()
        panelTask = Task { [weak self] in await self?.showPanel(only: id, sections: [.visible, .hidden, .alwaysHidden], anchor: anchor) }
    }

    // MARK: Developer hooks

    nonisolated static let diagnosticsPath = "/tmp/portside-assertion-diag.json"
    private var lastFailure: String?

    /// Only with the developer hooks on: where this copy runs from, whether it
    /// is Accessibility trusted, and the last reason a hide was undone, so a
    /// terminal can tell a hidden icon from an unverifiable one.
    private func noteDiagnostic(lastFailure failure: String?) {
        guard developerHooks else { return }
        if let failure { lastFailure = failure }
        let info: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundlePath": Bundle.main.bundlePath,
            "executablePath": Bundle.main.executablePath ?? "",
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "accessibilityTrusted": AXIsProcessTrusted(),
            "lastFailure": lastFailure ?? NSNull(),
            "updated": Date().timeIntervalSince1970,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: Self.diagnosticsPath))
        }
    }

    nonisolated static let toggleNotification = "com.james.portside.dev.shelf.toggle"
    nonisolated static let turnOffNotification = "com.james.portside.dev.shelf.turnOff"
    nonisolated static let grantNotification = "com.james.portside.dev.shelf.grant"
    /// Runs from the grant hook.
    var onDeveloperGrant: () -> Void = {}

    /// Only while the opt-in is on: lets a terminal press the real control's
    /// action (`notifyutil -p`) without synthetic input, for timing runs.
    private func installHooks() {
        let grant: () -> Void = { [weak self] in MainActor.assumeIsolated { self?.onDeveloperGrant() } }
        for (name, action) in [(Self.toggleNotification, onToggle), (Self.turnOffNotification, turnOff), (Self.grantNotification, grant)] {
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, .main) { _ in action() }
            if status == NOTIFY_STATUS_OK { hookTokens.append(token) }
        }
    }

    private func removeHooks() {
        for token in hookTokens { notify_cancel(token) }
        hookTokens = []
    }
}

/// Keeps a status item's click alive; `NSStatusItem` holds its target weakly.
private final class GroupIconTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func clicked() { action() }
}

/// Deciding what is new on the bar. Pure.
enum MenuBarNewItems {
    /// The first look only learns what is already there.
    static func arrivals(drawn: Set<String>, known: Set<String>?, saved: Set<String>, portside: String) -> (known: Set<String>, arrivals: Set<String>) {
        let owners = drawn.filter { !$0.hasPrefix("com.apple.") && $0 != portside }
        guard let known else { return (owners.union(saved), []) }
        let fresh = owners.subtracting(known).subtracting(saved)
        return (known.union(owners), fresh)
    }
}

/// The rows of the Portside Bar. Pure.
enum MenuBarBarPlan {
    static func rows(groups: [MenuBarGroup], only: UUID?, eligible: Set<String>, byBundle: [String: [MenuBarOverflowPanel.Entry]]) -> [MenuBarOverflowPanel.Row] {
        var used = Set<String>()
        var rows: [MenuBarOverflowPanel.Row] = []
        for group in groups where only == nil || group.id == only {
            let bundles = group.bundles.filter { eligible.contains($0) }
            used.formUnion(bundles)
            let entries = bundles.flatMap { byBundle[$0] ?? [] }
            if !entries.isEmpty { rows.append(.init(title: group.name, entries: entries)) }
        }
        if only == nil {
            let rest = eligible.subtracting(used).sorted().flatMap { byBundle[$0] ?? [] }
            if !rest.isEmpty { rows.append(.init(title: rows.isEmpty ? nil : "Other", entries: rest)) }
        }
        return rows
    }
}

/// Which processes have an item drawn on the menu bar right now, from
/// MenuBarAgent's own window (public Accessibility API, read only). Nil when
/// Accessibility is not allowed, the window cannot be read, or nothing is
/// drawn (a locked screen, a full screen app). Hidden items are not listed.
enum MenuBarDrawnOwners {
    static func read() async -> Set<pid_t>? {
        await Task.detached(priority: .utility) { readNow() }.value
    }

    struct Item: Sendable {
        let pid: pid_t
        let frame: CGRect
        /// Apple's own "more items" chevron: owned by the agent, no identifier.
        let isOverflowControl: Bool
    }

    nonisolated static func readNow() -> Set<pid_t>? {
        items().map { Set($0.map(\.pid)) }
    }

    static func barIsOverflowing() async -> Bool {
        await Task.detached(priority: .utility) { items()?.contains(where: \.isOverflowControl) ?? false }.value
    }

    /// Every drawn item with its frame (Accessibility coordinates: x as AppKit, y from the top).
    nonisolated static func items() -> [Item]? {
        guard AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        let agentPID = agent.processIdentifier
        let app = AXUIElementCreateApplication(agentPID)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        return collect(windows: windows) { window in
            guard let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            return children.map { child in
                var element = child
                var owner = agentPID
                while true {
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(element, &pid) == .success else { break }
                    owner = pid
                    if pid != agentPID { break }
                    guard let next = (attribute(element, kAXChildrenAttribute) as? [AXUIElement])?.first else { break }
                    element = next
                }
                let identifier = (attribute(element, kAXIdentifierAttribute) as? String) ?? (attribute(child, kAXIdentifierAttribute) as? String) ?? ""
                return Item(pid: owner, frame: frame(of: child) ?? .zero, isOverflowControl: owner == agentPID && identifier.isEmpty)
            }
        }
    }

    /// Each display has its own window. A missing window read is unknown,
    /// not evidence that the control disappeared from every display.
    nonisolated static func collect<Window>(windows: [Window], read: (Window) -> [Item]?) -> [Item]? {
        var result: [Item] = []
        for window in windows {
            guard let items = read(window) else { return nil }
            result.append(contentsOf: items)
        }
        return result.isEmpty ? nil : result
    }

    private nonisolated static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
