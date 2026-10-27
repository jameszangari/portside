import AppKit
import Combine
import os.log

/// Central coordinator for the dock.
///
/// React analogy: this is the container component. `EdgeTracker` and
/// `DockPanel` are dumb children that only emit enter/exit events; all the
/// state (is the cursor "inside" the dock zone, is a hide pending) lives here.
///
/// Timers in the reveal/hide path: exactly one cancelable hide-delay work
/// item, plus an optional cancelable reveal-delay work item that is only
/// used when `DockModel.revealDelay > 0` (it is 0 by default).
final class DockEngine {
    let dockModel: DockModel
    private let runningApps: RunningApps
    private let widgets: WidgetStore
    private let layout: DockLayout
    private let dockPanel: DockPanel
    private let edgeTracker: EdgeTracker
    private let hover: DockHover
    private let groups: GroupController
    private let logger = Logger(subsystem: "com.james.portside", category: "DockEngine")

    private var pendingHide: DispatchWorkItem?
    private var pendingReveal: DispatchWorkItem?

    /// True while any menu in Portside is open (item context menus). The menu
    /// sits outside the panel, so without this the hide timer would slide
    /// the dock away from under it.
    private var menuIsOpen = false
    private var menuObservers: [NSObjectProtocol] = []

    /// True while the separator is being dragged. The cursor can leave the
    /// panel mid-drag, and the dock must stay up until the drag ends.
    private var isResizing = false
    private let interactions = DockInteractions()
    private var edgeSubscription: AnyCancellable?

    /// Timestamp (CACurrentMediaTime) of the mouseEntered that started the
    /// current reveal, used for the enter -> animation start -> interactive logs.
    private var revealRequestedAt: CFTimeInterval = 0

    init(dockModel: DockModel = DockModel.load()) {
        self.dockModel = dockModel
        self.runningApps = RunningApps()
        self.widgets = WidgetStore(dockModel: dockModel)
        self.layout = DockLayout()
        self.hover = DockHover(overlay: OverlayPanel())
        self.groups = GroupController(dockModel: dockModel, runningApps: runningApps, hover: hover)
        let strip = DockStrip(dockModel: dockModel, runningApps: runningApps, widgets: widgets, layout: layout, groups: groups, hover: hover, interactions: interactions)
        self.dockPanel = DockPanel(dockModel: dockModel, strip: strip)
        self.edgeTracker = EdgeTracker(edge: dockModel.edge)
        hover.setEdge(dockModel.edge)

        interactions.onResizingChanged = { [weak self] resizing in
            guard let self else { return }
            self.isResizing = resizing
            if !resizing {
                self.rearmHideIfCursorOutside(source: "resize ended")
            }
        }

        interactions.onContentSizeChanged = { [weak dockPanel] size in
            dockPanel?.contentSizeChanged(size)
        }

        hover.stripToScreen = { [weak dockPanel] rect in dockPanel?.screenRect(forStripRect: rect) }
        dockPanel.onStripMouseMoved = { [weak self] point in
            guard let self, self.dockPanel.isRevealed else { return }
            self.hover.cursorMoved(to: point)
        }
        dockPanel.onMouseDown = { [weak self] in
            self?.hover.clear()
            self?.groups.stripMouseDown(at: NSEvent.mouseLocation)
        }

        // The open group's panel is part of "inside the dock": entering it
        // cancels a pending hide, leaving it arms one, like the panel itself.
        interactions.onGroupTapped = { [weak self] id in self?.groups.toggle(id) }
        hover.onTargetsChanged = { [weak self] in self?.groups.targetsChanged() }
        groups.onMouseEntered = { [weak self] in self?.handleEnter(source: "group", event: nil) }
        groups.onMouseExited = { [weak self] in self?.handleExit(source: "group") }
        groups.onCollapsed = { [weak self] in self?.rearmHideIfCursorOutside(source: "group closed") }

        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuIsOpen = true
        })
        menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.menuIsOpen = false
            // The hide timer skipped while the menu was up; re-arm it if the
            // cursor ended up outside the dock.
            self.rearmHideIfCursorOutside(source: "menu closed")
        })

        // @Published emits from willSet, before the property holds the new
        // value. Moving the panel there forces a synchronous SwiftUI layout
        // that reads the old edge and leaves the strip stale, so the change
        // is applied on the next main loop turn instead.
        edgeSubscription = dockModel.$edge
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] edge in self?.applyEdge(edge) }

        edgeTracker.onMouseEntered = { [weak self] event in
            self?.handleEnter(source: "edge", event: event)
        }
        edgeTracker.onMouseExited = { [weak self] in
            self?.handleExit(source: "edge")
        }
        dockPanel.onMouseEntered = { [weak self] event in
            self?.handleEnter(source: "panel", event: event)
        }
        dockPanel.onMouseExited = { [weak self] in
            self?.hover.clear()
            self?.handleExit(source: "panel")
        }
        dockPanel.onRevealAnimationStarted = { [weak self] in
            self?.logTiming(label: "animation start")
        }
        dockPanel.onPanelInteractive = { [weak self] in
            self?.logTiming(label: "panel interactive")
        }
        dockPanel.onRevealAnimationFinished = { [weak self] in
            guard let self else { return }
            self.logTiming(label: "animation finished")
            // The panel slid under a possibly stationary cursor, so no
            // mouseMoved will arrive. Check the cursor once.
            if let point = self.dockPanel.stripPoint(forScreenPoint: NSEvent.mouseLocation),
               self.dockPanel.containsScreenPoint(NSEvent.mouseLocation) {
                self.hover.cursorMoved(to: point)
            }
        }
    }

    /// Start the engine. The panel starts hidden; only the edge window is shown.
    func start() {
        dockPanel.prepareHidden()
        edgeTracker.start()
        logger.info("engine started, panel hidden, edge tracker armed")
    }

    /// Stop the engine: hide the panel and tear down the edge tracker.
    func stop() {
        pendingHide?.cancel()
        pendingHide = nil
        pendingReveal?.cancel()
        pendingReveal = nil
        hover.clear()
        dockPanel.hide(animated: false)
        groups.collapse(reason: "engine stopped")
        edgeTracker.stop()
        widgets.stopAll()
        logger.info("engine stopped")
    }

    /// Move the dock to another screen edge, live. The panel snaps hidden on
    /// the new edge; the next edge touch reveals it from there.
    private func applyEdge(_ edge: DockEdge) {
        groups.collapse(reason: "dock moved")
        pendingHide?.cancel()
        pendingHide = nil
        pendingReveal?.cancel()
        pendingReveal = nil
        hover.setEdge(edge)
        dockPanel.setEdge(edge)
        edgeTracker.setEdge(edge)
        logger.info("dock moved to the \(edge.rawValue, privacy: .public) edge")
    }

    private func rearmHideIfCursorOutside(source: String) {
        if !isCursorInsideDock(NSEvent.mouseLocation) {
            handleExit(source: source)
        }
    }

    /// Over the panel, the edge zone, or an open group.
    private func isCursorInsideDock(_ location: NSPoint) -> Bool {
        dockPanel.containsScreenPoint(location)
            || edgeTracker.containsScreenPoint(location)
            || groups.containsScreenPoint(location)
    }

    // MARK: - Enter / exit handling

    private func handleEnter(source: String, event: NSEvent?) {
        // Any enter (edge zone or the panel itself) cancels a pending hide.
        if let pendingHide {
            pendingHide.cancel()
            self.pendingHide = nil
            logger.info("\(source, privacy: .public) enter: pending hide canceled")
        }

        if dockPanel.isRevealedOrRevealing {
            return
        }

        revealRequestedAt = CACurrentMediaTime()
        if let event {
            // NSEvent.timestamp is system uptime; compare against the same clock
            // to see how long the event sat in the queue before we got it.
            let queueLatencyMs = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
            logger.info("\(source, privacy: .public) mouseEntered (event -> handler \(queueLatencyMs, format: .fixed(precision: 2))ms)")
        } else {
            logger.info("\(source, privacy: .public) mouseEntered")
        }

        let delay = dockModel.revealDelay
        if delay > 0 {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingReveal = nil
                self?.reveal()
            }
            pendingReveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            reveal()
        }
    }

    private func handleExit(source: String) {
        if let pendingReveal {
            pendingReveal.cancel()
            self.pendingReveal = nil
            logger.info("\(source, privacy: .public) exit: pending reveal canceled")
        }

        guard dockPanel.isRevealedOrRevealing else { return }

        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHide = nil
            if self.menuIsOpen {
                self.logger.info("hide timer fired but a menu is open, staying revealed")
                return
            }
            if self.isResizing {
                self.logger.info("hide timer fired during a resize drag, staying revealed")
                return
            }
            // One-shot sanity check, not polling: if the cursor is still over
            // the panel or the edge zone (for example because enter/exit
            // events raced while the panel slid under a stationary cursor),
            // leave the panel up. A later mouseExited will re-arm the hide.
            if self.isCursorInsideDock(NSEvent.mouseLocation) {
                self.logger.info("hide timer fired but cursor is still inside, staying revealed")
                return
            }
            self.logger.info("hide timer fired, hiding")
            self.hover.clear()
            self.dockPanel.hide(animated: true)
            // After hide() so the collapse's re-check sees the dock hiding.
            self.groups.collapse(reason: "dock hiding")
        }
        pendingHide = work
        let delayMs = dockModel.hideDelay * 1000
        logger.info("\(source, privacy: .public) mouseExited: hide armed in \(delayMs, format: .fixed(precision: 0))ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + dockModel.hideDelay, execute: work)
    }

    private func reveal() {
        dockPanel.show(animated: true)
    }

    private func logTiming(label: String) {
        guard revealRequestedAt > 0 else { return }
        let ms = (CACurrentMediaTime() - revealRequestedAt) * 1000
        logger.info("timing: mouseEntered -> \(label, privacy: .public) = \(ms, format: .fixed(precision: 2))ms")
    }
}
