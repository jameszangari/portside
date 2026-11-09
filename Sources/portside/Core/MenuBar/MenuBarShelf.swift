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
    /// Runs after a fail-open that also switched Always Hidden off.
    var onFailOpen: (@MainActor () -> Void)?
    private let surface: MenuBarShelfSurface
    private let verifyDelay: Duration
    private var verifying: Task<Void, Never>?
    private let log = Logger(subsystem: "com.james.portside", category: "menubar-shelf")

    init(surface: MenuBarShelfSurface, verifyDelay: Duration = MenuBarShelf.verifyDelay) {
        self.surface = surface
        self.verifyDelay = verifyDelay
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

    /// Clips the Always Hidden items behind a second separator, or brings them
    /// back. Off after any fail-open and on every launch.
    func setAlwaysHidden(_ on: Bool) {
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
        }
    }

    func barFrames() -> MenuBarBars? { isRunning ? surface.barFrames() : nil }

    /// Shows every item so the layout can reach them: the first separator
    /// collapses and Always Hidden is opened. Pair with `closeAfterLayout`.
    func openForLayout() {
        guard isRunning else { return }
        reveal()
        if alwaysHiddenEnabled { surface.applyAlwaysHidden(hidden: false) }
    }

    func closeAfterLayout() {
        guard isRunning, alwaysHiddenEnabled else { return }
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
        verifying?.cancel()
        verifying = nil
        let hadAlwaysHidden = alwaysHiddenEnabled
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

    /// Runs from the control's menu. The owner turns the module off.
    private let turnOff: () -> Void
    private let onToggle: () -> Void
    private var control: NSStatusItem?
    private var separator: NSStatusItem?
    private var alwaysHiddenSeparator: NSStatusItem?
    private var hidden = false

    init(onToggle: @escaping () -> Void, turnOff: @escaping () -> Void) {
        self.onToggle = onToggle
        self.turnOff = turnOff
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
        let separator = NSStatusBar.system.statusItem(withLength: Self.revealedLength)
        separator.autosaveName = Self.separatorName
        separator.behavior = []
        self.control = control
        self.separator = separator
        apply(hidden: false)
    }

    /// The control shows the state, not the action: an open eye while the
    /// items are showing, a crossed eye while they are hidden. A bar to the
    /// control's left marks where the hidden items sit.
    private func showState(hidden: Bool) {
        guard let button = control?.button else { return }
        let name = hidden ? "eye.slash" : "eye"
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
        separator?.length = hidden ? clearingLength(separator) : Self.revealedLength
        separator?.button?.image = hidden ? nil : Self.dividerImage()
        showState(hidden: hidden)
    }

    func controlIsOnScreen() -> Bool {
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
        alwaysHiddenSeparator?.length = hidden ? clearingLength(alwaysHiddenSeparator) : Self.revealedLength
        alwaysHiddenSeparator?.button?.image = hidden ? nil : Self.dividerImage()
    }

    func removeAlwaysHidden() {
        if let alwaysHiddenSeparator { NSStatusBar.system.removeStatusItem(alwaysHiddenSeparator) }
        alwaysHiddenSeparator = nil
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
        removeAlwaysHidden()
        if let control { NSStatusBar.system.removeStatusItem(control) }
        if let separator { NSStatusBar.system.removeStatusItem(separator) }
        control = nil
        separator = nil
    }

    @objc private func controlClicked() {
        guard let button = control?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            let toggle = NSMenuItem(title: hidden ? "Show Menu Bar Items" : "Hide Menu Bar Items", action: #selector(toggleFromMenu), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
            menu.addItem(.separator())
            let off = NSMenuItem(title: "Turn Off Menu Bar Shelf", action: #selector(turnOffFromMenu), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            onToggle()
        }
    }

    @objc private func toggleFromMenu() { onToggle() }
    @objc private func turnOffFromMenu() { turnOff() }
}
