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

/// Screen used for the dock: the primary display. `NSScreen.main` follows
/// the key window, which an accessory app does not have.
enum DockScreen {
    static var frame: NSRect {
        NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Frame minus the menu bar (and any native Dock reservation).
    static var visibleFrame: NSRect {
        NSScreen.screens.first?.visibleFrame ?? frame
    }

    /// Points to pixels (2 on Retina).
    static var backingScale: CGFloat {
        NSScreen.screens.first?.backingScaleFactor ?? 2
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
