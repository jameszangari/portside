import SwiftUI

/// Which screen edge the dock sits on. Raw values match the native Dock's
/// `orientation` preference so Milestone F can import it directly.
enum DockEdge: String, Codable, CaseIterable, Identifiable {
    case bottom, left, right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: "Bottom"
        case .left: "Left"
        case .right: "Right"
        }
    }

    /// Side docks lay their items out top to bottom.
    var isVertical: Bool { self != .bottom }

    /// The strip side that faces away from the screen edge. Labels and
    /// popovers open on this side; icons align to it.
    var farSide: Edge.Set {
        switch self {
        case .bottom: .top
        case .left: .trailing
        case .right: .leading
        }
    }

    /// The strip side that touches the screen edge.
    var nearSide: Edge.Set {
        switch self {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    /// Point that stays fixed when a tile grows (drag lift, magnification),
    /// so tiles grow away from the screen edge.
    var growthAnchor: UnitPoint {
        switch self {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    /// Where the strip sits in a hosting view larger than itself: against
    /// the screen edge, centered along it.
    var stripAlignment: Alignment {
        switch self {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

extension Notification.Name {
    /// `DockScreen.active` changed (multi-display: the dock moved screens).
    static let dockScreenDidChange = Notification.Name("com.james.portside.dockScreenDidChange")
}

/// The screen the dock is attached to. Follows the display whose edge the
/// cursor hit (P3). Falls back to the first screen. Prefer this over
/// `NSScreen.main`, which tracks the key window an accessory app never has.
enum DockScreen {
    private static var _active: NSScreen?
    /// The active screen's last known values. `NSScreen.screens` is empty
    /// while a closed laptop has no other display, and the dock must survive
    /// that: layout keeps using these until a screen comes back.
    private static var lastFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private static var lastVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private static var lastScale: CGFloat = 2

    /// Screen the dock panel and layout use right now. Nil with no display.
    static var active: NSScreen? {
        let screens = NSScreen.screens
        let match = _active.flatMap { current in screens.first { screensMatch($0, current) } } ?? screens.first
        if let match {
            lastFrame = match.frame
            lastVisibleFrame = match.visibleFrame
            lastScale = match.backingScaleFactor
        }
        return match
    }

    static var frame: NSRect { active?.frame ?? lastFrame }

    /// Frame minus the menu bar (and any native Dock reservation) on the
    /// active screen.
    static var visibleFrame: NSRect { active?.visibleFrame ?? lastVisibleFrame }

    /// Points to pixels (2 on Retina) for the active screen.
    static var backingScale: CGFloat { active?.backingScaleFactor ?? lastScale }

    /// Switch the dock to `screen`. No-op if it is already active.
    @discardableResult
    static func setActive(_ screen: NSScreen) -> Bool {
        if let current = _active, screensMatch(current, screen) { return false }
        _active = screen
        NotificationCenter.default.post(name: .dockScreenDidChange, object: screen)
        return true
    }

    /// Screen containing `point`, or nil if none (rare; between displays).
    static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// Keep `active` valid after displays change (unplug, resolution).
    static func reconcileAfterScreenChange() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        if let current = _active,
           let match = screens.first(where: { screensMatch($0, current) }) {
            _active = match
            return
        }
        let mouse = NSEvent.mouseLocation
        _active = screen(containing: mouse) ?? screens.first
        NotificationCenter.default.post(name: .dockScreenDidChange, object: _active)
    }

    private static func screensMatch(_ a: NSScreen, _ b: NSScreen) -> Bool {
        a === b || a.frame == b.frame
    }
}

private struct DockEdgeKey: EnvironmentKey {
    static let defaultValue: DockEdge = .bottom
}

extension EnvironmentValues {
    var dockEdge: DockEdge {
        get { self[DockEdgeKey.self] }
        set { self[DockEdgeKey.self] = newValue }
    }
}
