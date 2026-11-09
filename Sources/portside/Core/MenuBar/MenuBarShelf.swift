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
        verifying?.cancel()
        verifying = Task { [weak self, verifyDelay] in
            try? await Task.sleep(for: verifyDelay)
            guard !Task.isCancelled else { return }
            self?.verify()
        }
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
        guard mode == .hidden else { return }
        mode = .revealed
        lastFailOpen = reason
        log.notice("menu bar shelf revealed: \(reason, privacy: .public)")
        surface.apply(hidden: false)
    }

    private func verify() {
        guard isRunning, mode == .hidden else { return }
        if !surface.controlIsOnScreen() { failOpen("the control was pushed off screen") }
    }
}

/// The live surface: a control item on the right and a separator to its left.
@MainActor
final class StatusItemShelfSurface: NSObject, MenuBarShelfSurface {
    static let controlName = "PortsideShelfControl"
    static let separatorName = "PortsideShelfSeparator"
    /// Lengths in points. 120 hid items on a notched 1728 pt display; 220 and
    /// up clipped the separator itself (spike O6), so this stays modest.
    nonisolated static let revealedLength: CGFloat = 14
    nonisolated static let hiddenLength: CGFloat = 120

    /// Runs from the control's menu. The owner turns the module off.
    private let turnOff: () -> Void
    private let onToggle: () -> Void
    private var control: NSStatusItem?
    private var separator: NSStatusItem?
    private var hidden = false

    init(onToggle: @escaping () -> Void, turnOff: @escaping () -> Void) {
        self.onToggle = onToggle
        self.turnOff = turnOff
    }

    /// Seeds Portside's own default for where each item sits, only when the
    /// user has never placed it (a smaller number is further right). The key
    /// is undocumented and read from Portside's own defaults only.
    static func seedPositions(_ defaults: UserDefaults = .standard) {
        for (name, position) in [(controlName, 100.0), (separatorName, 200.0)] {
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
            button.image = NSImage(systemSymbolName: "chevron.left.2", accessibilityDescription: "Menu bar shelf")
            button.target = self
            button.action = #selector(controlClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Click to hide or show menu bar items. Right-click for options."
        }
        let separator = NSStatusBar.system.statusItem(withLength: Self.revealedLength)
        separator.autosaveName = Self.separatorName
        separator.behavior = []
        separator.button?.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: nil)
        self.control = control
        self.separator = separator
    }

    func apply(hidden: Bool) {
        self.hidden = hidden
        separator?.length = hidden ? Self.hiddenLength : Self.revealedLength
        separator?.button?.image = hidden ? nil : NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: nil)
        control?.button?.image = NSImage(
            systemSymbolName: hidden ? "chevron.right.2" : "chevron.left.2",
            accessibilityDescription: "Menu bar shelf"
        )
    }

    func controlIsOnScreen() -> Bool {
        guard let window = control?.button?.window else { return false }
        let frame = window.frame
        return NSScreen.screens.contains { $0.frame.intersects(frame) && frame.minX >= $0.frame.minX && frame.maxX <= $0.frame.maxX }
    }

    func remove() {
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
