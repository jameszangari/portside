import AppKit
import os.log

/// EdgeTracker owns a thin, practically invisible window along the dock's
/// screen edge and reports cursor enter/exit through an NSTrackingArea.
/// This is the fix for Dockset's lag: zero polling, the window server tells
/// us the instant the cursor crosses into the edge zone.
///
/// The window is alpha 1 with a 1% black background. A fully transparent
/// window (alpha 0 or a clear background) is skipped for mouse events by
/// macOS, so mouseEntered would never fire.
final class EdgeTracker {
    /// Called on the main thread when the cursor enters the edge zone.
    var onMouseEntered: ((NSEvent) -> Void)?
    /// Called on the main thread when the cursor leaves the edge zone.
    var onMouseExited: (() -> Void)?
    /// A file drag reached the edge zone. Tracking areas are unreliable
    /// while another app owns a drag session, so drags are tracked through
    /// the dragging destination callbacks instead.
    var onDragEntered: (() -> Void)?
    /// The file drag left the edge zone or ended (`reason`: exited, ended).
    var onDragExited: ((String) -> Void)?

    /// Pasteboard types that reveal the dock when dragged to the edge.
    static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL]

    /// Thickness (points) of the edge-trigger zone. The window takes every
    /// click inside it, so it is a single point: the row (or column) the
    /// cursor is pinned to when it hits the screen edge. At 4pt it ate
    /// clicks on window resize edges and controls at the bottom of apps.
    static let edgeThickness: CGFloat = 1.0

    /// Window level: one above the dock panel so the edge zone always
    /// belongs to the tracker, even while the panel is revealed.
    static let windowLevel = NSWindow.Level(rawValue: DockPanel.windowLevel.rawValue + 1)

    private(set) var edge: DockEdge
    private let edgeWindow: NSWindow
    private let edgeView: EdgeView
    private let logger = Logger(subsystem: "com.james.portside", category: "EdgeTracker")
    private var screenObserver: NSObjectProtocol?

    init(edge: DockEdge) {
        self.edge = edge
        edgeView = EdgeView(frame: .zero)
        edgeWindow = NSWindow(
            contentRect: EdgeTracker.edgeFrame(for: edge),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        edgeWindow.backgroundColor = NSColor(white: 0, alpha: 0.01)
        edgeWindow.isOpaque = false
        edgeWindow.hasShadow = false
        edgeWindow.alphaValue = 1
        edgeWindow.ignoresMouseEvents = false
        edgeWindow.level = EdgeTracker.windowLevel
        edgeWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        edgeWindow.isReleasedWhenClosed = false
        edgeWindow.contentView = edgeView

        edgeView.onMouseEntered = { [weak self] event in self?.onMouseEntered?(event) }
        edgeView.onMouseExited = { [weak self] in self?.onMouseExited?() }
        edgeView.onDragEntered = { [weak self] in self?.onDragEntered?() }
        edgeView.onDragExited = { [weak self] reason in self?.onDragExited?(reason) }
        edgeView.onMouseDown = { [weak self] event in
            let p = NSEvent.mouseLocation
            self?.logger.info("edge zone took a click at \(p.x, format: .fixed(precision: 1)),\(p.y, format: .fixed(precision: 1)) (button \(event.buttonNumber))")
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: - Lifecycle

    /// Show the edge window. Never activates the app.
    func start() {
        place()
        edgeWindow.orderFrontRegardless()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.place()
            }
        }
    }

    func stop() {
        edgeWindow.orderOut(nil)
        logger.info("edge window hidden")
    }

    /// Move the edge zone to another screen edge.
    func setEdge(_ newEdge: DockEdge) {
        guard newEdge != edge else { return }
        edge = newEdge
        place()
    }

    /// Whether a point in screen coordinates is inside the edge zone.
    func containsScreenPoint(_ point: NSPoint) -> Bool {
        edgeWindow.frame.contains(point)
    }

    // MARK: - Geometry

    private func place() {
        edgeWindow.setFrame(EdgeTracker.edgeFrame(for: edge), display: false)
        let f = edgeWindow.frame
        logger.info("edge window on \(self.edge.rawValue, privacy: .public) edge at \(f.origin.x, format: .fixed(precision: 0)),\(f.origin.y, format: .fixed(precision: 0)) size \(f.width, format: .fixed(precision: 0))x\(f.height, format: .fixed(precision: 0))")
    }

    /// The zone the cursor is pinned to when pushed against `edge` of the
    /// primary screen. Side zones stop below the menu bar so the menu bar's
    /// corners never reveal the dock.
    static func edgeFrame(for edge: DockEdge) -> NSRect {
        let screen = DockScreen.frame
        let visible = DockScreen.visibleFrame
        let t = edgeThickness
        switch edge {
        case .bottom:
            return NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: t)
        case .left:
            return NSRect(x: screen.minX, y: screen.minY, width: t, height: visible.maxY - screen.minY)
        case .right:
            return NSRect(x: screen.maxX - t, y: screen.minY, width: t, height: visible.maxY - screen.minY)
        }
    }
}

// MARK: - EdgeView (receives the NSTrackingArea callbacks)

private final class EdgeView: NSView {
    var onMouseEntered: ((NSEvent) -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseDown: ((NSEvent) -> Void)?
    var onDragEntered: (() -> Void)?
    var onDragExited: ((String) -> Void)?
    private var trackingArea: NSTrackingArea?
    /// Whether a drag is inside the zone, so `draggingEnded` after an
    /// exit does not report it twice.
    private var dragInside = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(EdgeTracker.dragTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// AppKit calls this whenever the view's geometry or window changes, so
    /// the tracking rect always matches the visible bounds.
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

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?(event)
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    /// Clicks in the zone cannot pass through to the window below. Logged
    /// so swallowed clicks show up in the hand test.
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func rightMouseDown(with event: NSEvent) { onMouseDown?(event) }

    // MARK: Drag destination (reveal only, never accepts a drop)

    /// Returns no operation: the zone only reveals the dock, the drop
    /// belongs to the strip. AppKit still reports exit and end.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragInside = true
        onDragEntered?()
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard dragInside else { return }
        dragInside = false
        onDragExited?("exited")
    }

    /// Drag released or canceled while still inside the zone.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard dragInside else { return }
        dragInside = false
        onDragExited?("ended")
    }

    /// No periodic draggingUpdated calls while the cursor rests in the zone.
    override func wantsPeriodicDraggingUpdates() -> Bool { false }
}
