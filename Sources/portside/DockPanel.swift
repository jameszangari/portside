import AppKit
import SwiftUI
import os.log

/// DockPanel wraps a non-activating NSPanel that renders the dock strip.
/// It slides in from its screen edge on `show` and back out on `hide`.
///
/// It knows nothing about the edge tracker or hide delays. It only reports
/// cursor enter/exit over itself and animation milestones; `DockEngine`
/// decides what to do with them.
final class DockPanel {
    /// Called when the cursor enters the panel's own tracking area.
    var onMouseEntered: ((NSEvent) -> Void)?
    /// Called when the cursor leaves the panel's own tracking area.
    var onMouseExited: (() -> Void)?
    /// Fired right after the reveal slide has been scheduled.
    var onRevealAnimationStarted: (() -> Void)?
    /// Fired once the panel is on screen and hit-testable (clicks work).
    var onPanelInteractive: (() -> Void)?
    /// Fired when the reveal slide completes (or immediately if instant).
    var onRevealAnimationFinished: (() -> Void)?
    /// Fired when the panel is off screen (hide finished, or parked hidden).
    var onHidden: (() -> Void)?
    /// Cursor moved over the panel, in strip root coordinates (`DockHover.space`).
    var onStripMouseMoved: ((CGPoint) -> Void)?
    /// Any mouse button went down on the strip (click, drag, context menu).
    var onMouseDown: (() -> Void)?
    /// A file drag entered the panel's margin around the strip. Over the
    /// strip itself, its SwiftUI drop delegate reports instead.
    var onDragEntered: (() -> Void)?
    /// The file drag left the margin or ended there (`reason`: exited, ended).
    var onDragExited: ((String) -> Void)?

    /// Window level: above normal windows and floating panels, below the
    /// edge tracker window. Same level as menus so it sits over most UI.
    static let windowLevel: NSWindow.Level = .popUpMenu

    private enum State { case hidden, revealing, revealed, hiding }

    private let panel: PortsidePanel
    private let contentView: PanelContentView
    private let hostingView: NSHostingView<DockStrip>
    private let dockModel: DockModel
    private let magnifier: Magnifier
    private let logger = Logger(subsystem: "com.james.portside", category: "DockPanel")

    private var state: State = .hidden
    /// Incremented on every show/hide so stale animation completions can be ignored.
    private var generation = 0
    private var screenObserver: NSObjectProtocol?
    /// Last size the strip reported. Nil until its first layout.
    private var measuredContentSize: CGSize?

    /// Extra window room for magnified tiles (see `Magnifier`). Zero unless
    /// tiles are magnified or settling, so the area above an unmagnified
    /// dock never blocks clicks.
    private var room = MagnifyRoom.zero
    /// Cursor is over the dock's active region (the whole panel without
    /// room; the shelf plus the magnified band with it).
    private var cursorInside = false
    /// An exit was already reported since the last enter, so the window's
    /// own mouseExited (after the room is removed) is not a second one.
    private var exitReported = false
    /// Room the current frame was laid out with.
    private var laidOutRoom = MagnifyRoom.zero
    /// When the window last grew or shrank for room. AppKit answers a shrink
    /// under a still cursor with an exit and an enter about 8ms apart.
    private var roomResizedAt: CFTimeInterval = 0
    /// Watches for the cursor coming back while the panel ignores the mouse
    /// (tiles settling after an exit). Exists only for that settle, about
    /// 200ms; a global monitor because our window gets no events then.
    private var settleReentryMonitor: Any?

    /// Screen edge the panel is attached to.
    private(set) var edge: DockEdge

    /// Padding around the SwiftUI strip inside the panel: along the edge on
    /// both ends, on the screen-edge side, and on the far side.
    private let alongInset: CGFloat = 12
    private let nearInset: CGFloat = 6
    private let farInset: CGFloat = 10
    /// Keeps the dock off the visible frame's corners when it is long.
    private let screenMargin: CGFloat = 4

    var isRevealedOrRevealing: Bool {
        state == .revealed || state == .revealing
    }

    /// Fully up and not moving, so screen positions of items are stable.
    var isRevealed: Bool { state == .revealed }

    // MARK: - Init

    init(dockModel: DockModel, strip: DockStrip, magnifier: Magnifier) {
        self.dockModel = dockModel
        self.magnifier = magnifier
        self.edge = dockModel.edge

        let hosting = FirstMouseHostingView(rootView: strip)
        hostingView = hosting
        // Report the SwiftUI ideal size through intrinsicContentSize, but do
        // not let the hosting view drive the window size (we animate the
        // window frame ourselves).
        hostingView.sizingOptions = [.intrinsicContentSize]

        contentView = PanelContentView(frame: .zero)
        contentView.addSubview(hostingView)

        panel = PortsidePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Not fully clear: the window server makes fully transparent pixels
        // click-through, and we want every point of the panel to be hit-testable.
        panel.backgroundColor = NSColor(white: 0, alpha: 0.01)
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = DockPanel.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.contentView = contentView

        contentView.onMouseEntered = { [weak self] event in self?.windowMouseEntered(event) }
        contentView.onMouseExited = { [weak self] in self?.windowMouseExited() }
        contentView.onDragEntered = { [weak self] in self?.onDragEntered?() }
        contentView.onDragExited = { [weak self] reason in self?.onDragExited?(reason) }
        contentView.onMouseMoved = { [weak self] event in self?.windowMouseMoved(event) }
        hosting.onMouseDown = { [weak self] in self?.onMouseDown?() }

        layout()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.layout()
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: - Geometry
    //
    // The panel sits flush against the screen frame's edge (the native
    // Dock's auto-hide can reserve a few points of `visibleFrame` there) and
    // is centered along that edge inside `visibleFrame`, so side docks stay
    // below the menu bar.

    /// Strip insets in the content view (non-flipped: y grows upward).
    private var insets: NSEdgeInsets {
        switch edge {
        case .bottom: NSEdgeInsets(top: farInset, left: alongInset, bottom: nearInset, right: alongInset)
        case .left: NSEdgeInsets(top: alongInset, left: nearInset, bottom: alongInset, right: farInset)
        case .right: NSEdgeInsets(top: alongInset, left: farInset, bottom: alongInset, right: nearInset)
        }
    }

    /// The strip's own (unmagnified) size.
    var stripSize: CGSize {
        let i = insets
        let base = basePanelSize
        return CGSize(width: base.width - i.left - i.right, height: base.height - i.top - i.bottom)
    }

    /// Panel size without the magnification room.
    private var basePanelSize: NSSize {
        var content = measuredContentSize ?? hostingView.intrinsicContentSize
        if content.width <= 0 || content.height <= 0 {
            content = hostingView.fittingSize
        }
        let i = insets
        return NSSize(width: content.width + i.left + i.right, height: content.height + i.top + i.bottom)
    }

    private var panelSize: NSSize { revealedFrame.size }

    /// The revealed frame plus the magnification room. The base frame is
    /// placed (and clamped to the screen) first, so the shelf never moves
    /// when room is added; the room may run past the screen's sides.
    private var revealedFrame: NSRect {
        let base = baseRevealedFrame
        guard room != .zero else { return base }
        switch edge {
        case .bottom:
            return NSRect(x: base.minX - room.side, y: base.minY,
                          width: base.width + room.side * 2, height: base.height + room.far)
        case .left:
            return NSRect(x: base.minX, y: base.minY - room.side,
                          width: base.width + room.far, height: base.height + room.side * 2)
        case .right:
            return NSRect(x: base.minX - room.far, y: base.minY - room.side,
                          width: base.width + room.far, height: base.height + room.side * 2)
        }
    }

    private var baseRevealedFrame: NSRect {
        let size = basePanelSize
        let screen = DockScreen.frame
        let visible = DockScreen.visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        func centered(_ length: CGFloat, in lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            let mid = (lower + upper) / 2
            return max(lower, min(mid - length / 2, upper - length)).rounded()
        }
        switch edge {
        case .bottom:
            return NSRect(x: centered(size.width, in: visible.minX, visible.maxX), y: screen.minY, width: size.width, height: size.height)
        case .left:
            return NSRect(x: screen.minX, y: centered(size.height, in: visible.minY, visible.maxY), width: size.width, height: size.height)
        case .right:
            return NSRect(x: screen.maxX - size.width, y: centered(size.height, in: visible.minY, visible.maxY), width: size.width, height: size.height)
        }
    }

    /// How far the shelf may widen past each end before it leaves the
    /// visible frame, in strip content order (left then right on the
    /// bottom, top then bottom on the sides).
    var magnifyAlongLimits: (lead: CGFloat, trail: CGFloat) {
        let base = baseRevealedFrame
        let visible = DockScreen.visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        let i = insets
        switch edge {
        case .bottom:
            return (base.minX + i.left - visible.minX, visible.maxX - (base.maxX - i.right))
        case .left, .right:
            return (visible.maxY - (base.maxY - i.top), base.minY + i.bottom - visible.minY)
        }
    }

    /// Same frame, pushed just past the screen edge.
    private var hiddenFrame: NSRect {
        var frame = revealedFrame
        let screen = DockScreen.frame
        switch edge {
        case .bottom: frame.origin.y = screen.minY - frame.height
        case .left: frame.origin.x = screen.minX - frame.width
        case .right: frame.origin.x = screen.maxX
        }
        return frame
    }

    /// Attach to another screen edge. The panel snaps hidden there; the next
    /// edge enter reveals it from the new side.
    func setEdge(_ newEdge: DockEdge) {
        guard newEdge != edge else { return }
        edge = newEdge
        prepareHidden()
        layout()
    }

    /// Size the hosting view and put the panel at the frame matching its state.
    private func layout(display: Bool = false) {
        // Size the window first, then fit the hosting view inside the
        // content view's real bounds. Setting the subview frame before the
        // window has a size would get skewed by autoresizing.
        switch state {
        case .hidden, .hiding:
            panel.setFrame(hiddenFrame, display: false)
        case .revealed, .revealing:
            panel.setFrame(revealedFrame, display: display)
        }
        let bounds = contentView.bounds
        let i = insets
        hostingView.frame = NSRect(
            x: bounds.minX + i.left,
            y: bounds.minY + i.bottom,
            width: bounds.width - i.left - i.right,
            height: bounds.height - i.top - i.bottom
        )
        // Keeps the insets when the window is resized without going through
        // layout(), e.g. show() picking up a new strip width.
        hostingView.autoresizingMask = [.width, .height]
    }

    /// Add or remove the room magnified tiles draw into. Applied at once
    /// while revealed; during a slide the slide's completion catches up.
    func setMagnifyRoom(_ newRoom: MagnifyRoom) {
        guard newRoom != room else { return }
        room = newRoom
        if room == .zero {
            panel.ignoresMouseEvents = false
            removeSettleReentryMonitor()
        }
        layoutIfSizeChanged()
    }

    /// The strip reported a new size (icon size, items, widgets, edge).
    func contentSizeChanged(_ size: CGSize) {
        measuredContentSize = size
        layoutIfSizeChanged()
    }

    /// Resizes in place while revealed or hidden. During a slide the
    /// animator owns the frame; the slide's completion catches up instead.
    private func layoutIfSizeChanged() {
        guard state == .revealed || state == .hidden else { return }
        guard panelSize != panel.frame.size else { return }
        let roomChanged = room != laidOutRoom
        // A resized window only redraws what SwiftUI marks dirty, and
        // undrawn pixels are fully transparent, which the window server
        // treats as click-through: the cursor would "leave" the dock. Room
        // changes redraw the whole window with the resize.
        layout(display: roomChanged)
        if roomChanged {
            roomResizedAt = CACurrentMediaTime()
            if state == .revealed { panel.display() }
            // Room comes and goes once per hover; keep it out of the info log.
            laidOutRoom = room
            logger.debug("panel room \(self.room.far, format: .fixed(precision: 0))/\(self.room.side, format: .fixed(precision: 0))pt")
            return
        }
        logger.info("panel resized to \(self.panel.frame.width, format: .fixed(precision: 0))x\(self.panel.frame.height, format: .fixed(precision: 0)) at icon \(self.dockModel.iconSize, format: .fixed(precision: 0))pt")
    }

    // MARK: - Strip coordinates (for hover labels and overlays)
    //
    // The strip's content coordinate space (`DockHover.space`) has a
    // top-left origin. It fills the hosting view except for the
    // magnification room, which sits on its far side and both ends.

    /// Top-left of the strip content inside the hosting view.
    private var contentOrigin: CGPoint {
        switch edge {
        case .bottom: CGPoint(x: room.side, y: room.far)
        case .left: CGPoint(x: 0, y: room.side)
        case .right: CGPoint(x: room.far, y: room.side)
        }
    }

    private func stripPoint(fromWindowPoint windowPoint: NSPoint) -> CGPoint {
        let p = hostingView.convert(windowPoint, from: nil)
        let origin = contentOrigin
        return CGPoint(x: p.x - origin.x, y: (hostingView.isFlipped ? p.y : hostingView.bounds.height - p.y) - origin.y)
    }

    /// Screen point -> strip root coordinates, or nil if the panel is not on screen.
    func stripPoint(forScreenPoint screenPoint: NSPoint) -> CGPoint? {
        guard panel.isVisible else { return nil }
        return stripPoint(fromWindowPoint: panel.convertPoint(fromScreen: screenPoint))
    }

    /// Strip root rect -> screen rect, or nil if the panel is not on screen.
    func screenRect(forStripRect rect: CGRect) -> NSRect? {
        guard panel.isVisible else { return nil }
        let origin = contentOrigin
        var local = rect.offsetBy(dx: origin.x, dy: origin.y)
        if !hostingView.isFlipped {
            local.origin.y = hostingView.bounds.height - local.maxY
        }
        return panel.convertToScreen(hostingView.convert(local, to: nil))
    }

    /// The panel's frame on screen without the magnification room, nil
    /// while it is ordered out.
    var screenFrame: NSRect? {
        panel.isVisible ? baseScreenFrame : nil
    }

    private var baseScreenFrame: NSRect {
        let frame = panel.frame
        switch edge {
        case .bottom:
            return NSRect(x: frame.minX + room.side, y: frame.minY,
                          width: frame.width - room.side * 2, height: frame.height - room.far)
        case .left:
            return NSRect(x: frame.minX, y: frame.minY + room.side,
                          width: frame.width - room.far, height: frame.height - room.side * 2)
        case .right:
            return NSRect(x: frame.minX + room.far, y: frame.minY + room.side,
                          width: frame.width - room.far, height: frame.height - room.side * 2)
        }
    }

    /// Whether a point in screen coordinates is over the visible dock: the
    /// panel, or with magnification room only the shelf and the band the
    /// magnified tiles cover (the rest of the room does not count).
    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard panel.isVisible else { return false }
        guard room != .zero else { return panel.frame.contains(point) }
        return isInActiveRegion(windowPoint: panel.convertPoint(fromScreen: point))
    }

    private func isInActiveRegion(windowPoint: NSPoint) -> Bool {
        guard room != .zero else { return true }
        let base = panel.convertFromScreen(baseScreenFrame)
        return base.contains(windowPoint) || magnifier.bandContains(stripPoint(fromWindowPoint: windowPoint))
    }

    // MARK: - Cursor tracking
    //
    // Without magnification room this is the window's own enter/exit/move,
    // unchanged. With room, enter and exit follow the active region, so the
    // transparent room never keeps the dock up or magnified.

    private func windowMouseEntered(_ event: NSEvent) {
        guard room == .zero || isInActiveRegion(windowPoint: event.locationInWindow) else { return }
        reportEnter(event)
    }

    private func windowMouseExited() {
        // The stray exit after a room resize: the cursor never left.
        if CACurrentMediaTime() - roomResizedAt < 0.05, containsScreenPoint(NSEvent.mouseLocation) {
            logger.debug("ignored exit after a room resize, cursor still over the dock")
            return
        }
        cursorInside = false
        // While the tiles settle back the room is still there; let clicks
        // above the dock through right away instead of after the settle.
        // Mouse events come back when the room goes (`setMagnifyRoom`), or
        // as soon as the cursor is back over the shelf.
        if room != .zero {
            panel.ignoresMouseEvents = true
            if state == .revealed { installSettleReentryMonitor() }
        }
        guard !exitReported else { return }
        exitReported = true
        onMouseExited?()
    }

    private func windowMouseMoved(_ event: NSEvent) {
        let point = stripPoint(fromWindowPoint: event.locationInWindow)
        guard room != .zero else {
            // Back over the panel after an exit we reported, but AppKit sent
            // no mouseEntered (the room went away under the cursor).
            if !cursorInside && exitReported { reportEnter(event) }
            onStripMouseMoved?(point)
            return
        }
        let inside = isInActiveRegion(windowPoint: event.locationInWindow)
        if inside != cursorInside {
            if inside {
                reportEnter(event)
            } else {
                windowMouseExited()
            }
        }
        if inside { onStripMouseMoved?(point) }
    }

    /// The cursor came back over the shelf while the tiles were still
    /// settling: take the mouse again and report the enter and the move at
    /// once, so magnification resumes without waiting for the settle.
    private func installSettleReentryMonitor() {
        guard settleReentryMonitor == nil else { return }
        settleReentryMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, self.panel.ignoresMouseEvents, self.room != .zero else { return }
            let location = NSEvent.mouseLocation
            guard self.panel.isVisible, self.baseScreenFrame.contains(location) else { return }
            self.removeSettleReentryMonitor()
            self.panel.ignoresMouseEvents = false
            self.logger.debug("cursor back over the shelf while settling")
            let windowPoint = self.panel.convertPoint(fromScreen: location)
            self.reportEnter(event)
            self.onStripMouseMoved?(self.stripPoint(fromWindowPoint: windowPoint))
        }
    }

    private func removeSettleReentryMonitor() {
        guard let monitor = settleReentryMonitor else { return }
        NSEvent.removeMonitor(monitor)
        settleReentryMonitor = nil
    }

    private func reportEnter(_ event: NSEvent) {
        cursorInside = true
        exitReported = false
        onMouseEntered?(event)
    }

    // MARK: - Show / Hide

    /// Put the panel in its hidden state without animation and keep it off screen.
    func prepareHidden() {
        panel.ignoresMouseEvents = false
        removeSettleReentryMonitor()
        generation += 1
        state = .hidden
        panel.setFrame(hiddenFrame, display: false)
        panel.orderOut(nil)
        onHidden?()
    }

    /// Slide the panel in from its edge. Non-activating: the frontmost
    /// app keeps focus and the first click on the panel is delivered.
    func show(animated: Bool) {
        guard !isRevealedOrRevealing else { return }
        generation += 1
        let myGeneration = generation
        state = .revealing

        if !panel.isVisible {
            panel.setFrame(hiddenFrame, display: false)
        }
        panel.ignoresMouseEvents = false
        removeSettleReentryMonitor()
        panel.orderFrontRegardless()

        let target = revealedFrame
        let duration = effectiveDuration(animated: animated)

        if duration == 0 {
            panel.setFrame(target, display: true)
            onRevealAnimationStarted?()
            onPanelInteractive?()
            finishReveal(generation: myGeneration)
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.finishReveal(generation: myGeneration)
        })
        onRevealAnimationStarted?()
        onPanelInteractive?()
    }

    /// Slide the panel out past its screen edge, then order it out.
    func hide(animated: Bool) {
        guard state == .revealed || state == .revealing else { return }
        generation += 1
        let myGeneration = generation
        state = .hiding
        removeSettleReentryMonitor()

        let target = hiddenFrame
        let duration = effectiveDuration(animated: animated)

        if duration == 0 {
            panel.setFrame(target, display: true)
            finishHide(generation: myGeneration)
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            self?.finishHide(generation: myGeneration)
        })
    }

    private func finishReveal(generation: Int) {
        guard generation == self.generation else { return }
        state = .revealed
        layoutIfSizeChanged()
        onRevealAnimationFinished?()
        logger.info("panel revealed")
    }

    private func finishHide(generation: Int) {
        guard generation == self.generation else { return }
        state = .hidden
        panel.orderOut(nil)
        cursorInside = false
        layoutIfSizeChanged()
        logger.info("panel hidden")
        onHidden?()
    }

    /// Animation duration honoring the instant option and Reduce Motion.
    private func effectiveDuration(animated: Bool) -> TimeInterval {
        if !animated { return 0 }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return 0 }
        return max(0, dockModel.animationDuration)
    }
}

// MARK: - NSPanel subclass

/// The panel never becomes key or main, like the native Dock: clicking an
/// item must not move keyboard focus away from the frontmost app. Clicks
/// still arrive because the hosting view accepts first mouse (verified with
/// synthetic clicks: item click logged, key window false, app inactive).
private final class PortsidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Do not let AppKit nudge the panel back on screen while it is parked
    /// past its screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - Content view with its own tracking area

/// Hosts the SwiftUI strip and reports cursor enter/exit over the panel so
/// the dock stays up while the user hovers it.
private final class PanelContentView: NSView {
    var onMouseEntered: ((NSEvent) -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseMoved: ((NSEvent) -> Void)?
    var onDragEntered: (() -> Void)?
    var onDragExited: ((String) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var dragInside = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Same types as the edge zone, so a drag stays "over the dock" in
        // the margin between the strip and the panel's edges.
        registerForDraggedTypes(EdgeTracker.dragTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Created once: `.inVisibleRect` follows the view's bounds by itself.
        // Replacing the area on every resize (magnification room coming and
        // going) made AppKit send a stray exit and enter under a still cursor.
        guard trackingArea == nil else { return }
        // .mouseMoved drives hover labels. Events only arrive while the
        // cursor is inside this view, so there is no cost when it is not.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
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

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(event)
    }

    // MARK: Drag destination (keeps the dock up, never accepts a drop)

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

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard dragInside else { return }
        dragInside = false
        onDragExited?("ended")
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }
}

/// NSHostingView that accepts the first click even when its window is not
/// key, so the user never needs a "wake up" click. Logs each mouse down so
/// the hand test can confirm no focus change (key window and app active
/// should both stay false).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    private let logger = Logger(subsystem: "com.james.portside", category: "DockPanel")

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var onMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let keyWindow = window?.isKeyWindow ?? false
        logger.info("panel mouseDown (key window: \(keyWindow), portside active: \(NSApp.isActive))")
        onMouseDown?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onMouseDown?()
        super.rightMouseDown(with: event)
    }
}
