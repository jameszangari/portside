import AppKit
import os.log

/// EdgeTracker owns a thin, practically invisible window along the bottom
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

    /// Thickness (points) of the edge-trigger zone. Kept thin so it does not
    /// intercept clicks meant for other windows.
    static let edgeThickness: CGFloat = 4.0

    /// Window level: one above the dock panel so the bottom strip always
    /// belongs to the tracker, even while the panel is revealed.
    static let windowLevel = NSWindow.Level(rawValue: DockPanel.windowLevel.rawValue + 1)

    private let edgeWindow: NSWindow
    private let edgeView: EdgeView
    private let logger = Logger(subsystem: "com.james.portside", category: "EdgeTracker")
    private var screenObserver: NSObjectProtocol?

    init() {
        edgeView = EdgeView(frame: .zero)
        edgeWindow = NSWindow(
            contentRect: EdgeTracker.edgeFrame(),
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
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: - Lifecycle

    /// Show the edge window. Never activates the app.
    func start() {
        edgeWindow.setFrame(EdgeTracker.edgeFrame(), display: false)
        edgeWindow.orderFrontRegardless()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.edgeWindow.setFrame(EdgeTracker.edgeFrame(), display: false)
            }
        }
        let f = edgeWindow.frame
        logger.info("edge window shown at y=\(f.origin.y, format: .fixed(precision: 0)) width=\(f.width, format: .fixed(precision: 0)) height=\(f.height, format: .fixed(precision: 0))")
    }

    func stop() {
        edgeWindow.orderOut(nil)
        logger.info("edge window hidden")
    }

    /// Whether a point in screen coordinates is inside the edge zone.
    func containsScreenPoint(_ point: NSPoint) -> Bool {
        edgeWindow.frame.contains(point)
    }

    // MARK: - Geometry

    /// Frame of the edge zone along the bottom of the primary screen.
    static func edgeFrame() -> NSRect {
        let screen = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        return NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: edgeThickness)
    }
}

// MARK: - EdgeView (receives the NSTrackingArea callbacks)

private final class EdgeView: NSView {
    var onMouseEntered: ((NSEvent) -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
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

    /// Swallow clicks on the strip; they would otherwise go nowhere useful.
    override func mouseDown(with event: NSEvent) {}
}
