import AppKit
import Combine
import OSLog

/// When a shown shelf hides again by itself. Smart also hides shortly after a
/// click elsewhere or an app switch; Timed only counts down; Focused App only
/// hides on an app switch.
enum MenuBarRehideStrategy: String, Codable, CaseIterable, Identifiable {
    case smart, timed, focusedApp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smart: "Smart"
        case .timed: "After a delay"
        case .focusedApp: "When I switch apps"
        }
    }
}

/// Whether a layout drop may also move the real item (a Command-drag).
/// Manual only records sections and never touches the pointer.
enum MenuBarArrangement: String, Codable, CaseIterable, Identifiable {
    case automatic, manual
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// How apps leave the bar on macOS 27. Standard uses the assertion and can
/// also hide Apple's items. Native uses macOS's own per-app switch.
enum MenuBarHidingMethod: String, Codable, CaseIterable, Identifiable {
    case standard, native
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Where hidden items appear when the shelf opens.
enum MenuBarPresentation: String, Codable, CaseIterable, Identifiable {
    case menuBar, portsideBar, portsideBarOnNotch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .menuBar: "In the menu bar"
        case .portsideBar: "In the Portside Bar"
        case .portsideBarOnNotch: "In the Portside Bar on notched displays"
        }
    }
}

/// Where the Portside Bar opens.
enum MenuBarBarLocation: String, Codable, CaseIterable, Identifiable {
    case dynamic, pointer, icon, left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dynamic: "Pointer or Portside icon"
        case .pointer: "Under the pointer"
        case .icon: "Under the Portside icon"
        case .left: "Left edge"
        case .right: "Right edge"
        }
    }
}

/// How the menu bar shelf is revealed and hidden (P2-MENU-06). Saved in
/// dock.json as `menuBarTriggers`; every key is optional on read.
struct MenuBarTriggerSettings: Codable, Equatable {
    /// Seconds before a revealed shelf hides again. 0 means never.
    static let rehideChoices = [0, 5, 10, 15, 30, 60]
    static let defaultRehideSeconds = 15

    var hotkey: HotkeyChord?
    var alwaysHiddenHotkey: HotkeyChord?
    /// Triggers on the empty part of the menu bar.
    var hover = false
    var scroll = true
    var emptyClick = true
    var rehideSeconds = MenuBarTriggerSettings.defaultRehideSeconds
    var rehideOnAppChange = false
    var strategy = MenuBarRehideStrategy.smart
    /// Saved, unlike the separator shelf's session-only Always Hidden.
    var alwaysHiddenEnabled = false
    /// Where an app seen for the first time goes.
    var newItemsSection = MenuBarSection.visible
    var arrangement = MenuBarArrangement.automatic
    var hidingMethod = MenuBarHidingMethod.standard
    var presentation = MenuBarPresentation.menuBar
    var barLocation = MenuBarBarLocation.dynamic
    var look = MenuBarLook()

    /// Whether another app becoming frontmost hides the shelf.
    var rehidesOnAppChange: Bool { strategy != .timed || rehideOnAppChange }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case hotkey, alwaysHiddenHotkey, hover, scroll, emptyClick, rehideSeconds, rehideOnAppChange
        case strategy, alwaysHiddenEnabled, newItemsSection, arrangement, hidingMethod, presentation, barLocation, look
    }

    /// A malformed or unknown value keeps that field's default; a chord that
    /// cannot be registered is dropped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let chord = try? c.decodeIfPresent(HotkeyChord.self, forKey: .hotkey)
        hotkey = chord.flatMap { $0.isRegisterable ? $0 : nil }
        let second = try? c.decodeIfPresent(HotkeyChord.self, forKey: .alwaysHiddenHotkey)
        alwaysHiddenHotkey = second.flatMap { $0.isRegisterable ? $0 : nil }
        hover = c.value(.hover, or: false)
        scroll = c.value(.scroll, or: true)
        emptyClick = c.value(.emptyClick, or: true)
        strategy = c.value(.strategy, or: MenuBarRehideStrategy.smart)
        alwaysHiddenEnabled = c.value(.alwaysHiddenEnabled, or: false)
        newItemsSection = c.value(.newItemsSection, or: MenuBarSection.visible)
        arrangement = c.value(.arrangement, or: MenuBarArrangement.automatic)
        hidingMethod = c.value(.hidingMethod, or: MenuBarHidingMethod.standard)
        presentation = c.value(.presentation, or: MenuBarPresentation.menuBar)
        barLocation = c.value(.barLocation, or: MenuBarBarLocation.dynamic)
        look = c.value(.look, or: MenuBarLook())
        let seconds = c.value(.rehideSeconds, or: Self.defaultRehideSeconds)
        rehideSeconds = Self.rehideChoices.contains(seconds) ? seconds : Self.defaultRehideSeconds
        rehideOnAppChange = c.value(.rehideOnAppChange, or: false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(hotkey, forKey: .hotkey)
        try c.encodeIfPresent(alwaysHiddenHotkey, forKey: .alwaysHiddenHotkey)
        try c.encode(strategy, forKey: .strategy)
        try c.encode(alwaysHiddenEnabled, forKey: .alwaysHiddenEnabled)
        try c.encode(newItemsSection, forKey: .newItemsSection)
        try c.encode(arrangement, forKey: .arrangement)
        try c.encode(hidingMethod, forKey: .hidingMethod)
        try c.encode(presentation, forKey: .presentation)
        try c.encode(barLocation, forKey: .barLocation)
        try c.encode(look, forKey: .look)
        try c.encode(hover, forKey: .hover)
        try c.encode(scroll, forKey: .scroll)
        try c.encode(emptyClick, forKey: .emptyClick)
        try c.encode(rehideSeconds, forKey: .rehideSeconds)
        try c.encode(rehideOnAppChange, forKey: .rehideOnAppChange)
    }

    /// Clamps to what the app accepts.
    var sanitized: MenuBarTriggerSettings {
        var copy = self
        if let chord = copy.hotkey, !chord.isRegisterable { copy.hotkey = nil }
        if let chord = copy.alwaysHiddenHotkey, !chord.isRegisterable { copy.alwaysHiddenHotkey = nil }
        if !Self.rehideChoices.contains(copy.rehideSeconds) { copy.rehideSeconds = Self.defaultRehideSeconds }
        copy.look = copy.look.sanitized
        return copy
    }
}

enum MenuBarTrigger: String, CaseIterable {
    /// The shelf control or its right-click menu.
    case control
    case hotkey
    /// The Hide or Show Menu Bar Items command.
    case command
    case hover
    case scroll
    case emptyClick

    /// Needs the pointer over the empty bar, so it reads other apps' menu
    /// bar geometry and can be starved or misfire.
    var isPointerTrigger: Bool {
        switch self {
        case .hover, .scroll, .emptyClick: return true
        case .control, .hotkey, .command: return false
        }
    }
}

/// Which pointer triggers are offered. All of them now that the empty-bar
/// test reads MenuBarAgent's own window.
enum MenuBarTriggerFeasibility {
    static let validated: Set<MenuBarTrigger> = [.hover, .scroll, .emptyClick]

    static func isAvailable(_ trigger: MenuBarTrigger) -> Bool {
        !trigger.isPointerTrigger || validated.contains(trigger)
    }
}

extension MenuBarTrigger {
    @MainActor var isAvailableNow: Bool { MenuBarTriggerFeasibility.isAvailable(self) }
}

/// What a trigger must check before it acts. The live one reads macOS;
/// tests inject fixtures.
@MainActor
protocol MenuBarTriggerEnvironment: AnyObject {
    /// Another app's menu or a status item menu is open.
    func menuIsOpen() -> Bool
    /// A mouse button is down, which includes a drag.
    func mouseButtonDown() -> Bool
    func secureInputActive() -> Bool
    func accessibilityTrusted() -> Bool
    /// Layout or Reorder is moving items with synthetic drags.
    func layoutIsBusy() -> Bool
    /// The layout editor is open and needs every item on screen.
    func layoutIsEditing() -> Bool
    /// The pointer is over a menu bar, so the user is still working there.
    func pointerInMenuBar() -> Bool
    /// The window under the pointer belongs to the active app or the Dock.
    func cursorOverActiveAppOrDock() -> Bool
    /// The shelf just opened. Menus open from now on count; panels already up do not.
    func noteRevealed()
}

extension MenuBarTriggerEnvironment {
    func pointerInMenuBar() -> Bool { false }
    func cursorOverActiveAppOrDock() -> Bool { true }
    func noteRevealed() {}
}

/// Whether a point is on the empty part of the menu bar: in the bar, not in
/// the notch, not over an app menu or a status item.
@MainActor
protocol MenuBarEmptyAreaProbe: AnyObject {
    func isEmptyBar(_ point: CGPoint) -> Bool
    /// A click also counts on the notch, which is still menu bar.
    func isClickableBar(_ point: CGPoint) -> Bool
    /// Clicks, scrolls and dwell ends must read the bar as it is now.
    func discardCache()
}

extension MenuBarEmptyAreaProbe {
    func discardCache() {}
}

/// The pure geometry behind the empty-bar test, in one coordinate space.
enum MenuBarBarGeometry {
    /// `occupied` are the app menu and status item rects; `margin` keeps a
    /// pointer near an edge from counting as empty.
    static func isEmpty(point: CGPoint, band: CGRect, notch: CGRect?, occupied: [CGRect], margin: CGFloat = 4) -> Bool {
        guard band.contains(point) else { return false }
        if let notch, notch.insetBy(dx: -margin, dy: 0).contains(CGPoint(x: point.x, y: notch.midY)) { return false }
        return !occupied.contains { $0.insetBy(dx: -margin, dy: -margin).contains(CGPoint(x: point.x, y: band.midY)) }
    }
}

extension MenuBarEmptyAreaProbe {
    func isClickableBar(_ point: CGPoint) -> Bool { isEmptyBar(point) }
}

/// Reveal and hide triggers plus automatic rehide, on top of the existing
/// `MenuBarShelf` (it owns the separator, recovery and verification). This
/// adds no menu bar state of its own: it asks the shelf to reveal or hide and
/// remembers only whether a trigger revealed it, so rehide never hides
/// something the user opened for another reason (the layout editor).
///
/// No polling. Rehide is one cancelable delay timer; the pointer triggers
/// use global event monitors installed only while one is on and available.
/// Fail-open stays the shelf's job; this only cancels what it had pending.
@MainActor
final class MenuBarTriggerService: ObservableObject {
    enum Action { case toggle, reveal, hide }

    enum Outcome: Equatable {
        case revealed, hidden
        case refused(String)
    }

    /// Why the last trigger did nothing, for Settings. Nil after one acts.
    @Published private(set) var status: String?
    /// Why macOS refused the shortcut, or nil.
    @Published private(set) var hotkeyFailure: String?
    @Published private(set) var isRunning = false
    /// A trigger revealed the shelf and a rehide is still wanted.
    private(set) var rehidePending = false

    /// Secure input is on now, for Settings to explain a shortcut that may not fire.
    var secureInputOn: Bool { environment.secureInputActive() }

    /// Wait before a hover reveals, so crossing the bar does not.
    nonisolated static let hoverDwell: Duration = .milliseconds(200)
    /// Retry wait when a rehide is deferred and no delay is set.
    nonisolated static let deferWait = 3

    private let shelf: MenuBarShelf
    private let environment: MenuBarTriggerEnvironment
    private let probe: MenuBarEmptyAreaProbe
    private let unit: (Int) -> Duration
    private let smartUnit: (Int) -> Duration
    private let dwell: Duration
    private let featureCheck: (MenuBarTrigger) -> Bool
    private(set) var settings = MenuBarTriggerSettings()
    private var rehideTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var smartTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var rehideMonitor: Any?
    private var lastPointerCheck: TimeInterval = 0
    private var lastReveal: ContinuousClock.Instant?
    private var lastEmptyClick: TimeInterval = 0
    private let eligibilityPoll: Duration
    private let focusGrace: Duration
    private var hotKey: HotKey?
    private var alwaysHiddenHotKey: HotKey?
    private var monitors: [Any] = []
    private let log = Logger(subsystem: "com.james.portside", category: "menubar-triggers")

    init(
        shelf: MenuBarShelf,
        environment: MenuBarTriggerEnvironment,
        probe: MenuBarEmptyAreaProbe,
        unit: @escaping (Int) -> Duration = { .seconds($0) },
        smartUnit: ((Int) -> Duration)? = nil,
        dwell: Duration = MenuBarTriggerService.hoverDwell,
        eligibilityPoll: Duration = .milliseconds(250),
        focusGrace: Duration = .milliseconds(500),
        featureCheck: @escaping (MenuBarTrigger) -> Bool = { MenuBarTriggerFeasibility.isAvailable($0) }
    ) {
        self.shelf = shelf
        self.environment = environment
        self.probe = probe
        self.unit = unit
        self.smartUnit = smartUnit ?? unit
        self.dwell = dwell
        self.eligibilityPoll = eligibilityPoll
        self.focusGrace = focusGrace
        self.featureCheck = featureCheck
        shelf.onRecovery = { [weak self] reason in
            guard let self, self.isRunning else { return }
            self.cancelPending()
            self.status = "Hiding stopped: \(reason)"
        }
    }

    func start(_ settings: MenuBarTriggerSettings) {
        isRunning = true
        apply(settings)
    }

    func stop() {
        isRunning = false
        cancelPending()
        removeMonitors()
        hotKey = nil
        alwaysHiddenHotKey = nil
        hotkeyFailure = nil
        status = nil
    }

    func apply(_ next: MenuBarTriggerSettings) {
        let next = next.sanitized
        let previous = settings
        settings = next
        guard isRunning else { return }
        if next.hotkey != previous.hotkey || hotKey == nil && next.hotkey != nil { registerHotKey() }
        if next.alwaysHiddenHotkey != previous.alwaysHiddenHotkey || alwaysHiddenHotKey == nil && next.alwaysHiddenHotkey != nil { registerAlwaysHiddenHotKey() }
        if next.hover != previous.hover || next.scroll != previous.scroll || next.emptyClick != previous.emptyClick
            || next.strategy != previous.strategy || monitors.isEmpty {
            installMonitors()
        }
        if next.hidingMethod != previous.hidingMethod { shelf.membershipDidChange() }
        if shelf.hidesByMembership, !shelf.alwaysHiddenEnabled { shelf.setAlwaysHidden(true) }
        if next.rehideSeconds != previous.rehideSeconds || next.strategy != previous.strategy {
            smartTask?.cancel()
            smartTask = nil
            focusTask?.cancel()
            focusTask = nil
            startRehideChecks()
        }
    }

    // MARK: Triggers

    /// Runs one trigger. A refusal says why and changes nothing.
    @discardableResult
    func activate(_ trigger: MenuBarTrigger, action: Action = .toggle) -> Outcome {
        if let reason = refusal(for: trigger) {
            status = reason
            return .refused(reason)
        }
        status = nil
        let wantReveal: Bool
        switch action {
        case .toggle: wantReveal = shelf.mode == .hidden
        case .reveal: wantReveal = true
        case .hide: wantReveal = false
        }
        if wantReveal {
            guard shelf.mode == .hidden else { return .revealed }
            beforeReveal()
            shelf.reveal()
            noteOpened()
            return .revealed
        }
        cancelPending()
        shelf.hide()
        return .hidden
    }

    /// Why `trigger` must not act now, or nil.
    func refusal(for trigger: MenuBarTrigger) -> String? {
        guard shelf.isRunning, isRunning else { return "Menu Bar Shelf is off." }
        if environment.layoutIsBusy() { return "A layout change is running." }
        guard trigger.isPointerTrigger else { return nil }
        if !featureCheck(trigger) { return "This trigger is not validated yet." }
        if !environment.accessibilityTrusted() { return "Needs Accessibility to find the empty part of the menu bar." }
        if environment.secureInputActive() { return "Secure input is on, so macOS withholds mouse events from other apps." }
        if environment.mouseButtonDown() && trigger != .emptyClick { return "A mouse button is down." }
        if environment.menuIsOpen() { return "A menu is open." }
        return nil
    }

    /// Double-click, Option-click and the second shortcut: also shows Always Hidden.
    func showAlwaysHidden(_ trigger: MenuBarTrigger = .control) {
        guard refusal(for: trigger) == nil, shelf.alwaysHiddenEnabled else { return }
        beforeReveal()
        shelf.showAlwaysHidden()
        noteOpened()
    }

    /// Runs just before the shelf opens, so items appear in their saved order.
    var beforeReveal: () -> Void = {}

    private func noteOpened() {
        rehidePending = true
        lastReveal = .now
        environment.noteRevealed()
        startRehideChecks()
    }

    func toggleAlwaysHidden(_ trigger: MenuBarTrigger = .control) {
        if shelf.alwaysHiddenShown {
            activate(trigger, action: .hide)
        } else {
            showAlwaysHidden(trigger)
        }
    }

    var alwaysHiddenAvailable: Bool { shelf.alwaysHiddenEnabled }

    /// The launch state: every assigned app hidden, no rehide owed.
    func startCollapsed() {
        guard isRunning, shelf.hidesByMembership, shelf.hasHiddenAssignments else { return }
        shelf.hide()
    }

    // MARK: Rehide

    /// Starts whatever the chosen policy does while the shelf is open.
    private func startRehideChecks() {
        rehideTask?.cancel()
        rehideTask = nil
        removeRehideMonitor()
        guard rehidePending, settings.rehideSeconds > 0 else { return }
        switch settings.strategy {
        case .smart:
            // The countdown backs up the click-based path.
            rehideTask = makeRehideTask { [weak self] in self?.startRehideChecks() }
        case .timed:
            rehideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMovedWhileOpen() }
            }
            updateTimedRehide()
        case .focusedApp:
            break
        }
    }

    private func removeRehideMonitor() {
        if let rehideMonitor { NSEvent.removeMonitor(rehideMonitor) }
        rehideMonitor = nil
    }

    /// Timed counts only while the pointer is off the menu bar.
    func pointerMovedWhileOpen() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPointerCheck > 0.05 else { return }
        lastPointerCheck = now
        updateTimedRehide()
    }

    private func updateTimedRehide() {
        guard rehidePending, settings.strategy == .timed else { return }
        if environment.pointerInMenuBar() {
            rehideTask?.cancel()
            rehideTask = nil
        } else if rehideTask == nil {
            rehideTask = makeRehideTask { [weak self] in self?.restartTimedCountdown() }
        }
    }

    private func restartTimedCountdown() {
        rehideTask = makeRehideTask { [weak self] in self?.restartTimedCountdown() }
    }

    /// Hides after a full eligible interval. Time with a menu open or a drag
    /// under way does not count. The pointer on the bar abandons the wait.
    private func makeRehideTask(onBlocked: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let interval = unit(settings.rehideSeconds)
        return Task { [weak self, eligibilityPoll] in
            let clock = ContinuousClock()
            var eligibleSince = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: eligibilityPoll)
                guard !Task.isCancelled, let self else { return }
                if self.environment.pointerInMenuBar() {
                    self.rehideTask = nil
                    return
                }
                if self.heldOpen() != nil {
                    eligibleSince = clock.now
                    continue
                }
                if eligibleSince.duration(to: clock.now) >= interval {
                    self.rehideTask = nil
                    self.finishRehide(onBlocked: onBlocked)
                    return
                }
            }
        }
    }

    private func finishRehide(onBlocked: @MainActor () -> Void) {
        guard rehidePending, shelf.isRunning, shelf.mode == .revealed else {
            rehidePending = false
            return
        }
        if let reason = heldOpen() ?? (environment.pointerInMenuBar() ? "the pointer is on the menu bar." : nil) {
            status = "Hiding again is waiting: \(reason)"
            onBlocked()
            return
        }
        hideNow()
    }

    private func hideNow() {
        rehideTask?.cancel()
        rehideTask = nil
        smartTask?.cancel()
        smartTask = nil
        focusTask?.cancel()
        focusTask = nil
        removeRehideMonitor()
        rehidePending = false
        status = nil
        shelf.hide()
    }

    /// What keeps the shelf open without counting toward the delay.
    private func heldOpen() -> String? {
        if environment.layoutIsBusy() { return "a layout change is running." }
        if environment.layoutIsEditing() { return "the layout editor is open." }
        if environment.mouseButtonDown() { return "a mouse button is down." }
        if environment.menuIsOpen() { return "a menu is open." }
        return nil
    }

    /// Another app became frontmost. Portside itself never counts, so opening
    /// Settings does not hide the items being edited. Waits the delay, and
    /// ignores the focus change a reveal itself often causes.
    func appActivated(bundleID: String?) {
        guard settings.rehidesOnAppChange, settings.rehideSeconds > 0, rehidePending, bundleID != Bundle.main.bundleIdentifier,
              !environment.pointerInMenuBar() else { return }
        focusTask?.cancel()
        let wait = smartUnit(settings.rehideSeconds)
        focusTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.rehidePending else { return }
            self.focusTask = nil
            if let last = self.lastReveal, last.duration(to: .now) < self.focusGrace { return }
            if self.settings.strategy == .smart, self.environment.menuIsOpen() { return }
            if self.environment.layoutIsEditing() || self.environment.layoutIsBusy() { return }
            self.hideNow()
        }
    }

    /// Smart: a click away from the bar starts the wait, and the newest click
    /// decides. Hides only if the pointer is then over the active app or the
    /// Dock and no menu is open, so a click on a panel or popover keeps it open.
    func clickedElsewhere() {
        guard settings.strategy == .smart, rehidePending, settings.rehideSeconds > 0, !environment.pointerInMenuBar() else { return }
        smartTask?.cancel()
        let wait = smartUnit(settings.rehideSeconds)
        smartTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.smartDue(requireActiveApp: true)
        }
    }

    /// A click that also changed Space settles it at once.
    func spaceChanged() {
        guard smartTask != nil else { return }
        smartDue(requireActiveApp: false)
    }

    private func smartDue(requireActiveApp: Bool) {
        smartTask?.cancel()
        smartTask = nil
        guard rehidePending, settings.strategy == .smart, settings.rehideSeconds > 0 else { return }
        if requireActiveApp, !environment.cursorOverActiveAppOrDock() { return }
        if heldOpen() != nil { return }
        hideNow()
    }

    /// Hides at once when something outside the policies asks, or waits again.
    func rehideDue() {
        rehideTask = nil
        finishRehide { [weak self] in self?.startRehideChecks() }
    }

    /// Nothing pending survives a stale decision, but the shelf stays as it is.
    func displayChanged() {
        dwellTask?.cancel()
        dwellTask = nil
        smartTask?.cancel()
        smartTask = nil
        focusTask?.cancel()
        focusTask = nil
        startRehideChecks()
    }

    /// Sleep, wake, a display change, the module turning off: nothing may
    /// hide later on a stale decision.
    func cancelPending() {
        rehideTask?.cancel()
        rehideTask = nil
        removeRehideMonitor()
        dwellTask?.cancel()
        dwellTask = nil
        smartTask?.cancel()
        smartTask = nil
        focusTask?.cancel()
        focusTask = nil
        rehidePending = false
    }

    // MARK: Hotkey

    private func registerHotKey() {
        hotKey = nil
        hotkeyFailure = nil
        defer { registerAlwaysHiddenHotKey() }
        guard let chord = settings.hotkey else { return }
        hotKey = HotKey(chord: chord, name: "Menu bar shelf \(chord.displayString)") { [weak self] in
            MainActor.assumeIsolated { _ = self?.activate(.hotkey) }
        }
        if hotKey == nil {
            hotkeyFailure = "macOS refused \(chord.displayString), usually because another app already holds it."
        }
    }

    private func registerAlwaysHiddenHotKey() {
        alwaysHiddenHotKey = nil
        guard let chord = settings.alwaysHiddenHotkey else { return }
        alwaysHiddenHotKey = HotKey(chord: chord, name: "Menu bar Always Hidden \(chord.displayString)") { [weak self] in
            MainActor.assumeIsolated { self?.toggleAlwaysHidden(.hotkey) }
        }
        if alwaysHiddenHotKey == nil {
            let failure = "macOS refused \(chord.displayString), usually because another app already holds it."
            hotkeyFailure = hotkeyFailure ?? failure
        }
    }

    // MARK: Pointer triggers

    private func installMonitors() {
        removeMonitors()
        var mask: NSEvent.EventTypeMask = []
        if settings.hover && featureCheck(.hover) { mask.insert(.mouseMoved) }
        if settings.scroll && featureCheck(.scroll) { mask.insert(.scrollWheel) }
        if settings.emptyClick && featureCheck(.emptyClick) { mask.insert(.leftMouseDown) }
        if settings.strategy == .smart { mask.insert(.leftMouseDown); mask.insert(.rightMouseDown) }
        guard !mask.isEmpty else { return }
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.receive(event.type, scrollDelta: Self.scrollDelta(of: event))
        }
        if let monitor { monitors.append(monitor) }
        // A global monitor sees only other apps' events, so with Settings in
        // front the bar would stop answering without this one.
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.receive(event.type, scrollDelta: Self.scrollDelta(of: event))
            return event
        }
        if let local { monitors.append(local) }
    }

    /// `scrollingDeltaY` raises on anything but a scroll, and AppKit swallows
    /// the exception, so reading it on a click would silently drop the click.
    nonisolated static func scrollDelta(of event: NSEvent) -> CGFloat {
        event.type == .scrollWheel ? event.scrollingDeltaY : 0
    }

    private nonisolated func receive(_ type: NSEvent.EventType, scrollDelta: CGFloat) {
        MainActor.assumeIsolated {
            if type == .leftMouseDown || type == .rightMouseDown { clickedElsewhere() }
            pointerEvent(type, scrollDelta: scrollDelta)
        }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        dwellTask?.cancel()
        dwellTask = nil
    }

    /// Delivered for every pointer event while a pointer trigger is on, so it
    /// returns before doing any work unless the pointer is on the bar.
    func pointerEvent(_ type: NSEvent.EventType, scrollDelta: CGFloat = 0, at point: CGPoint = NSEvent.mouseLocation) {
        if type != .mouseMoved { probe.discardCache() }
        guard type == .leftMouseDown ? probe.isClickableBar(point) : probe.isEmptyBar(point) else {
            dwellTask?.cancel()
            dwellTask = nil
            return
        }
        switch type {
        case .mouseMoved:
            guard settings.hover, shelf.mode == .hidden, dwellTask == nil else { return }
            dwellTask = Task { [weak self, dwell] in
                try? await Task.sleep(for: dwell)
                guard !Task.isCancelled else { return }
                self?.dwellDone()
            }
        case .scrollWheel:
            guard settings.scroll, scrollDelta != 0 else { return }
            activate(.scroll, action: scrollDelta > 0 ? .reveal : .hide)
        case .leftMouseDown:
            guard settings.emptyClick else { return }
            // A second click inside the double-click window opens Always Hidden.
            let now = ProcessInfo.processInfo.systemUptime
            let second = now - lastEmptyClick < NSEvent.doubleClickInterval
            lastEmptyClick = second ? 0 : now
            if second, shelf.alwaysHiddenEnabled {
                showAlwaysHidden(.emptyClick)
            } else {
                activate(.emptyClick)
            }
        default:
            break
        }
    }

    private func dwellDone() {
        dwellTask = nil
        probe.discardCache()
        guard settings.hover, probe.isEmptyBar(NSEvent.mouseLocation) else { return }
        activate(.hover, action: .reveal)
    }
}
