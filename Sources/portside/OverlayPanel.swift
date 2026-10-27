import AppKit
import SwiftUI

/// A floating, non-activating panel that shows SwiftUI content next to a
/// screen rect (a hovered tile, a folder icon). It lives outside the dock
/// strip so its content can extend past the strip's bounds.
///
/// Click-through by default (`ignoresMouseEvents`), so it never steals the
/// cursor from the dock panel's tracking area. An interactive use (the
/// Milestone D folder popover) sets `ignoresMouseEvents = false` and must also
/// count `containsScreenPoint` as "inside the dock" in the hide logic.
///
/// React analogy: a portal. Content is rendered into a separate window but
/// positioned relative to an element in the dock.
final class OverlayPanel {
    /// Above the dock panel and the edge tracker.
    static let windowLevel = NSWindow.Level(rawValue: EdgeTracker.windowLevel.rawValue + 1)

    private let panel: OverlayNSPanel
    private let hostingView: NSHostingView<AnyView>

    init() {
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        hostingView.sizingOptions = [.intrinsicContentSize]

        panel = OverlayNSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = OverlayPanel.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = hostingView
    }

    var ignoresMouseEvents: Bool {
        get { panel.ignoresMouseEvents }
        set { panel.ignoresMouseEvents = newValue }
    }

    var isVisible: Bool { panel.isVisible }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }

    /// Show `content` next to `anchor` (screen coordinates), on the side
    /// facing away from `edge`, separated by `gap` points. Replaces whatever
    /// was showing. Instant: no animation.
    func present(_ content: AnyView, anchor: NSRect, edge: DockEdge, gap: CGFloat) {
        hostingView.rootView = content
        let size = hostingView.fittingSize
        let frame = OverlayPanel.frame(size: size, anchor: anchor, edge: edge, gap: gap)
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func dismiss() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Place a box of `size` beside `anchor`, centered on it along the dock's
    /// axis and kept inside the visible frame (no menu bar) of the anchor's
    /// screen. Rounded to whole points so text stays crisp.
    static func frame(size: NSSize, anchor: NSRect, edge: DockEdge, gap: CGFloat) -> NSRect {
        var origin: NSPoint
        switch edge {
        case .bottom:
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        case .left:
            origin = NSPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
        case .right:
            origin = NSPoint(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2)
        }
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.first { $0.frame.intersects(anchor) }
            ?? NSScreen.screens.first
        if let bounds = screen?.visibleFrame {
            let margin: CGFloat = 4
            origin.x = min(max(origin.x, bounds.minX + margin), bounds.maxX - margin - size.width)
            origin.y = min(max(origin.y, bounds.minY + margin), bounds.maxY - margin - size.height)
        }
        return NSRect(origin: NSPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }
}

/// Never key or main, so presenting an overlay cannot move focus.
private final class OverlayNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
