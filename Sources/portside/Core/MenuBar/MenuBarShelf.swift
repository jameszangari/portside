import AppKit
import OSLog

/// What the shelf draws and measures. The live one owns two `NSStatusItem`s;
/// tests inject a fixture so the state machine runs without a menu bar.
@MainActor
protocol MenuBarShelfSurface: AnyObject {
    func install()
    /// Shrinks or grows the separator. Hidden pushes the items to its left
    /// into the clipped zone; revealed lets them come back (spike O4, O5).
    func apply(hidden: Bool)
    /// Both of Portside's own items are on a screen. False means the hide
    /// pushed the control out of reach, so the shelf must reveal again.
    func controlIsOnScreen() -> Bool
    func remove()
    /// The optional second separator (P2-MENU-05), left of the first. Widened,
    /// it clips the Always Hidden items; collapsed, they come back.
    func installAlwaysHidden()
    func applyAlwaysHidden(hidden: Bool)
    func removeAlwaysHidden()
    /// Where the separators sit now, only while both are collapsed and in
    /// order. Nil otherwise: a widened separator reports no usable position.
    func barFrames() -> MenuBarBars?
    /// Set by the shelf. A surface that cannot hide, or loses a hide it was
    /// asked for, calls it with the reason; the shelf then reveals. The
    /// separator surface never needs it.
    var failureHandler: (@MainActor (String) -> Void)? { get set }
    /// The next reveal must really show the items: a recovery or a layout move.
    func noteFailOpen()
    func applyLook(_ look: MenuBarLook)
    /// True when hiding follows saved section membership (macOS 27 assertion)
    /// rather than item position, so moving an item between sections needs no drag.
    var hidesByMembership: Bool { get }
    var hasHiddenAssignments: Bool { get }
    /// The saved sections changed; apply them now.
    func membershipDidChange()
    /// After sleep or a display change: confirm hiding is still sound.
    func revalidate()
}

extension MenuBarShelfSurface {
    var hidesByMembership: Bool { false }
    func noteFailOpen() {}
    func applyLook(_ look: MenuBarLook) {}
    var hasHiddenAssignments: Bool { false }
    func membershipDidChange() {}
    func revalidate() {}
}

/// P2-MENU-03: a recoverable reveal shelf. A separator status item of
/// Portside's own, placed to the left of a control item, is widened to push
/// the items on its left out of view and shrunk to bring them back (see the
/// hide/recovery spike). Nothing of another app is touched: no preference,
/// no move, no Accessibility.
///
/// Fail-open by construction. The shelf starts revealed on every launch and
/// never saves "hidden"; the hide lives only in this process, so quit, crash
/// and SIGKILL all return the bar (spike O7). Sleep, wake, a display change
/// and a control that ends off screen reveal at once.
@MainActor
final class MenuBarShelf {
    enum Mode: Equatable { case revealed, hidden }

    /// Wait after hiding before checking the control is still on screen.
    /// One-shot, not a poll; the bar needs a moment to re-lay out.
    nonisolated static let verifyDelay: Duration = .milliseconds(300)

    private(set) var mode = Mode.revealed
    private(set) var isRunning = false
    /// Why the last automatic reveal happened; nil after a user action.
    private(set) var lastFailOpen: String?
    /// Session only, like `mode`: never saved, so every launch starts with
    /// nothing clipped (P2-MENU-05).
    private(set) var alwaysHiddenEnabled = false
    /// Always Hidden is open right now (double-click, Option-click).
    private(set) var alwaysHiddenShown = false
    var hidesByMembership: Bool { surface.hidesByMembership }
    var hasHiddenAssignments: Bool { surface.hasHiddenAssignments }
    /// Runs after a fail-open that also switched Always Hidden off.
    var onFailOpen: (@MainActor () -> Void)?
    /// Reports recovery to trigger controls without replacing layout's callback.
    var onRecovery: (@MainActor (String) -> Void)?
    private let surface: MenuBarShelfSurface
    private let verifyDelay: Duration
    private var verifying: Task<Void, Never>?
    private let log = Logger(subsystem: "com.james.portside", category: "menubar-shelf")

    init(surface: MenuBarShelfSurface, verifyDelay: Duration = MenuBarShelf.verifyDelay) {
        self.surface = surface
        self.verifyDelay = verifyDelay
        surface.failureHandler = { [weak self] reason in self?.failOpen(reason) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        mode = .revealed
        lastFailOpen = nil
        surface.install()
        surface.apply(hidden: false)
    }

    /// Reveals first, so even a removal that fails halfway leaves nothing hidden.
    func stop() {
        guard isRunning else { return }
        verifying?.cancel()
        verifying = nil
        surface.apply(hidden: false)
        if alwaysHiddenEnabled {
            surface.applyAlwaysHidden(hidden: false)
            surface.removeAlwaysHidden()
            alwaysHiddenEnabled = false
        }
        surface.remove()
        mode = .revealed
        isRunning = false
    }

    func toggle() {
        mode == .hidden ? reveal() : hide()
    }

    func hide() {
        guard isRunning, mode == .revealed else { return }
        if alwaysHiddenShown {
            alwaysHiddenShown = false
            if alwaysHiddenEnabled { surface.applyAlwaysHidden(hidden: true) }
        }
        mode = .hidden
        lastFailOpen = nil
        surface.apply(hidden: true)
        scheduleVerify()
    }

    private func scheduleVerify() {
        verifying?.cancel()
        verifying = Task { [weak self, verifyDelay] in
            try? await Task.sleep(for: verifyDelay)
            guard !Task.isCancelled else { return }
            self?.verify()
        }
    }

    /// Reveals Hidden and Always Hidden together until the next hide.
    func showAlwaysHidden() {
        guard isRunning, alwaysHiddenEnabled else { return }
        reveal()
        alwaysHiddenShown = true
        surface.applyAlwaysHidden(hidden: false)
    }

    func membershipDidChange() {
        guard isRunning else { return }
        surface.membershipDidChange()
    }

    func applyLook(_ look: MenuBarLook) {
        guard isRunning else { return }
        surface.applyLook(look)
    }

    func revalidate() {
        guard isRunning else { return }
        surface.revalidate()
    }

    /// Clips the Always Hidden items behind a second separator, or brings them
    /// back. Off after any fail-open and on every launch.
    func setAlwaysHidden(_ wanted: Bool) {
        // Hiding by membership always honors the section an item is in.
        let on = wanted || surface.hidesByMembership
        guard isRunning, on != alwaysHiddenEnabled else { return }
        if on {
            surface.installAlwaysHidden()
            surface.applyAlwaysHidden(hidden: true)
            alwaysHiddenEnabled = true
            scheduleVerify()
        } else {
            surface.applyAlwaysHidden(hidden: false)
            surface.removeAlwaysHidden()
            alwaysHiddenEnabled = false
            alwaysHiddenShown = false
        }
    }

    func barFrames() -> MenuBarBars? { isRunning ? surface.barFrames() : nil }

    /// Shows every item so the layout can reach them: the first separator
    /// collapses and Always Hidden is opened. Pair with `closeAfterLayout`.
    func openForLayout() {
        guard isRunning else { return }
        // A real move needs the items on the real bar, not in the Portside Bar.
        if mode == .hidden { surface.noteFailOpen() }
        reveal()
        if alwaysHiddenEnabled { surface.applyAlwaysHidden(hidden: false) }
    }

    func closeAfterLayout() {
        guard isRunning, alwaysHiddenEnabled else { return }
        alwaysHiddenShown = false
        surface.applyAlwaysHidden(hidden: true)
        scheduleVerify()
    }

    func reveal() {
        guard isRunning else { return }
        verifying?.cancel()
        verifying = nil
        lastFailOpen = nil
        guard mode == .hidden else { return }
        mode = .revealed
        surface.apply(hidden: false)
    }

    /// Sleep, wake, display change: reveal without asking, so a notch or an
    /// unplugged display cannot leave items trapped.
    func failOpen(_ reason: String) {
        guard isRunning else { return }
        onRecovery?(reason)
        verifying?.cancel()
        verifying = nil
        let hadAlwaysHidden = alwaysHiddenEnabled && !surface.hidesByMembership
        alwaysHiddenShown = false
        if hadAlwaysHidden {
            surface.applyAlwaysHidden(hidden: false)
            surface.removeAlwaysHidden()
            alwaysHiddenEnabled = false
        }
        guard mode == .hidden else {
            if hadAlwaysHidden {
                lastFailOpen = reason
                log.notice("menu bar always hidden off: \(reason, privacy: .public)")
                onFailOpen?()
            }
            return
        }
        mode = .revealed
        lastFailOpen = reason
        log.notice("menu bar shelf revealed: \(reason, privacy: .public)")
        surface.noteFailOpen()
        surface.apply(hidden: false)
        onFailOpen?()
    }

    private func verify() {
        guard isRunning, mode == .hidden || alwaysHiddenEnabled else { return }
        if !surface.controlIsOnScreen() { failOpen("the control was pushed off screen") }
    }
}

/// The live surface: a control item on the right and a separator to its left.
@MainActor
final class StatusItemShelfSurface: NSObject, MenuBarShelfSurface {
    static let controlName = "PortsideShelfControl"
    static let separatorName = "PortsideShelfSeparator"
    static let alwaysHiddenName = "PortsideShelfAlwaysHiddenSeparator"
    /// Lengths in points. 120 hid items on a notched 1728 pt display; 220 and
    /// up clipped the separator itself (spike O6), so this stays modest.
    nonisolated static let revealedLength: CGFloat = 14
    nonisolated static let hiddenLength: CGFloat = 120
    /// Largest width a hiding separator is given, so a bad reading cannot
    /// ask for something absurd.
    nonisolated static let maxHiddenLength: CGFloat = 6000

    /// How wide a separator must be to push everything on its left off the
    /// screen: its right edge stays put (the items on its right do not move),
    /// so its left edge has to reach the screen's left edge. Never smaller
    /// than the original 120 pt, which only hid the nearest few items. Nil
    /// reading falls back to a width that clears any display.
    nonisolated static func widthToClear(rightEdge: CGFloat?, screenMinX: CGFloat?) -> CGFloat {
        guard let rightEdge, let screenMinX else { return 3000 }
        return min(max(rightEdge - screenMinX + 40, hiddenLength), maxHiddenLength)
    }

    /// Extra rows for the control's right-click menu (profiles).
    var extraMenuItems: @MainActor () -> [NSMenuItem] = { [] }

    /// The control's frame, for placing the overflow panel under it.
    var controlFrame: NSRect? { icon == .off ? nil : control?.button?.window?.frame }

    /// Runs from the control's menu. The owner turns the module off.
    private let turnOff: () -> Void
    private let onToggle: () -> Void
    /// The assertion surface owns hiding: dividers only mark where sections
    /// begin, and collapse to nothing instead of widening.
    private let dividerMode: Bool
    private let onAlwaysHidden: () -> Void
    private let alwaysHiddenAvailable: () -> Bool
    private var lastPrimaryClick: TimeInterval = 0
    private var secondaryMonitor: Any?
    var failureHandler: (@MainActor (String) -> Void)?
    private var control: NSStatusItem?
    private var separator: NSStatusItem?
    private var alwaysHiddenSeparator: NSStatusItem?
    private var hidden = false
    private(set) var icon = MenuBarControlIcon.eye
    /// No marker while items open in the Portside Bar or there is no control.
    var hidesDivider = false

    init(
        onToggle: @escaping () -> Void, turnOff: @escaping () -> Void, dividerMode: Bool = false,
        onAlwaysHidden: @escaping () -> Void = {}, alwaysHiddenAvailable: @escaping () -> Bool = { false }
    ) {
        self.onToggle = onToggle
        self.turnOff = turnOff
        self.dividerMode = dividerMode
        self.onAlwaysHidden = onAlwaysHidden
        self.alwaysHiddenAvailable = alwaysHiddenAvailable
    }

    /// Seeds Portside's own default for where each item sits, only when the
    /// user has never placed it (a smaller number is further right). The key
    /// is undocumented and read from Portside's own defaults only.
    static func seedPositions(_ defaults: UserDefaults = .standard) {
        for (name, position) in [(controlName, 100.0), (separatorName, 200.0), (alwaysHiddenName, 300.0)] {
            let key = "NSStatusItem Preferred Position \(name)"
            if defaults.object(forKey: key) == nil { defaults.set(position, forKey: key) }
        }
    }

    func install() {
        guard control == nil else { return }
        Self.seedPositions()
        let control = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        control.autosaveName = Self.controlName
        control.behavior = []
        if let button = control.button {
            button.target = self
            button.action = #selector(controlClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.control = control
        let separator = NSStatusBar.system.statusItem(withLength: Self.revealedLength)
        separator.autosaveName = Self.separatorName
        separator.behavior = []
        self.separator = separator
        if dividerMode { installSecondaryClicks() }
        apply(hidden: false)
    }

    /// The control shows the state, not the action: an open eye while the
    /// items are showing, a crossed eye while they are hidden. A bar to the
    /// control's left marks where the hidden items sit.
    private func showState(hidden: Bool) {
        control?.isVisible = icon != .off
        guard let button = control?.button, let name = icon.symbol(hidden: hidden) else { return }
        let state = hidden ? "Menu bar items are hidden." : "Menu bar items are showing."
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: state)
        button.toolTip = "\(state) Click to \(hidden ? "show" : "hide") them. Right-click for options."
        button.setAccessibilityLabel("Menu bar shelf. \(state)")
    }

    private static func dividerImage() -> NSImage {
        let size = NSSize(width: 6, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 1, width: 1.5, height: rect.height - 2), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    func apply(hidden: Bool) {
        self.hidden = hidden
        let collapsed = hidden || (hidesDivider && dividerMode)
        separator?.length = collapsed ? hiddenLength(of: separator) : Self.revealedLength
        separator?.button?.image = collapsed ? nil : Self.dividerImage()
        showState(hidden: hidden)
    }

    func applyLook(_ look: MenuBarLook) {
        icon = look.controlIcon
        hidesDivider = hidesDivider || icon == .off
        apply(hidden: hidden)
    }

    func controlIsOnScreen() -> Bool {
        if icon == .off { return true }
        guard let window = control?.button?.window else { return false }
        let frame = window.frame
        return NSScreen.screens.contains { $0.frame.intersects(frame) && frame.minX >= $0.frame.minX && frame.maxX <= $0.frame.maxX }
    }

    func installAlwaysHidden() {
        guard alwaysHiddenSeparator == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: Self.revealedLength)
        item.autosaveName = Self.alwaysHiddenName
        item.behavior = []
        item.button?.image = Self.dividerImage()
        alwaysHiddenSeparator = item
    }

    func applyAlwaysHidden(hidden: Bool) {
        let collapsed = hidden || (hidesDivider && dividerMode)
        alwaysHiddenSeparator?.length = collapsed ? hiddenLength(of: alwaysHiddenSeparator) : Self.revealedLength
        alwaysHiddenSeparator?.button?.image = collapsed ? nil : Self.dividerImage()
    }

    func removeAlwaysHidden() {
        if let alwaysHiddenSeparator { NSStatusBar.system.removeStatusItem(alwaysHiddenSeparator) }
        alwaysHiddenSeparator = nil
    }

    /// A divider stays registered at zero width so its position stays readable.
    private func hiddenLength(of item: NSStatusItem?) -> CGFloat {
        dividerMode ? 0 : clearingLength(item)
    }

    /// Measured while the item is still at its small length: widening it moves
    /// only its left edge, so this reading is the one that stays true.
    private func clearingLength(_ item: NSStatusItem?) -> CGFloat {
        guard let window = item?.button?.window else { return Self.widthToClear(rightEdge: nil, screenMinX: nil) }
        // Already widened (hide again, or Always Hidden under a hidden shelf): keep it.
        if window.frame.width > Self.revealedLength * 2 { return item?.length ?? Self.hiddenLength }
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(window.frame) }
        return Self.widthToClear(rightEdge: window.frame.maxX, screenMinX: screen?.frame.minX)
    }

    func barFrames() -> MenuBarBars? {
        guard let frame = separator?.button?.window?.frame, frame.width < Self.revealedLength * 2 else { return nil }
        var second: ClosedRange<Double>?
        if let item = alwaysHiddenSeparator {
            guard let other = item.button?.window?.frame, other.width < Self.revealedLength * 2, other.maxX <= frame.minX else { return nil }
            second = Double(other.minX)...Double(other.maxX)
        }
        return MenuBarBars(separator: Double(frame.minX)...Double(frame.maxX), alwaysHiddenSeparator: second)
    }

    func remove() {
        if let secondaryMonitor { NSEvent.removeMonitor(secondaryMonitor) }
        secondaryMonitor = nil
        removeAlwaysHidden()
        if let control { NSStatusBar.system.removeStatusItem(control) }
        if let separator { NSStatusBar.system.removeStatusItem(separator) }
        control = nil
        separator = nil
    }

    @objc private func controlClicked() {
        let event = NSApp.currentEvent
        let flags = (event?.modifierFlags ?? []).union(NSEvent.modifierFlags)
        if event?.type == .rightMouseUp || flags.contains(.control) {
            showMenu()
            return
        }
        guard dividerMode, alwaysHiddenAvailable() else {
            onToggle()
            return
        }
        if flags.contains(.option) {
            onAlwaysHidden()
            return
        }
        // MenuBarAgent can report a click count of 1 for both clicks, so time them here.
        let now = ProcessInfo.processInfo.systemUptime
        let second = now - lastPrimaryClick < NSEvent.doubleClickInterval
        lastPrimaryClick = second ? 0 : now
        if second { onAlwaysHidden() } else { onToggle() }
    }

    /// MenuBarAgent does not forward secondary clicks to a status button it
    /// hosts, so right-click and Control-click on the control are watched here.
    private func installSecondaryClicks() {
        secondaryMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            let isSecondary = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard isSecondary else { return }
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, let frame = self.control?.button?.window?.frame, frame.insetBy(dx: -2, dy: -2).contains(point) else { return }
                self.showMenu()
            }
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: hidden ? "Show Menu Bar Items" : "Hide Menu Bar Items", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        if dividerMode, alwaysHiddenAvailable() {
            let always = NSMenuItem(title: "Show Always Hidden Items", action: #selector(alwaysHiddenFromMenu), keyEquivalent: "")
            always.target = self
            menu.addItem(always)
        }
        let extras = extraMenuItems()
        if !extras.isEmpty {
            menu.addItem(.separator())
            for extra in extras { menu.addItem(extra) }
        }
        menu.addItem(.separator())
        let off = NSMenuItem(title: "Turn Off Menu Bar Shelf", action: #selector(turnOffFromMenu), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        if let button = control?.button, !dividerMode {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func alwaysHiddenFromMenu() { onAlwaysHidden() }
    @objc private func toggleFromMenu() { onToggle() }
    @objc private func turnOffFromMenu() { turnOff() }
}
