import AppKit
import Combine
import OSLog

/// How the menu bar shelf is revealed and hidden (P2-MENU-06). Saved in
/// dock.json as `menuBarTriggers`; every key is optional on read.
struct MenuBarTriggerSettings: Codable, Equatable {
    /// Seconds before a revealed shelf hides again. 0 means never.
    static let rehideChoices = [0, 5, 10, 15, 30, 60]
    static let defaultRehideSeconds = 15

    var hotkey: HotkeyChord?
    /// Optional triggers on the empty part of the menu bar. Off by default and
    /// held off until they are validated (`MenuBarTriggerFeasibility`).
    var hover = false
    var scroll = false
    var emptyClick = false
    var rehideSeconds = MenuBarTriggerSettings.defaultRehideSeconds
    var rehideOnAppChange = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case hotkey, hover, scroll, emptyClick, rehideSeconds, rehideOnAppChange
    }

    /// A malformed or unknown value keeps that field's default; a chord that
    /// cannot be registered is dropped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let chord = try? c.decodeIfPresent(HotkeyChord.self, forKey: .hotkey)
        hotkey = chord.flatMap { $0.isRegisterable ? $0 : nil }
        hover = c.value(.hover, or: false)
        scroll = c.value(.scroll, or: false)
        emptyClick = c.value(.emptyClick, or: false)
        let seconds = c.value(.rehideSeconds, or: Self.defaultRehideSeconds)
        rehideSeconds = Self.rehideChoices.contains(seconds) ? seconds : Self.defaultRehideSeconds
        rehideOnAppChange = c.value(.rehideOnAppChange, or: false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(hotkey, forKey: .hotkey)
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
        if !Self.rehideChoices.contains(copy.rehideSeconds) { copy.rehideSeconds = Self.defaultRehideSeconds }
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

/// Which risky triggers have passed their physical feasibility checks. None
/// has: the pointer triggers cannot yet tell the empty bar from another app's
/// menu or status item reliably (MENU-02 found item frames unreliable), and
/// secure-input starvation is untested on hardware. `PORTSIDE_MENU_TRIGGERS_EXPERIMENTAL=1`
/// unlocks them for those checks only; it is never a setting.
enum MenuBarTriggerFeasibility {
    static let validated: Set<MenuBarTrigger> = []

    static func isAvailable(_ trigger: MenuBarTrigger, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard trigger.isPointerTrigger else { return true }
        return validated.contains(trigger) || environment["PORTSIDE_MENU_TRIGGERS_EXPERIMENTAL"] == "1"
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
}

/// Whether a point is on the empty part of the menu bar: in the bar, not in
/// the notch, not over an app menu or a status item.
@MainActor
protocol MenuBarEmptyAreaProbe: AnyObject {
    func isEmptyBar(_ point: CGPoint) -> Bool
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
    nonisolated static let hoverDwell: Duration = .milliseconds(250)
    /// Retry wait when a rehide is deferred and no delay is set.
    nonisolated static let deferWait = 3

    private let shelf: MenuBarShelf
    private let environment: MenuBarTriggerEnvironment
    private let probe: MenuBarEmptyAreaProbe
    private let unit: (Int) -> Duration
    private let dwell: Duration
    private let featureCheck: (MenuBarTrigger) -> Bool
    private(set) var settings = MenuBarTriggerSettings()
    private var rehideTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var hotKey: HotKey?
    private var monitors: [Any] = []
    private let log = Logger(subsystem: "com.james.portside", category: "menubar-triggers")

    init(
        shelf: MenuBarShelf,
        environment: MenuBarTriggerEnvironment,
        probe: MenuBarEmptyAreaProbe,
        unit: @escaping (Int) -> Duration = { .seconds($0) },
        dwell: Duration = MenuBarTriggerService.hoverDwell,
        featureCheck: @escaping (MenuBarTrigger) -> Bool = { MenuBarTriggerFeasibility.isAvailable($0) }
    ) {
        self.shelf = shelf
        self.environment = environment
        self.probe = probe
        self.unit = unit
        self.dwell = dwell
        self.featureCheck = featureCheck
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
        hotkeyFailure = nil
        status = nil
    }

    func apply(_ next: MenuBarTriggerSettings) {
        let next = next.sanitized
        let previous = settings
        settings = next
        guard isRunning else { return }
        if next.hotkey != previous.hotkey || hotKey == nil && next.hotkey != nil { registerHotKey() }
        if next.hover != previous.hover || next.scroll != previous.scroll || next.emptyClick != previous.emptyClick || monitors.isEmpty {
            installMonitors()
        }
        if next.rehideSeconds != previous.rehideSeconds, rehidePending { armRehide() }
        if !next.rehideOnAppChange, next.rehideSeconds == 0 { rehidePending = false }
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
            shelf.reveal()
            rehidePending = true
            armRehide()
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

    // MARK: Rehide

    private func armRehide() {
        rehideTask?.cancel()
        rehideTask = nil
        guard rehidePending, settings.rehideSeconds > 0 else { return }
        scheduleRehide(after: settings.rehideSeconds)
    }

    private func scheduleRehide(after seconds: Int) {
        rehideTask?.cancel()
        let wait = unit(seconds)
        rehideTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.rehideDue()
        }
    }

    /// Hides unless something is in the way, then waits again; never stacks.
    func rehideDue() {
        rehideTask = nil
        guard rehidePending, shelf.isRunning, shelf.mode == .revealed else {
            rehidePending = false
            return
        }
        if let reason = deferral() {
            status = "Hiding again is waiting: \(reason)"
            scheduleRehide(after: max(settings.rehideSeconds, Self.deferWait))
            return
        }
        rehidePending = false
        status = nil
        shelf.hide()
    }

    private func deferral() -> String? {
        if environment.layoutIsBusy() { return "a layout change is running." }
        if environment.layoutIsEditing() { return "the layout editor is open." }
        if environment.mouseButtonDown() { return "a mouse button is down." }
        if environment.menuIsOpen() { return "a menu is open." }
        return nil
    }

    /// Another app became frontmost. Portside itself never counts, so opening
    /// Settings does not hide the items being edited.
    func appActivated(bundleID: String?) {
        guard settings.rehideOnAppChange, rehidePending, bundleID != Bundle.main.bundleIdentifier else { return }
        rehideDue()
    }

    /// Sleep, wake, a display change, the module turning off: nothing may
    /// hide later on a stale decision.
    func cancelPending() {
        rehideTask?.cancel()
        rehideTask = nil
        dwellTask?.cancel()
        dwellTask = nil
        rehidePending = false
    }

    // MARK: Hotkey

    private func registerHotKey() {
        hotKey = nil
        hotkeyFailure = nil
        guard let chord = settings.hotkey else { return }
        hotKey = HotKey(chord: chord, name: "Menu bar shelf \(chord.displayString)") { [weak self] in
            MainActor.assumeIsolated { _ = self?.activate(.hotkey) }
        }
        if hotKey == nil {
            hotkeyFailure = "macOS refused \(chord.displayString), usually because another app already holds it."
        }
    }

    // MARK: Pointer triggers

    private func installMonitors() {
        removeMonitors()
        var mask: NSEvent.EventTypeMask = []
        if settings.hover && featureCheck(.hover) { mask.insert(.mouseMoved) }
        if settings.scroll && featureCheck(.scroll) { mask.insert(.scrollWheel) }
        if settings.emptyClick && featureCheck(.emptyClick) { mask.insert(.leftMouseDown) }
        guard !mask.isEmpty else { return }
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            let deltaY = event.scrollingDeltaY
            MainActor.assumeIsolated { self?.pointerEvent(type, scrollDelta: deltaY) }
        }
        if let monitor { monitors.append(monitor) }
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
        guard probe.isEmptyBar(point) else {
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
            activate(.emptyClick)
        default:
            break
        }
    }

    private func dwellDone() {
        dwellTask = nil
        guard settings.hover else { return }
        activate(.hover, action: .reveal)
    }
}
