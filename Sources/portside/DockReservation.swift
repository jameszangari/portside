import AppKit
import os.log

/// Screen space the pinned dock takes from its edge, the way the native
/// Dock shrinks `visibleFrame` when its hiding is off. Nothing can shrink
/// `visibleFrame` for other apps, so `WindowFitter` fits their windows to
/// this instead, and Portside's own windows place themselves inside
/// `usableFrame`.
struct Reservation: Equatable {
    let edge: DockEdge
    /// Thickness from the screen edge, in points.
    let depth: CGFloat
    /// Frame of the display the dock is on.
    let screenFrame: NSRect

    /// The strip of the screen the dock covers (AppKit coordinates).
    var band: NSRect {
        switch edge {
        case .bottom: NSRect(x: screenFrame.minX, y: screenFrame.minY, width: screenFrame.width, height: depth)
        case .left: NSRect(x: screenFrame.minX, y: screenFrame.minY, width: depth, height: screenFrame.height)
        case .right: NSRect(x: screenFrame.maxX - depth, y: screenFrame.minY, width: depth, height: screenFrame.height)
        }
    }

    /// `visible` (a `visibleFrame`) with the band taken off its dock side.
    /// Unchanged for other displays.
    func usableFrame(visible: NSRect, screenFrame other: NSRect) -> NSRect {
        guard other == screenFrame else { return visible }
        var r = visible
        switch edge {
        case .bottom:
            let minY = max(r.minY, screenFrame.minY + depth)
            r.size.height = max(0, r.maxY - minY)
            r.origin.y = minY
        case .left:
            let minX = max(r.minX, screenFrame.minX + depth)
            r.size.width = max(0, r.maxX - minX)
            r.origin.x = minX
        case .right:
            r.size.width = max(0, min(r.maxX, screenFrame.maxX - depth) - r.minX)
        }
        return r
    }
}

extension Notification.Name {
    /// `DockReservation.current` changed. Posted on the main thread.
    static let dockReservationDidChange = Notification.Name("com.james.portside.dockReservationDidChange")
}

/// Holds the current `Reservation` (nil while the dock auto-hides) and
/// reports changes. `DockEngine` feeds it; it decides nothing on its own.
///
/// React analogy: a tiny store with one derived value and a subscriber.
final class DockReservation {
    /// Nil when nothing is reserved (hiding on, or the engine stopped).
    private(set) var current: Reservation?
    /// Called with (old, new) after every change.
    var onChange: ((Reservation?, Reservation?) -> Void)?

    private let logger = Logger(subsystem: "com.james.portside", category: "DockReservation")

    /// Apply new inputs. `active` is false while the dock auto-hides.
    func update(active: Bool, edge: DockEdge, depth: CGFloat, screenFrame: NSRect, reason: String) {
        let depth = depth.rounded(.up)
        let next: Reservation? = active && depth > 0
            ? Reservation(edge: edge, depth: depth, screenFrame: screenFrame)
            : nil
        guard next != current else { return }
        let old = current
        current = next
        if let next {
            logger.info("reserved \(next.depth, format: .fixed(precision: 0))pt on the \(next.edge.rawValue, privacy: .public) edge of \(next.screenFrame.width, format: .fixed(precision: 0))x\(next.screenFrame.height, format: .fixed(precision: 0)) (\(reason, privacy: .public))")
        } else {
            logger.info("reservation off (\(reason, privacy: .public))")
        }
        onChange?(old, next)
        NotificationCenter.default.post(name: .dockReservationDidChange, object: self)
    }

    /// `screen.visibleFrame` minus the reserved band, if the dock is on it.
    func usableFrame(of screen: NSScreen) -> NSRect {
        guard let current else { return screen.visibleFrame }
        return current.usableFrame(visible: screen.visibleFrame, screenFrame: screen.frame)
    }
}
