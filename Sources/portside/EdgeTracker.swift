import AppKit
import os.log

/// EdgeTracker owns a thin, practically invisible window along the dock's
/// edge on **every** display and reports cursor enter/exit through an
/// NSTrackingArea. Zero polling: the
/// window server tells us the instant the cursor crosses into the edge zone.
///
/// Multi-display (P3): each screen has its own edge window. Entering one
/// reports that screen so the dock can move there before revealing.
///
/// The window is alpha 1 with a 1% black background. A fully transparent
/// window (alpha 0 or a clear background) is skipped for mouse events by
/// macOS, so mouseEntered would never fire.
final class EdgeTracker {
    /// Called on the main thread when the cursor enters an edge zone.
    /// `screen` is the display that owns that zone.
    var onMouseEntered: ((NSEvent, NSScreen) -> Void)?
    /// Called on the main thread when the cursor leaves an edge zone.
    var onMouseExited: (() -> Void)?
    /// A file drag reached an edge zone. Tracking areas are unreliable
    /// while another app owns a drag session, so drags are tracked through
    /// the dragging destination callbacks instead.
    var onDragEntered: ((NSScreen) -> Void)?
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
    private var zones: [EdgeZone] = []
    private let logger = Logger(subsystem: "com.james.portside", category: "EdgeTracker")
    private var observers: [NSObjectProtocol] = []
    private var isRunning = false

    init(edge: DockEdge) {
        self.edge = edge
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        tearDownZones()
    }

    // MARK: - Lifecycle

    /// Show an edge window on every screen. Never activates the app.
    func start() {
        isRunning = true
        rebuildZones()
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DockScreen.reconcileAfterScreenChange()
                self?.rebuildZones()
            })
            // After a Space or fullscreen switch, re-assert edge windows so
            // they stay above the new Space's content (canJoinAllSpaces alone
            // is not always enough for ordering).
            observers.append(center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reassertFront()
            })
        }
    }

    func stop() {
        isRunning = false
        for zone in zones {
            zone.window.orderOut(nil)
        }
        logger.info("edge windows hidden")
    }

    /// Keep edge zones above the current Space / fullscreen app.
    private func reassertFront() {
        guard isRunning else { return }
        for zone in zones {
            zone.window.orderFrontRegardless()
        }
    }

    /// Move the edge zones to another screen edge on every display.
    func setEdge(_ newEdge: DockEdge) {
        guard newEdge != edge else { return }
        edge = newEdge
        rebuildZones()
    }

    /// Whether a point in screen coordinates is inside any edge zone.
    func containsScreenPoint(_ point: NSPoint) -> Bool {
        zones.contains { $0.window.frame.contains(point) }
    }

    // MARK: - Geometry

    private func rebuildZones() {
        tearDownZones()
        for screen in NSScreen.screens {
            let zone = EdgeZone(edge: edge, screen: screen)
            zone.view.onMouseEntered = { [weak self, weak zone] event in
                guard let self, let zone, let screen = zone.screen else { return }
                self.onMouseEntered?(event, screen)
            }
            zone.view.onMouseExited = { [weak self] in self?.onMouseExited?() }
            zone.view.onDragEntered = { [weak self, weak zone] in
                guard let self, let zone, let screen = zone.screen else { return }
                self.onDragEntered?(screen)
            }
            zone.view.onDragExited = { [weak self] reason in self?.onDragExited?(reason) }
            zone.view.onMouseDown = { [weak self] event in
                let p = NSEvent.mouseLocation
                self?.logger.info("edge zone took a click at \(p.x, format: .fixed(precision: 1)),\(p.y, format: .fixed(precision: 1)) (button \(event.buttonNumber))")
            }
            zones.append(zone)
            if isRunning {
                zone.window.orderFrontRegardless()
            }
            let f = zone.window.frame
            logger.info("edge window on \(self.edge.rawValue, privacy: .public) @\(f.origin.x, format: .fixed(precision: 0)),\(f.origin.y, format: .fixed(precision: 0)) \(f.width, format: .fixed(precision: 0))x\(f.height, format: .fixed(precision: 0))")
        }
    }

    private func tearDownZones() {
        for zone in zones {
            zone.window.orderOut(nil)
            zone.window.contentView = nil
        }
        zones.removeAll()
    }

    /// The zone the cursor is pinned to when pushed against `edge` of
    /// `screen`. Side zones stop below the menu bar so the menu bar's
    /// corners never reveal the dock.
    static func edgeFrame(for edge: DockEdge, on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let t = edgeThickness
        switch edge {
        case .bottom:
            return NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: t)
        case .left:
            return NSRect(x: frame.minX, y: frame.minY, width: t, height: visible.maxY - frame.minY)
        case .right:
            return NSRect(x: frame.maxX - t, y: frame.minY, width: t, height: visible.maxY - frame.minY)
        }
    }

    /// Primary-screen helper for callers that have not switched yet.
    static func edgeFrame(for edge: DockEdge) -> NSRect {
        edgeFrame(for: edge, on: DockScreen.active)
    }
}

// MARK: - Per-screen zone

private final class EdgeZone {
    let window: NSWindow
    let view: EdgeView
    /// Retained so callbacks can report which display was hit.
    private(set) var screen: NSScreen?

    init(edge: DockEdge, screen: NSScreen) {
        self.screen = screen
        view = EdgeView(frame: .zero)
        window = NSWindow(
            contentRect: EdgeTracker.edgeFrame(for: edge, on: screen),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = NSColor(white: 0, alpha: 0.01)
        window.isOpaque = false
        window.hasShadow = false
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.level = EdgeTracker.windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.isReleasedWhenClosed = false
        window.contentView = view
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
