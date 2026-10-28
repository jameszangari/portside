import AppKit
import SwiftUI

/// A floating, non-activating panel that shows SwiftUI content next to a
/// screen rect (a hovered tile, a group tile). It lives outside the dock
/// strip so its content can extend past the strip's bounds.
///
/// Click-through by default (`ignoresMouseEvents`), so it never steals the
/// cursor from the dock panel's tracking area. An interactive use (the group
/// popover) sets `ignoresMouseEvents = false`, listens to `onMouseEntered` /
/// `onMouseExited`, and the hide logic counts `containsScreenPoint` as
/// "inside the dock".
///
/// React analogy: a portal. Content is rendered into a separate window but
/// positioned relative to an element in the dock.
final class OverlayPanel {
    /// Above the dock panel and the edge tracker.
    static let windowLevel = NSWindow.Level(rawValue: EdgeTracker.windowLevel.rawValue + 1)

    /// Cursor entered or left the panel (only while it accepts mouse events).
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    private let panel: OverlayNSPanel
    private let container: OverlayContentView
    private let hostingView: OverlayHostingView
    private var placement: (anchor: NSRect, edge: DockEdge, gap: CGFloat)?

    init() {
        hostingView = OverlayHostingView(rootView: AnyView(EmptyView()))
        hostingView.sizingOptions = [.intrinsicContentSize]
        container = OverlayContentView(frame: .zero)
        container.addSubview(hostingView)
        hostingView.autoresizingMask = [.width, .height]

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
        panel.contentView = container

        container.onMouseEntered = { [weak self] in self?.onMouseEntered?() }
        container.onMouseExited = { [weak self] in self?.onMouseExited?() }
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
    /// was showing. The panel follows the content's size if it changes later.
    func present(_ content: AnyView, anchor: NSRect, edge: DockEdge, gap: CGFloat) {
        placement = (anchor, edge, gap)
        // NSHostingView does not report intrinsic size changes to AppKit
        // here, so the content reports its own size.
        hostingView.rootView = AnyView(
            content
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                    self?.place(size: size)
                }
        )
        place(size: hostingView.fittingSize)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Keep the current content but move it next to a new anchor (the tile
    /// moved because the strip changed).
    func reanchor(_ anchor: NSRect) {
        guard panel.isVisible, var current = placement, current.anchor != anchor else { return }
        current.anchor = anchor
        placement = current
        place(size: panel.frame.size)
    }

    func dismiss() {
        endKeyFocus()
        placement = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    var isKey: Bool { panel.isKeyWindow }

    /// Let the panel take keyboard focus (for a text field) without
    /// activating Portside: it is a non-activating panel, so the frontmost
    /// app stays active and only key events come here.
    func beginKeyFocus() {
        panel.allowsKey = true
        panel.makeKey()
    }

    /// Give keyboard focus back to the frontmost app's window by ordering
    /// the panel out (and back in if it is still showing).
    func endKeyFocus() {
        guard panel.allowsKey else { return }
        panel.allowsKey = false
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        if placement != nil {
            panel.orderFrontRegardless()
        }
    }

    private func place(size: NSSize) {
        guard let placement, size.width > 0, size.height > 0 else { return }
        let frame = OverlayPanel.frame(size: size, anchor: placement.anchor, edge: placement.edge, gap: placement.gap)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        hostingView.frame = container.bounds
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

/// Never main, and key only while `allowsKey` is set (inline rename), so
/// presenting an overlay cannot move focus.
private final class OverlayNSPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Reports cursor enter/exit over the whole overlay.
private final class OverlayContentView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
}

/// Takes the first click even though the panel is never key, so a click in
/// the popover works without a "wake up" click.
private final class OverlayHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
